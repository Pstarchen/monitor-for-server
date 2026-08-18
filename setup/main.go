package main

import (
	"context"
	"crypto/rand"
	"database/sql"
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

	mysqlDriver "github.com/go-sql-driver/mysql"
)

var workspace = "/workspace"
var envPath = "/workspace/.env"

var identifierPattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]{0,63}$`)
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

type databaseTestRequest struct {
	Host         string `json:"host"`
	Port         int    `json:"port"`
	DatabaseName string `json:"databaseName"`
	Username     string `json:"username"`
	Password     string `json:"password"`
}

type setupRequest struct {
	MySQLAdminHost       string `json:"mysqlAdminHost"`
	MySQLAdminPort       int    `json:"mysqlAdminPort"`
	MySQLAdminUsername   string `json:"mysqlAdminUsername"`
	MySQLAdminPassword   string `json:"mysqlAdminPassword"`
	MySQLAppHost         string `json:"mysqlAppHost"`
	MySQLAppPort         int    `json:"mysqlAppPort"`
	DatabaseName         string `json:"databaseName"`
	AppUsername          string `json:"appUsername"`
	AppPassword          string `json:"appPassword"`
	AppPasswordConfirm   string `json:"appPasswordConfirm"`
	PublicBaseURL        string `json:"publicBaseUrl"`
	AllowedOrigins       string `json:"allowedOrigins"`
	SiteName             string `json:"siteName"`
	Timezone             string `json:"timezone"`
	WebPort              int    `json:"webPort"`
	WebBindAddress       string `json:"webBindAddress"`
	AdminUsername        string `json:"adminUsername"`
	AdminPassword        string `json:"adminPassword"`
	AdminPasswordConfirm string `json:"adminPasswordConfirm"`
}

func main() {
	if configuredWorkspace := strings.TrimSpace(os.Getenv("SETUP_WORKSPACE")); configuredWorkspace != "" {
		workspace = filepath.Clean(configuredWorkspace)
		envPath = filepath.Join(workspace, ".env")
	}
	service := &setupService{}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/setup/status", service.status)
	mux.HandleFunc("/api/setup/test-database", service.testDatabase)
	mux.HandleFunc("/api/setup/complete", service.complete)

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

func (s *setupService) status(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	configured := configuredEnv()
	state := "ready"
	message := "等待首次安装配置"
	if s.applying {
		state = "applying"
		message = "正在应用配置并启动服务"
		configured = false
	} else if configured {
		state = "configured"
		message = "安装已完成"
	} else if s.lastErr != "" {
		state = "error"
		message = s.lastErr
	}
	writeJSON(w, http.StatusOK, setupStatus{Configured: configured, State: state, Message: message, BaseURL: s.baseURL})
}

func (s *setupService) testDatabase(w http.ResponseWriter, r *http.Request) {
	if configuredEnv() {
		writeError(w, http.StatusConflict, "系统已经完成安装")
		return
	}
	var request databaseTestRequest
	if err := decodeJSON(r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "数据库连接信息格式不正确")
		return
	}
	if err := validateDatabaseTest(request); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	db, err := openMySQL(ctx, request.Host, request.Port, request.Username, request.Password, "")
	if err != nil {
		writeError(w, http.StatusBadRequest, "无法连接 MySQL，请检查地址、端口、账号、密码和防火墙")
		return
	}
	defer db.Close()
	var databaseExists int
	if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = ?", request.DatabaseName).Scan(&databaseExists); err != nil {
		writeError(w, http.StatusBadRequest, "MySQL 已连接，但无法检查目标数据库，请确认账号具有元数据读取权限")
		return
	}
	if databaseExists != 0 {
		writeError(w, http.StatusConflict, fmt.Sprintf("MySQL 管理连接成功，但数据库 %s 已存在，请换一个未使用的数据库名", request.DatabaseName))
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"message": "MySQL 管理连接成功，目标数据库可创建"})
}

func (s *setupService) complete(w http.ResponseWriter, r *http.Request) {
	if configuredEnv() {
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

	if err := provisionDatabase(r.Context(), request); err != nil {
		s.mu.Lock()
		s.applying = false
		s.lastErr = err.Error()
		s.mu.Unlock()
		writeError(w, http.StatusBadRequest, err.Error())
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
	writeJSON(w, http.StatusAccepted, setupStatus{State: "applying", Message: "数据库和配置已完成，正在重建服务", BaseURL: request.PublicBaseURL})
}

func (s *setupService) applyCompose() {
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Minute)
	defer cancel()
	command := exec.CommandContext(ctx, "docker", "compose", "--project-directory", workspace, "--env-file", envPath, "up", "-d", "--build", "server", "web")
	command.Env = append(os.Environ(), "COMPOSE_PROJECT_NAME=guanlan-monitor")
	if output, err := command.CombinedOutput(); err != nil {
		log.Printf("compose apply failed: %v (%d bytes)", err, len(output))
		s.mu.Lock()
		s.applying = false
		s.lastErr = "服务重建失败，请检查 Docker 日志后重试"
		s.mu.Unlock()
		return
	}
	s.mu.Lock()
	s.applying = false
	s.lastErr = ""
	s.mu.Unlock()
}

func provisionDatabase(ctx context.Context, request setupRequest) error {
	db, err := openMySQL(ctx, request.MySQLAdminHost, request.MySQLAdminPort, request.MySQLAdminUsername, request.MySQLAdminPassword, "")
	if err != nil {
		return errors.New("无法连接 MySQL，请检查管理地址、端口、账号、密码和防火墙")
	}
	defer db.Close()

	var databaseExists int
	if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = ?", request.DatabaseName).Scan(&databaseExists); err != nil {
		return errors.New("无法检查目标数据库，请确认管理账号具有元数据读取权限")
	}
	if databaseExists != 0 {
		return fmt.Errorf("数据库 %s 已存在，为避免覆盖数据安装已停止", request.DatabaseName)
	}
	var userExists int
	if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM mysql.user WHERE User = ?", request.AppUsername).Scan(&userExists); err != nil {
		return errors.New("无法检查应用用户，请确认管理账号具有用户读取权限")
	}
	if userExists != 0 {
		return fmt.Errorf("应用用户 %s 已存在，为避免修改账号安装已停止", request.AppUsername)
	}

	databaseIdentifier := quoteIdentifier(request.DatabaseName)
	userLiteral := quoteLiteral(request.AppUsername)
	passwordLiteral := quoteLiteral(request.AppPassword)
	statements := []string{
		fmt.Sprintf("CREATE DATABASE %s CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci", databaseIdentifier),
		fmt.Sprintf("CREATE USER %s@'%%' IDENTIFIED BY %s", userLiteral, passwordLiteral),
		fmt.Sprintf("GRANT ALL PRIVILEGES ON %s.* TO %s@'%%'", databaseIdentifier, userLiteral),
		"FLUSH PRIVILEGES",
	}
	for _, statement := range statements {
		if _, err := db.ExecContext(ctx, statement); err != nil {
			return errors.New("创建数据库或应用用户失败，请检查 MySQL 管理权限")
		}
	}

	appDB, err := openMySQL(ctx, request.MySQLAppHost, request.MySQLAppPort, request.AppUsername, request.AppPassword, request.DatabaseName)
	if err != nil {
		return errors.New("数据库已创建，但应用连接测试失败，请检查容器连接地址和 MySQL 监听配置")
	}
	defer appDB.Close()
	return nil
}

func openMySQL(ctx context.Context, host string, port int, username, password, database string) (*sql.DB, error) {
	host = strings.Trim(host, "[]")
	config := mysqlDriver.NewConfig()
	config.User = username
	config.Passwd = password
	config.Net = "tcp"
	config.Addr = net.JoinHostPort(host, strconv.Itoa(port))
	config.DBName = database
	config.ParseTime = true
	config.Timeout = 8 * time.Second
	config.ReadTimeout = 8 * time.Second
	config.WriteTimeout = 8 * time.Second
	dsn := config.FormatDSN()
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, err
	}
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func writeEnvironment(request setupRequest) error {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return err
	}
	settingsKey := base64.StdEncoding.EncodeToString(key)
	lines := []string{
		"# Generated by the browser setup wizard. Keep this file private.",
		"SPRING_PROFILES_ACTIVE=production",
		"DB_URL=" + dotenvValue(fmt.Sprintf("jdbc:mysql://%s:%d/%s?useUnicode=true&characterEncoding=utf8&serverTimezone=UTC", request.MySQLAppHost, request.MySQLAppPort, request.DatabaseName)),
		"DB_USERNAME=" + dotenvValue(request.AppUsername),
		"DB_PASSWORD=" + dotenvValue(request.AppPassword),
		"BOOTSTRAP_ADMIN_USERNAME=" + dotenvValue(request.AdminUsername),
		"BOOTSTRAP_ADMIN_PASSWORD=" + dotenvValue(request.AdminPassword),
		"SETTINGS_ENCRYPTION_KEY=" + dotenvValue(settingsKey),
		"WEB_PORT=" + dotenvValue(strconv.Itoa(request.WebPort)),
		"WEB_BIND_ADDRESS=" + dotenvValue(request.WebBindAddress),
		"APP_TIMEZONE=" + dotenvValue(request.Timezone),
		"SITE_NAME=" + dotenvValue(request.SiteName),
		"PUBLIC_BASE_URL=" + dotenvValue(request.PublicBaseURL),
		"SESSION_COOKIE_SECURE=" + dotenvValue(strconv.FormatBool(strings.HasPrefix(request.PublicBaseURL, "https://"))),
		"ALLOW_INSECURE_HTTP=" + dotenvValue(strconv.FormatBool(strings.HasPrefix(request.PublicBaseURL, "http://"))),
		"ALLOWED_ORIGINS=" + dotenvValue(request.AllowedOrigins),
		"METRIC_RETENTION_DAYS=30",
		"DEVICE_OFFLINE_AFTER_SECONDS=30",
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

func configuredEnv() bool {
	values, err := readEnv()
	if err != nil {
		return false
	}
	return values["SPRING_PROFILES_ACTIVE"] == "production" &&
		strings.HasPrefix(values["DB_URL"], "jdbc:mysql://") &&
		values["DB_USERNAME"] != "" && values["DB_PASSWORD"] != "" &&
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

func validateDatabaseTest(request databaseTestRequest) error {
	if err := validateHostPort(request.Host, request.Port); err != nil {
		return err
	}
	if !identifierPattern.MatchString(request.DatabaseName) {
		return errors.New("数据库名必须以字母开头，只能包含字母、数字和下划线")
	}
	if strings.TrimSpace(request.Username) == "" || request.Password == "" {
		return errors.New("请输入 MySQL 管理账号和密码")
	}
	return nil
}

func validateSetupRequest(request setupRequest) error {
	if err := validateDatabaseTest(databaseTestRequest{Host: request.MySQLAdminHost, Port: request.MySQLAdminPort, DatabaseName: request.DatabaseName, Username: request.MySQLAdminUsername, Password: request.MySQLAdminPassword}); err != nil {
		return err
	}
	if err := validateHostPort(request.MySQLAppHost, request.MySQLAppPort); err != nil {
		return errors.New("容器连接 MySQL 地址或端口无效")
	}
	if !identifierPattern.MatchString(request.DatabaseName) {
		return errors.New("数据库名必须以字母开头，只能包含字母、数字和下划线")
	}
	if !identifierPattern.MatchString(request.AppUsername) {
		return errors.New("应用数据库用户名格式无效")
	}
	if len(request.AppPassword) < 12 || request.AppPassword != request.AppPasswordConfirm {
		return errors.New("应用数据库密码至少 12 位且两次输入必须一致")
	}
	if len(request.AdminPassword) < 12 || request.AdminPassword != request.AdminPasswordConfirm {
		return errors.New("管理员密码至少 12 位且两次输入必须一致")
	}
	if !usernamePattern.MatchString(request.AdminUsername) {
		return errors.New("管理员用户名格式无效")
	}
	parsedURL, err := url.Parse(request.PublicBaseURL)
	if err != nil || parsedURL.Host == "" || parsedURL.RawQuery != "" || parsedURL.Fragment != "" || (parsedURL.Scheme != "http" && parsedURL.Scheme != "https") {
		return errors.New("公网入口必须是有效的 HTTP 或 HTTPS 地址")
	}
	if strings.TrimSpace(request.AllowedOrigins) == "" || strings.TrimSpace(request.SiteName) == "" || len(request.SiteName) > 80 || strings.TrimSpace(request.Timezone) == "" {
		return errors.New("请完整填写来源、站点名称和时区")
	}
	if request.WebPort < 1 || request.WebPort > 65535 {
		return errors.New("Web 端口无效")
	}
	if request.WebBindAddress != "0.0.0.0" && request.WebBindAddress != "127.0.0.1" {
		return errors.New("Web 绑定地址只支持 0.0.0.0 或 127.0.0.1")
	}
	return nil
}

func validateHostPort(host string, port int) error {
	host = strings.TrimSpace(host)
	if host == "" || strings.ContainsAny(host, " /?#") || port < 1 || port > 65535 {
		return errors.New("MySQL 地址或端口无效")
	}
	return nil
}

func quoteIdentifier(value string) string {
	return "`" + strings.ReplaceAll(value, "`", "``") + "`"
}

func quoteLiteral(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	value = strings.ReplaceAll(value, "'", "''")
	return "'" + value + "'"
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
