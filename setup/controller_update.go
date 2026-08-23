package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const controllerUpdateRunnerName = "guanlan-controller-update-run"

const (
	controllerUpdateCheckTimeout       = 15 * time.Minute
	controllerUpdateApplyTimeout       = 45 * time.Minute
	controllerUpdateRunnerStartTimeout = 30 * time.Second
	controllerUpdateInspectTimeout     = 2 * time.Second
	controllerUpdateInspectionCache    = 2 * time.Second
	controllerUpdateCheckStaleAfter    = 20 * time.Minute
	controllerUpdateApplyStaleAfter    = 75 * time.Minute
)

type controllerUpdateService struct {
	mu      sync.Mutex
	running bool
	token   string
	now     func() time.Time
}

type controllerUpdateState struct {
	State            string                    `json:"state"`
	CurrentRevision  string                    `json:"currentRevision,omitempty"`
	LatestRevision   string                    `json:"latestRevision,omitempty"`
	UpdateAvailable  bool                      `json:"updateAvailable"`
	Message          string                    `json:"message,omitempty"`
	CheckedAt        string                    `json:"checkedAt,omitempty"`
	UpdatedAt        string                    `json:"updatedAt,omitempty"`
	StartedAt        string                    `json:"startedAt,omitempty"`
	AutoUpdate       bool                      `json:"autoUpdate"`
	NextAutoUpdateAt string                    `json:"nextAutoUpdateAt,omitempty"`
	LastAutoRunDate  string                    `json:"lastAutoRunDate,omitempty"`
	Services         []controllerServiceStatus `json:"services"`
}

type controllerInspection struct {
	current  string
	latest   string
	services []controllerServiceStatus
}

var controllerInspectionCache struct {
	sync.Mutex
	at    time.Time
	value controllerInspection
}

type controllerServiceStatus struct {
	Name     string `json:"name"`
	Revision string `json:"revision,omitempty"`
	Health   string `json:"health"`
}

type autoUpdateRequest struct {
	Enabled bool `json:"enabled"`
}

type controllerImage struct {
	service      string
	environment  string
	defaultImage string
}

var controllerImages = []controllerImage{
	{service: "setup", environment: "GUANLAN_SETUP_IMAGE", defaultImage: "ghcr.io/pstarchen/monitor-for-server-setup:latest"},
	{service: "server", environment: "GUANLAN_SERVER_IMAGE", defaultImage: "ghcr.io/pstarchen/monitor-for-server-server:latest"},
	{service: "web", environment: "GUANLAN_WEB_IMAGE", defaultImage: "ghcr.io/pstarchen/monitor-for-server-web:latest"},
}

func newControllerUpdateService() *controllerUpdateService {
	return &controllerUpdateService{
		token: strings.TrimSpace(os.Getenv("CONTROLLER_UPDATE_TOKEN")),
		now:   time.Now,
	}
}

func (s *controllerUpdateService) register(mux *http.ServeMux) {
	mux.Handle("/internal/controller-update/status", s.authorize(http.HandlerFunc(s.status)))
	mux.Handle("/internal/controller-update/check", s.authorize(http.HandlerFunc(s.check)))
	mux.Handle("/internal/controller-update/apply", s.authorize(http.HandlerFunc(s.apply)))
	mux.Handle("/internal/controller-update/auto", s.authorize(http.HandlerFunc(s.auto)))
}

func (s *controllerUpdateService) authorize(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		provided := strings.TrimSpace(r.Header.Get("X-Controller-Update-Token"))
		if s.token == "" || !constantTimeEqual(provided, s.token) {
			writeError(w, http.StatusUnauthorized, "内部更新服务认证失败")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func constantTimeEqual(left, right string) bool {
	leftHash := sha256.Sum256([]byte(left))
	rightHash := sha256.Sum256([]byte(right))
	return subtle.ConstantTimeCompare(leftHash[:], rightHash[:]) == 1
}

func (s *controllerUpdateService) status(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, s.snapshot())
}

func (s *controllerUpdateService) check(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}
	if err := s.begin("CHECKING", "正在从镜像源检查总控更新"); err != nil {
		if errors.Is(err, errUpdateRunning) {
			writeError(w, http.StatusConflict, err.Error())
		} else {
			writeError(w, http.StatusInternalServerError, "更新状态保存失败")
		}
		return
	}
	go s.runCheck()
	writeJSON(w, http.StatusAccepted, s.snapshot())
}

func (s *controllerUpdateService) apply(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}
	if err := s.startUpdate(false); err != nil {
		if errors.Is(err, errUpdateRunning) {
			writeError(w, http.StatusConflict, err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusAccepted, s.snapshot())
}

func (s *controllerUpdateService) auto(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		methodNotAllowed(w, http.MethodPut)
		return
	}
	var request autoUpdateRequest
	if err := decodeJSON(r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "自动更新设置格式不正确")
		return
	}
	if err := updateEnvironmentSetting("CONTROLLER_AUTO_UPDATE", fmt.Sprintf("%t", request.Enabled)); err != nil {
		log.Printf("controller auto-update setting failed: %v", err)
		writeError(w, http.StatusInternalServerError, "自动更新设置保存失败")
		return
	}
	state := s.readState()
	state.AutoUpdate = request.Enabled
	state.Message = map[bool]string{true: "已启用每日自动更新", false: "已关闭自动更新"}[request.Enabled]
	s.decorate(&state)
	_ = writeControllerUpdateState(state)
	writeJSON(w, http.StatusOK, state)
}

var errUpdateRunning = errors.New("已有更新任务正在执行")

func (s *controllerUpdateService) begin(stateName, message string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	state := s.readState()
	if s.running || ((state.State == "CHECKING" || state.State == "UPDATING") && !s.isStale(state)) {
		return errUpdateRunning
	}
	s.running = true
	state.State = stateName
	state.StartedAt = s.currentTime().UTC().Format(time.RFC3339)
	state.Message = message
	state.UpdateAvailable = false
	s.decorate(&state)
	if err := writeControllerUpdateState(state); err != nil {
		s.running = false
		return err
	}
	return nil
}

func (s *controllerUpdateService) finish() {
	s.mu.Lock()
	s.running = false
	s.mu.Unlock()
}

func (s *controllerUpdateService) runCheck() {
	defer s.finish()
	ctx, cancel := context.WithTimeout(context.Background(), controllerUpdateCheckTimeout)
	defer cancel()
	command := updateControllerCommand(ctx, "--check")
	command.Env = append(os.Environ(), "COMPOSE_PROJECT_NAME="+environmentValue("COMPOSE_PROJECT_NAME", "guanlan-monitor"))
	output, err := command.CombinedOutput()
	state := s.readState()
	state.CheckedAt = s.currentTime().UTC().Format(time.RFC3339)
	if err != nil {
		log.Printf("controller update check failed: %v (%d bytes)", err, len(output))
		state.State = "ERROR"
		state.StartedAt = ""
		state.Message = "检查更新失败，请检查镜像源与 Docker 状态"
	} else {
		state.State = "IDLE"
		state.StartedAt = ""
		invalidateControllerInspectionCache()
		s.decorate(&state)
		state.Message = map[bool]string{true: "发现可用的总控更新", false: "当前已经是最新版本"}[state.UpdateAvailable]
	}
	if err := writeControllerUpdateState(state); err != nil {
		log.Printf("controller update state write failed: %v", err)
	}
}

func (s *controllerUpdateService) startUpdate(automatic bool) error {
	if err := s.begin("UPDATING", "正在更新总控服务，控制台将短暂重启"); err != nil {
		return err
	}
	state := s.readState()
	if automatic {
		state.LastAutoRunDate = s.localNow().Format("2006-01-02")
		if err := writeControllerUpdateState(state); err != nil {
			s.finish()
			return fmt.Errorf("save automatic update state: %w", err)
		}
	}
	go s.launchUpdateRunner()
	return nil
}

func (s *controllerUpdateService) launchUpdateRunner() {
	defer s.finish()
	args := composeBaseArgs()
	args = append(args, controllerUpdateRunnerArgs()...)
	ctx, cancel := context.WithTimeout(context.Background(), controllerUpdateRunnerStartTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, "docker", args...)
	command.Env = append(os.Environ(), "COMPOSE_PROJECT_NAME="+environmentValue("COMPOSE_PROJECT_NAME", "guanlan-monitor"))
	output, err := command.CombinedOutput()
	if err == nil {
		return
	}
	log.Printf("controller update runner start failed: %v (%d bytes)", err, len(output))
	state := s.readState()
	state.State = "ERROR"
	state.StartedAt = ""
	state.Message = "更新任务启动失败，请检查 Docker 状态"
	_ = writeControllerUpdateState(state)
}

func (s *controllerUpdateService) runUpdate() error {
	state := s.readState()
	state.State = "UPDATING"
	state.Message = "正在拉取镜像并重启总控服务"
	s.decorate(&state)
	_ = writeControllerUpdateState(state)

	ctx, cancel := context.WithTimeout(context.Background(), controllerUpdateApplyTimeout)
	defer cancel()
	command := updateControllerCommand(ctx, "--apply")
	command.Env = append(os.Environ(), "COMPOSE_PROJECT_NAME="+environmentValue("COMPOSE_PROJECT_NAME", "guanlan-monitor"))
	output, err := command.CombinedOutput()
	state = s.readState()
	if err != nil {
		log.Printf("controller update failed: %v (%d bytes)", err, len(output))
		state.State = "ERROR"
		state.StartedAt = ""
		state.Message = "总控更新失败，现有数据未被删除"
		_ = writeControllerUpdateState(state)
		return errors.New(state.Message)
	}
	state.State = "IDLE"
	state.StartedAt = ""
	state.Message = "总控服务已更新"
	state.UpdatedAt = s.currentTime().UTC().Format(time.RFC3339)
	state.CheckedAt = state.UpdatedAt
	invalidateControllerInspectionCache()
	s.decorate(&state)
	state.LatestRevision = state.CurrentRevision
	state.UpdateAvailable = false
	return writeControllerUpdateState(state)
}

func (s *controllerUpdateService) snapshot() controllerUpdateState {
	state := s.readState()
	s.mu.Lock()
	running := s.running
	s.mu.Unlock()
	if !running && s.isStale(state) {
		state.State = "ERROR"
		state.StartedAt = ""
		state.UpdateAvailable = false
		state.Message = "上次更新任务已超时，状态已恢复，请重新检查"
		if err := writeControllerUpdateState(state); err != nil {
			log.Printf("controller stale update state write failed: %v", err)
		}
	}
	s.decorate(&state)
	return state
}

func (s *controllerUpdateService) isStale(state controllerUpdateState) bool {
	if state.State != "CHECKING" && state.State != "UPDATING" {
		return false
	}
	if state.StartedAt == "" {
		return true
	}
	started, err := time.Parse(time.RFC3339, state.StartedAt)
	if err != nil {
		return true
	}
	limit := controllerUpdateCheckStaleAfter
	if state.State == "UPDATING" {
		limit = controllerUpdateApplyStaleAfter
	}
	return s.currentTime().UTC().Sub(started) > limit
}

func (s *controllerUpdateService) currentTime() time.Time {
	if s.now != nil {
		return s.now()
	}
	return time.Now()
}

func (s *controllerUpdateService) decorate(state *controllerUpdateState) {
	state.AutoUpdate = strings.EqualFold(configuredEnvironmentValue("CONTROLLER_AUTO_UPDATE"), "true")
	state.NextAutoUpdateAt = s.nextAutoUpdate().UTC().Format(time.RFC3339)
	current, latest, services := inspectControllerImages()
	state.CurrentRevision = current
	state.LatestRevision = latest
	state.Services = services
	state.UpdateAvailable = current != "" && latest != "" && current != latest
}

func (s *controllerUpdateService) readState() controllerUpdateState {
	state := controllerUpdateState{State: "IDLE", Message: "尚未检查更新", Services: []controllerServiceStatus{}}
	content, err := os.ReadFile(controllerUpdateStatePath)
	if err == nil {
		if json.Unmarshal(content, &state) != nil {
			state = controllerUpdateState{State: "ERROR", Message: "更新状态文件无法读取", Services: []controllerServiceStatus{}}
		}
	}
	return state
}

func writeControllerUpdateState(state controllerUpdateState) error {
	content, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(workspace, ".controller-update-state-*")
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(append(content, '\n')); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryName, controllerUpdateStatePath)
}

func inspectControllerImages() (string, string, []controllerServiceStatus) {
	controllerInspectionCache.Lock()
	if !controllerInspectionCache.at.IsZero() && time.Since(controllerInspectionCache.at) < controllerUpdateInspectionCache {
		value := controllerInspectionCache.value
		controllerInspectionCache.Unlock()
		return value.current, value.latest, append([]controllerServiceStatus(nil), value.services...)
	}
	controllerInspectionCache.Unlock()

	values, _ := readEnv()
	statuses := make([]controllerServiceStatus, 0, len(controllerImages))
	results := make([]struct {
		status  controllerServiceStatus
		current string
		latest  string
	}, len(controllerImages))
	var wait sync.WaitGroup
	for index, image := range controllerImages {
		wait.Add(1)
		go func(index int, image controllerImage) {
			defer wait.Done()
			composeArgs := append(composeBaseArgs(), "ps", "-q", image.service)
			containerID := commandOutput("docker", composeArgs...)
			current := ""
			health := "not_found"
			if containerID != "" {
				current = inspectReference(containerID, false)
				health = commandOutput("docker", "inspect", "--format", "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}", containerID)
			}
			imageReference := strings.TrimSpace(os.Getenv(image.environment))
			if imageReference == "" {
				imageReference = strings.TrimSpace(values[image.environment])
			}
			if imageReference == "" {
				imageReference = image.defaultImage
			}
			results[index] = struct {
				status  controllerServiceStatus
				current string
				latest  string
			}{controllerServiceStatus{Name: image.service, Revision: current, Health: health}, current, inspectReference(imageReference, true)}
		}(index, image)
	}
	wait.Wait()
	currentRevision := ""
	latestRevision := ""
	for _, result := range results {
		statuses = append(statuses, result.status)
		if result.status.Name == "server" || currentRevision == "" {
			currentRevision = result.current
		}
		if result.status.Name == "server" || latestRevision == "" {
			latestRevision = result.latest
		}
	}
	value := controllerInspection{current: currentRevision, latest: latestRevision, services: append([]controllerServiceStatus(nil), statuses...)}
	controllerInspectionCache.Lock()
	controllerInspectionCache.at = time.Now()
	controllerInspectionCache.value = value
	controllerInspectionCache.Unlock()
	return currentRevision, latestRevision, statuses
}

func invalidateControllerInspectionCache() {
	controllerInspectionCache.Lock()
	controllerInspectionCache.at = time.Time{}
	controllerInspectionCache.Unlock()
}

func inspectReference(reference string, image bool) string {
	fallback := ".Image"
	if image {
		fallback = ".Id"
	}
	format := fmt.Sprintf(`{{index .Config.Labels "org.opencontainers.image.revision"}}|{{%s}}`, fallback)
	args := []string{"inspect", "--format", format, reference}
	if image {
		args = append([]string{"image"}, args...)
	}
	value := commandOutput("docker", args...)
	parts := strings.SplitN(value, "|", 2)
	if len(parts) > 0 && strings.TrimSpace(parts[0]) != "" && strings.TrimSpace(parts[0]) != "<no value>" {
		return strings.TrimSpace(parts[0])
	}
	if len(parts) == 2 {
		return strings.TrimPrefix(strings.TrimSpace(parts[1]), "sha256:")
	}
	return ""
}

func commandOutput(name string, args ...string) string {
	ctx, cancel := context.WithTimeout(context.Background(), controllerUpdateInspectTimeout)
	defer cancel()
	output, err := exec.CommandContext(ctx, name, args...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}

func updateControllerCommand(ctx context.Context, mode string) *exec.Cmd {
	// The script is bind-mounted from the host and may not retain its executable bit.
	return exec.CommandContext(ctx, "bash", filepath.Join(workspace, "deploy", "update-controller.sh"), mode)
}

func controllerUpdateRunnerArgs() []string {
	return []string{"run", "-d", "--rm", "--no-deps", "-e", "CONTROLLER_UPDATE_RUNNER=true", "--name", controllerUpdateRunnerName, "setup", "update-runner"}
}

func composeBaseArgs() []string {
	return []string{"compose", "--project-directory", workspace, "--env-file", envPath}
}

func updateEnvironmentSetting(key, value string) error {
	content, err := os.ReadFile(envPath)
	if err != nil {
		return err
	}
	lines := strings.Split(strings.ReplaceAll(string(content), "\r\n", "\n"), "\n")
	replacement := key + "=" + dotenvValue(value)
	found := false
	for index, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), key+"=") {
			lines[index] = replacement
			found = true
		}
	}
	if !found {
		if len(lines) > 0 && lines[len(lines)-1] == "" {
			lines = lines[:len(lines)-1]
		}
		lines = append(lines, replacement)
	}
	temporary, err := os.CreateTemp(filepath.Dir(envPath), ".env.controller-update-*")
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.WriteString(strings.Join(lines, "\n") + "\n"); err != nil {
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

func (s *controllerUpdateService) runScheduler() {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		s.maybeRunAutomaticUpdate()
		<-ticker.C
	}
}

func (s *controllerUpdateService) maybeRunAutomaticUpdate() {
	if !strings.EqualFold(configuredEnvironmentValue("CONTROLLER_AUTO_UPDATE"), "true") {
		return
	}
	now := s.localNow()
	state := s.readState()
	if now.Hour() < 4 || state.LastAutoRunDate == now.Format("2006-01-02") {
		return
	}
	if err := s.startUpdate(true); err != nil && !errors.Is(err, errUpdateRunning) {
		log.Printf("automatic controller update could not start: %v", err)
	}
}

func (s *controllerUpdateService) localNow() time.Time {
	locationName := configuredEnvironmentValue("APP_TIMEZONE")
	if locationName == "" {
		locationName = environmentValue("APP_TIMEZONE", "Asia/Shanghai")
	}
	location, err := time.LoadLocation(locationName)
	if err != nil {
		location = time.Local
	}
	return s.currentTime().In(location)
}

func (s *controllerUpdateService) nextAutoUpdate() time.Time {
	now := s.localNow()
	next := time.Date(now.Year(), now.Month(), now.Day(), 4, 0, 0, 0, now.Location())
	if !next.After(now) {
		next = next.AddDate(0, 0, 1)
	}
	return next
}

func methodNotAllowed(w http.ResponseWriter, allowed string) {
	w.Header().Set("Allow", allowed)
	writeError(w, http.StatusMethodNotAllowed, "请求方法不受支持")
}
