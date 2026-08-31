package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	_ "time/tzdata"
)

var workspace = "/workspace"
var hostWorkspace = workspace
var envPath = "/workspace/.env"
var completionMarkerPath = "/workspace/.setup-complete"
var controllerUpdateStatePath = "/workspace/.controller-update-state.json"

var usernamePattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_.-]{0,63}$`)

type setupService struct {
	mu       sync.Mutex
	applying bool
	lastErr  string
	baseURL  string
}

type setupStatus struct {
	Configured bool   `json:"configured"`
	State      string `json:"state"`
	Message    string `json:"message,omitempty"`
	BaseURL    string `json:"baseUrl,omitempty"`
}

type setupRequest struct {
	PublicBaseURL        string `json:"publicBaseUrl"`
	AllowedOrigins       string `json:"allowedOrigins"`
	SiteName             string `json:"siteName"`
	Timezone             string `json:"timezone"`
	AdminUsername        string `json:"adminUsername"`
	AdminPassword        string `json:"adminPassword"`
	AdminPasswordConfirm string `json:"adminPasswordConfirm"`
}

func main() {
	if configuredWorkspace := strings.TrimSpace(os.Getenv("SETUP_WORKSPACE")); configuredWorkspace != "" {
		workspace = filepath.Clean(configuredWorkspace)
		envPath = filepath.Join(workspace, ".env")
		completionMarkerPath = filepath.Join(workspace, ".setup-complete")
		controllerUpdateStatePath = filepath.Join(workspace, ".controller-update-state.json")
	}
	hostWorkspace = detectHostWorkspace()
	updater := newControllerUpdateService()
	updater.recoverStaleState()
	if len(os.Args) > 1 && os.Args[1] == "update-runner" {
		if err := updater.runUpdate(); err != nil {
			log.Fatal(err)
		}
		return
	}
	service := &setupService{}
	if configuredEnv() && !setupCompleted() {
		service.applying = true
		go service.applyCompose()
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/setup/status", service.status)
	mux.HandleFunc("/api/setup/complete", service.complete)
	mux.HandleFunc("/api/setup/agent-installer", service.agentInstaller)
	updater.register(mux)
	go updater.runScheduler()

	server := &http.Server{
		Addr:              ":8090",
		Handler:           withRequestLimits(withOriginGuard(mux)),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       90 * time.Second,
		WriteTimeout:      90 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("first-run setup service listening on %s", server.Addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

// agentInstaller serves the installer from the mounted controller workspace so
// monitored hosts do not need direct access to GitHub or another CDN.
func (s *setupService) agentInstaller(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}
	platform := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("platform")))
	filename := map[string]string{"linux": "install-agent.sh", "windows": "install-agent.ps1"}[platform]
	if filename == "" {
		writeError(w, http.StatusBadRequest, "安装器平台必须是 linux 或 windows")
		return
	}
	path := filepath.Join(workspace, "deploy", filename)
	content, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			writeError(w, http.StatusNotFound, "当前总控版本未提供该平台的 Agent 安装器")
		} else {
			writeError(w, http.StatusInternalServerError, "Agent 安装器读取失败")
		}
		return
	}
	if platform == "linux" {
		content = bytes.ReplaceAll(content, []byte("\r\n"), []byte("\n"))
		content = bytes.ReplaceAll(content, []byte("\r"), []byte("\n"))
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(content)
}

func (s *setupService) status(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	applying := s.applying
	lastErr := s.lastErr
	baseURL := s.baseURL
	s.mu.Unlock()
	configured := configuredEnv()
	state := "ready"
	message := "等待首次安装配置"
	if applying {
		state = "applying"
		message = "配置已保存，正在启动生产服务"
	} else if lastErr != "" {
		state = "error"
		message = lastErr
	} else if configured && setupCompleted() {
		state = "configured"
		message = "安装已完成"
	} else if configured {
		state = "applying"
		message = "配置已保存，正在等待生产服务就绪"
	}
	if baseURL == "" && configured {
		baseURL = configuredEnvironmentValue("PUBLIC_BASE_URL")
	}
	writeJSON(w, http.StatusOK, setupStatus{Configured: configured, State: state, Message: message, BaseURL: baseURL})
}

func (s *setupService) complete(w http.ResponseWriter, r *http.Request) {
	if configuredEnv() && setupCompleted() {
		writeError(w, http.StatusConflict, "系统已经完成安装")
		return
	}
	var request setupRequest
	if err := decodeJSON(r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "安装信息格式不正确")
		return
	}
	if err := validateSetupRequest(request); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	s.mu.Lock()
	if s.applying {
		s.mu.Unlock()
		writeError(w, http.StatusConflict, "已有安装任务正在执行")
		return
	}
	s.applying = true
	s.lastErr = ""
	s.mu.Unlock()
	if err := clearSetupCompletionMarker(); err != nil {
		s.mu.Lock()
		s.applying = false
		s.lastErr = "安装状态重置失败，请检查项目目录权限"
		s.mu.Unlock()
		writeError(w, http.StatusInternalServerError, s.lastErr)
		return
	}

	if err := writeEnvironment(request); err != nil {
		s.mu.Lock()
		s.applying = false
		s.lastErr = "配置文件写入失败，请检查项目目录权限"
		s.mu.Unlock()
		writeError(w, http.StatusInternalServerError, "配置文件写入失败，请检查项目目录权限")
		return
	}

	s.mu.Lock()
	s.baseURL = request.PublicBaseURL
	s.mu.Unlock()
	go s.applyCompose()
	writeJSON(w, http.StatusAccepted, setupStatus{Configured: true, State: "applying", Message: "配置已保存，正在初始化 PostgreSQL 并启动服务", BaseURL: request.PublicBaseURL})
}

func (s *setupService) applyCompose() {
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Minute)
	defer cancel()
	command := exec.CommandContext(ctx, "docker", composeApplyArgs()...)
	command.Env = controllerUpdateEnvironment()
	if output, err := command.CombinedOutput(); err != nil {
		log.Printf("compose apply failed: %v (%d bytes)", err, len(output))
		s.mu.Lock()
		s.applying = false
		s.lastErr = "服务重建失败，请检查 Docker 日志后重试"
		s.mu.Unlock()
		return
	}
	if err := writeSetupCompletionMarker(); err != nil {
		log.Printf("setup completion marker failed: %v", err)
		s.mu.Lock()
		s.applying = false
		s.lastErr = "生产服务已启动，但安装状态保存失败，请检查项目目录权限"
		s.mu.Unlock()
		return
	}
	s.mu.Lock()
	s.applying = false
	s.lastErr = ""
	s.mu.Unlock()
}

func composeApplyArgs() []string {
	args := []string{"compose", "-f", filepath.Join(workspace, "docker-compose.yml"), "--project-directory", hostWorkspace, "--env-file", envPath}
	if strings.EqualFold(environmentValue("CONTROLLER_AGENT_ENABLED", "false"), "true") {
		args = append(args, "--profile", "host-monitoring")
	}
	return append(args, "up", "-d", "--build", "--no-deps", "--wait", "--wait-timeout", "300", "server", "web")
}

func writeEnvironment(request setupRequest) error {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return err
	}
	settingsKey := base64.StdEncoding.EncodeToString(key)
	postgresDatabase := environmentValue("POSTGRES_DB", "guanlan_monitor")
	postgresUser := environmentValue("POSTGRES_USER", "guanlan")
	postgresPassword := strings.TrimSpace(os.Getenv("POSTGRES_PASSWORD"))
	webPort := environmentValue("WEB_PORT", "18080")
	webBindAddress := environmentValue("WEB_BIND_ADDRESS", "0.0.0.0")
	controllerAgentEnabled := environmentValue("CONTROLLER_AGENT_ENABLED", "false")
	controllerAgentDeviceID := environmentValue("CONTROLLER_AGENT_DEVICE_ID", "")
	controllerAgentKey := environmentValue("CONTROLLER_AGENT_KEY", "")
	controllerAgentName := environmentValue("CONTROLLER_AGENT_NAME", "总控服务器")
	controllerAgentGroup := environmentValue("CONTROLLER_AGENT_GROUP", "控制平面")
	controllerAutoUpdate := configuredEnvironmentValue("CONTROLLER_AUTO_UPDATE")
	if controllerAutoUpdate == "" {
		controllerAutoUpdate = environmentValue("CONTROLLER_AUTO_UPDATE", "false")
	}
	if postgresPassword == "" {
		return errors.New("内置 PostgreSQL 凭据缺失，请重新运行总终端安装器")
	}
	lines := []string{
		"# Generated by the browser setup wizard. Keep this file private.",
		"SPRING_PROFILES_ACTIVE=production",
		"POSTGRES_DB=" + dotenvValue(postgresDatabase),
		"POSTGRES_USER=" + dotenvValue(postgresUser),
		"POSTGRES_PASSWORD=" + dotenvValue(postgresPassword),
		"BOOTSTRAP_ADMIN_USERNAME=" + dotenvValue(request.AdminUsername),
		"BOOTSTRAP_ADMIN_PASSWORD=" + dotenvValue(request.AdminPassword),
		"SETTINGS_ENCRYPTION_KEY=" + dotenvValue(settingsKey),
		"WEB_PORT=" + dotenvValue(webPort),
		"WEB_BIND_ADDRESS=" + dotenvValue(webBindAddress),
		"APP_TIMEZONE=" + dotenvValue(request.Timezone),
		"SITE_NAME=" + dotenvValue(request.SiteName),
		"PUBLIC_BASE_URL=" + dotenvValue(request.PublicBaseURL),
		"SESSION_COOKIE_SECURE=" + dotenvValue(strconv.FormatBool(strings.HasPrefix(request.PublicBaseURL, "https://"))),
		"ALLOW_INSECURE_HTTP=" + dotenvValue(strconv.FormatBool(strings.HasPrefix(request.PublicBaseURL, "http://"))),
		"ALLOWED_ORIGINS=" + dotenvValue(request.AllowedOrigins),
		"METRIC_RETENTION_DAYS=30",
		"DEVICE_OFFLINE_AFTER_SECONDS=30",
		"CONTROLLER_AGENT_ENABLED=" + dotenvValue(controllerAgentEnabled),
		"CONTROLLER_AGENT_DEVICE_ID=" + dotenvValue(controllerAgentDeviceID),
		"CONTROLLER_AGENT_KEY=" + dotenvValue(controllerAgentKey),
		"CONTROLLER_AGENT_NAME=" + dotenvValue(controllerAgentName),
		"CONTROLLER_AGENT_GROUP=" + dotenvValue(controllerAgentGroup),
		"CONTROLLER_AUTO_UPDATE=" + dotenvValue(controllerAutoUpdate),
	}
	content := strings.Join(lines, "\n") + "\n"
	if existing, err := os.ReadFile(envPath); err == nil {
		backup := fmt.Sprintf("%s.backup.setup.%s", envPath, time.Now().UTC().Format("20060102T150405Z"))
		if err := os.WriteFile(backup, existing, 0600); err != nil {
			return err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	temporary, err := os.CreateTemp(workspace, ".env.setup-*")
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := io.WriteString(temporary, content); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryName, envPath)
}

func environmentValue(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func detectHostWorkspace() string {
	if configured := strings.TrimSpace(os.Getenv("GUANLAN_HOST_PROJECT_ROOT")); configured != "" {
		return filepath.Clean(configured)
	}
	hostname, err := os.Hostname()
	if err != nil || strings.TrimSpace(hostname) == "" {
		return workspace
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "docker", "inspect", "--format", `{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}`, hostname).Output()
	if err != nil {
		return workspace
	}
	if detected := strings.TrimSpace(string(output)); detected != "" {
		return filepath.Clean(detected)
	}
	return workspace
}

func configuredEnvironmentValue(name string) string {
	values, err := readEnv()
	if err != nil {
		return ""
	}
	return values[name]
}

func setupCompleted() bool {
	info, err := os.Stat(completionMarkerPath)
	return err == nil && !info.IsDir()
}

func clearSetupCompletionMarker() error {
	err := os.Remove(completionMarkerPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func writeSetupCompletionMarker() error {
	temporary, err := os.CreateTemp(workspace, ".setup-complete-*")
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := io.WriteString(temporary, time.Now().UTC().Format(time.RFC3339)+"\n"); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryName, completionMarkerPath)
}

func configuredEnv() bool {
	values, err := readEnv()
	if err != nil {
		return false
	}
	return values["SPRING_PROFILES_ACTIVE"] == "production" &&
		values["POSTGRES_DB"] != "" && values["POSTGRES_USER"] != "" && values["POSTGRES_PASSWORD"] != "" &&
		values["BOOTSTRAP_ADMIN_USERNAME"] != "" && values["BOOTSTRAP_ADMIN_PASSWORD"] != "" &&
		values["SETTINGS_ENCRYPTION_KEY"] != ""
}

func readEnv() (map[string]string, error) {
	content, err := os.ReadFile(envPath)
	if err != nil {
		return nil, err
	}
	values := make(map[string]string)
	for _, line := range strings.Split(string(content), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		value := strings.TrimSpace(parts[1])
		if len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"' {
			value = strings.TrimSuffix(strings.TrimPrefix(value, `"`), `"`)
		}
		values[strings.TrimSpace(parts[0])] = value
	}
	return values, nil
}

func validateSetupRequest(request setupRequest) error {
	if len(request.AdminPassword) < 12 || request.AdminPassword != request.AdminPasswordConfirm {
		return errors.New("管理员密码至少 12 位且两次输入必须一致")
	}
	if !usernamePattern.MatchString(request.AdminUsername) {
		return errors.New("管理员用户名格式无效")
	}
	parsedURL, err := url.Parse(request.PublicBaseURL)
	if err != nil || parsedURL.User != nil || parsedURL.Host == "" || (parsedURL.Path != "" && parsedURL.Path != "/") || parsedURL.RawQuery != "" || parsedURL.Fragment != "" || (parsedURL.Scheme != "http" && parsedURL.Scheme != "https") {
		return errors.New("公网入口必须是有效的 HTTP 或 HTTPS 地址")
	}
	if err := validateAllowedOrigins(request.AllowedOrigins, parsedURL); err != nil {
		return err
	}
	if strings.TrimSpace(request.SiteName) == "" || len(request.SiteName) > 80 || strings.TrimSpace(request.Timezone) == "" {
		return errors.New("请完整填写来源、站点名称和时区")
	}
	if _, err := time.LoadLocation(strings.TrimSpace(request.Timezone)); err != nil {
		return errors.New("服务时区无效，请填写 IANA 时区，例如 Asia/Shanghai")
	}
	return nil
}

func validateAllowedOrigins(value string, publicURL *url.URL) error {
	publicOrigin := normalizedOrigin(publicURL)
	foundPublic := false
	count := 0
	for _, raw := range strings.Split(value, ",") {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		origin, err := url.Parse(raw)
		if err != nil || origin.User != nil || origin.Host == "" || origin.RawQuery != "" || origin.Fragment != "" || (origin.Path != "" && origin.Path != "/") || (origin.Scheme != "http" && origin.Scheme != "https") {
			return errors.New("允许的 Web 来源必须是逗号分隔的 HTTP 或 HTTPS 来源地址")
		}
		count++
		if normalizedOrigin(origin) == publicOrigin {
			foundPublic = true
		}
	}
	if count == 0 {
		return errors.New("请至少填写一个允许的 Web 来源")
	}
	if !foundPublic {
		return errors.New("允许的 Web 来源必须包含公网入口地址")
	}
	return nil
}

func normalizedOrigin(value *url.URL) string {
	if value == nil {
		return ""
	}
	scheme := strings.ToLower(value.Scheme)
	host := strings.ToLower(strings.TrimSuffix(value.Hostname(), "."))
	port := value.Port()
	if port == defaultPort(scheme) {
		port = ""
	}
	authority := host
	if strings.Contains(host, ":") {
		authority = "[" + host + "]"
	}
	if port != "" {
		authority += ":" + port
	}
	return scheme + "://" + authority
}

func dotenvValue(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	value = strings.ReplaceAll(value, `"`, `\"`)
	value = strings.ReplaceAll(value, "$", "$$")
	return `"` + value + `"`
}

func decodeJSON(request *http.Request, target any) error {
	decoder := json.NewDecoder(io.LimitReader(request.Body, 64*1024))
	decoder.DisallowUnknownFields()
	return decoder.Decode(target)
}

func withRequestLimits(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			r.Body = http.MaxBytesReader(w, r.Body, 64*1024)
		}
		next.ServeHTTP(w, r)
	})
}

func withOriginGuard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			origin := r.Header.Get("Origin")
			if origin != "" {
				parsed, err := url.Parse(origin)
				forwardedHost := firstHeaderValue(r.Header.Get("X-Forwarded-Host"))
				if err != nil || !validOriginURL(parsed) || (!originMatchesHost(parsed, r.Host) && !originMatchesHost(parsed, forwardedHost)) {
					writeError(w, http.StatusForbidden, "来源校验失败")
					return
				}
			}
		}
		next.ServeHTTP(w, r)
	})
}

func validOriginURL(origin *url.URL) bool {
	return origin != nil && origin.User == nil && origin.Host != "" && origin.Path == "" && origin.RawQuery == "" && origin.Fragment == "" && (origin.Scheme == "http" || origin.Scheme == "https")
}

func originMatchesHost(origin *url.URL, expectedAuthority string) bool {
	expectedHost, expectedPort := splitAuthority(firstHeaderValue(expectedAuthority))
	if expectedHost == "" || !strings.EqualFold(strings.TrimSuffix(origin.Hostname(), "."), strings.TrimSuffix(expectedHost, ".")) {
		return false
	}
	if expectedPort == "" {
		return true
	}
	originPort := origin.Port()
	if originPort == "" {
		originPort = defaultPort(origin.Scheme)
	}
	return originPort == expectedPort
}

func splitAuthority(authority string) (string, string) {
	authority = strings.TrimSpace(authority)
	if authority == "" {
		return "", ""
	}
	if host, port, err := net.SplitHostPort(authority); err == nil {
		return strings.Trim(host, "[]"), port
	}
	if strings.Count(authority, ":") == 1 {
		parts := strings.SplitN(authority, ":", 2)
		if _, err := strconv.Atoi(parts[1]); err == nil {
			return strings.Trim(parts[0], "[]"), parts[1]
		}
	}
	return strings.Trim(authority, "[]"), ""
}

func defaultPort(scheme string) string {
	if strings.EqualFold(scheme, "https") {
		return "443"
	}
	return "80"
}

func firstHeaderValue(value string) string {
	if index := strings.IndexByte(value, ','); index >= 0 {
		value = value[:index]
	}
	return strings.TrimSpace(value)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"message": message})
}
