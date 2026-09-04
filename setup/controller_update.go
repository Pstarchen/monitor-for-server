package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const controllerUpdateRunnerName = "xingchen-controller-update-run"
const controllerUpdateRunnerProjectSuffix = "-update-runner"

// This opt-in is intentionally not exposed by the production Compose service.
const controllerUpdateWorkspaceFallbackEnvironment = "XINGCHEN_CONTROLLER_UPDATE_ALLOW_WORKSPACE_FALLBACK"

var packagedControllerUpdaterPath = "/usr/local/share/xingchen/updaters/update-controller.sh"

const (
	controllerUpdateCheckTimeout       = controllerReleaseCheckTimeout
	controllerUpdateApplyTimeout       = 4 * time.Hour
	controllerUpdateRunnerStartTimeout = 30 * time.Second
	controllerUpdateRunnerGracePeriod  = 2 * time.Minute
	controllerUpdateInspectTimeout     = 2 * time.Second
	controllerUpdateInspectionCache    = 2 * time.Second
	controllerUpdateCheckStaleAfter    = controllerUpdateCheckTimeout + 2*time.Minute
	controllerUpdateApplyStaleAfter    = 4*time.Hour + 15*time.Minute
	controllerAutoFailureLimit         = 3
	controllerAutoPauseDuration        = 24 * time.Hour
)

type controllerUpdateService struct {
	mu             sync.Mutex
	running        bool
	token          string
	now            func() time.Time
	client         *http.Client
	apiBase        string
	giteeAPIBase   string
	releases       *agentReleaseService
	allowGitHubAPI bool
	networkMode    string
	allowGitee     bool
	startRunner    func() ([]byte, error)
	waitRunner     func() bool
}

type controllerUpdateState struct {
	State                 string                    `json:"state"`
	CurrentRevision       string                    `json:"currentRevision,omitempty"`
	LatestRevision        string                    `json:"latestRevision,omitempty"`
	CurrentVersion        string                    `json:"currentVersion,omitempty"`
	VersionRevision       string                    `json:"versionRevision,omitempty"`
	LatestVersion         string                    `json:"latestVersion,omitempty"`
	UpdateAvailable       bool                      `json:"updateAvailable"`
	Message               string                    `json:"message,omitempty"`
	ReleaseName           string                    `json:"releaseName,omitempty"`
	ReleaseNotes          string                    `json:"releaseNotes,omitempty"`
	ReleaseURL            string                    `json:"releaseUrl,omitempty"`
	ReleasePublishedAt    string                    `json:"releasePublishedAt,omitempty"`
	ReleaseFetchedAt      string                    `json:"releaseFetchedAt,omitempty"`
	ReleaseCached         bool                      `json:"releaseCached,omitempty"`
	ReleaseWarning        string                    `json:"releaseWarning,omitempty"`
	ReleaseSource         string                    `json:"releaseSource,omitempty"`
	ReleaseVerification   string                    `json:"releaseVerification,omitempty"`
	NetworkMode           string                    `json:"networkMode"`
	CheckedAt             string                    `json:"checkedAt,omitempty"`
	UpdatedAt             string                    `json:"updatedAt,omitempty"`
	StartedAt             string                    `json:"startedAt,omitempty"`
	AutoUpdate            bool                      `json:"autoUpdate"`
	AutoFailureCount      int                       `json:"autoFailureCount"`
	AutoPaused            bool                      `json:"autoPaused"`
	AutoPausedUntil       string                    `json:"autoPausedUntil,omitempty"`
	NextAutoUpdateAt      string                    `json:"nextAutoUpdateAt,omitempty"`
	LastAutoRunDate       string                    `json:"lastAutoRunDate,omitempty"`
	Trigger               string                    `json:"trigger,omitempty"`
	Services              []controllerServiceStatus `json:"services"`
	Phase                 string                    `json:"phase,omitempty"`
	RollbackState         string                    `json:"rollbackState,omitempty"`
	BackupName            string                    `json:"backupName,omitempty"`
	DatabaseCompatibility string                    `json:"databaseCompatibility,omitempty"`
}

type controllerInspection struct {
	current  string
	latest   string
	version  string
	services []controllerServiceStatus
}

var controllerInspectionCache struct {
	sync.Mutex
	at    time.Time
	value controllerInspection
}

var controllerUpdateStateProcessLock sync.Mutex

type controllerAutomaticStateWrite int

const (
	preserveControllerAutomaticState controllerAutomaticStateWrite = iota
	recordControllerAutomaticFailure
	resetControllerAutomaticFailures
)

type controllerServiceStatus struct {
	Name     string `json:"name"`
	Revision string `json:"revision,omitempty"`
	Version  string `json:"version,omitempty"`
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
	{service: "setup", environment: "XINGCHEN_SETUP_IMAGE", defaultImage: "ghcr.io/pstarchen/monitor-for-server-setup:v1.20.17"},
	{service: "server", environment: "XINGCHEN_SERVER_IMAGE", defaultImage: "ghcr.io/pstarchen/monitor-for-server-server:v1.20.17"},
	{service: "web", environment: "XINGCHEN_WEB_IMAGE", defaultImage: "ghcr.io/pstarchen/monitor-for-server-web:v1.20.17"},
}

func newControllerUpdateService() *controllerUpdateService {
	return &controllerUpdateService{
		token:          strings.TrimSpace(os.Getenv("CONTROLLER_UPDATE_TOKEN")),
		now:            time.Now,
		client:         &http.Client{Timeout: controllerReleaseCheckTimeout},
		apiBase:        controllerGitHubAPIBase,
		giteeAPIBase:   controllerGiteeAPIBase,
		releases:       newAgentReleaseService(),
		allowGitHubAPI: strings.EqualFold(strings.TrimSpace(os.Getenv("XINGCHEN_CONTROLLER_ALLOW_GITHUB_API")), "true"),
		networkMode:    configuredNetworkMode(),
		allowGitee:     configuredGiteeAllowed(),
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
	if err := s.begin("CHECKING", "正在从发布源检查总控更新"); err != nil {
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
	mode := s.effectiveNetworkMode()
	if !validNetworkMode(mode) {
		writeError(w, http.StatusBadRequest, "XINGCHEN_NETWORK_MODE 配置无效")
		return
	}
	if request.Enabled && mode == networkModeOffline {
		writeError(w, http.StatusBadRequest, "完全离线模式不能启用自动更新")
		return
	}
	if err := updateEnvironmentSetting("CONTROLLER_AUTO_UPDATE", fmt.Sprintf("%t", request.Enabled)); err != nil {
		log.Printf("controller auto-update setting failed: %v", err)
		writeError(w, http.StatusInternalServerError, "自动更新设置保存失败")
		return
	}
	state, err := mutateControllerUpdateState(func(state *controllerUpdateState) {
		state.AutoUpdate = request.Enabled
		if request.Enabled {
			s.resetAutomaticFailures(state)
		}
		if state.State != "CHECKING" && state.State != "UPDATING" {
			state.Message = map[bool]string{true: "已启用每日自动更新", false: "已关闭自动更新"}[request.Enabled]
		}
	})
	if err != nil {
		log.Printf("controller auto-update state failed: %v", err)
		writeError(w, http.StatusInternalServerError, "自动更新状态保存失败")
		return
	}
	s.decorate(&state)
	writeJSON(w, http.StatusOK, state)
}

var errUpdateRunning = errors.New("已有更新任务正在执行")

func (s *controllerUpdateService) begin(stateName, message string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.running {
		return errUpdateRunning
	}
	alreadyRunning := false
	_, err := mutateControllerUpdateState(func(state *controllerUpdateState) {
		if (state.State == "CHECKING" || state.State == "UPDATING") && !s.isStale(*state) {
			alreadyRunning = true
			return
		}
		state.State = stateName
		state.StartedAt = s.currentTime().UTC().Format(time.RFC3339)
		state.Message = message
		state.UpdateAvailable = false
	})
	if err != nil {
		return err
	}
	if alreadyRunning {
		return errUpdateRunning
	}
	s.running = true
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
	state := s.readState()
	if err := s.refreshReleaseState(ctx, &state, false); err != nil {
		log.Printf("controller release check failed: %v", err)
		state.State = "ERROR"
		state.StartedAt = ""
		state.Message = "检查更新失败，请检查版本清单源和缓存状态"
	} else {
		state.State = "IDLE"
		state.StartedAt = ""
		if state.CurrentVersion == "" {
			state.Message = "已获取最新发布，但无法识别当前运行版本"
		} else if state.ReleaseWarning != "" {
			state.Message = "发布源暂时不可用，已使用上次检查结果"
		} else if controllerVersionLess(state.LatestVersion, state.CurrentVersion) {
			state.Message = "当前运行版本高于最新公开 Release"
		} else {
			state.Message = map[bool]string{true: "发现可用的总控更新", false: "当前已经是最新版本"}[state.UpdateAvailable]
		}
	}
	state.CheckedAt = s.currentTime().UTC().Format(time.RFC3339)
	if err := s.writeRuntimeState(state, preserveControllerAutomaticState); err != nil {
		log.Printf("controller update state write failed: %v", err)
	}
}

func (s *controllerUpdateService) startUpdate(automatic bool) error {
	mode := s.effectiveNetworkMode()
	if !validNetworkMode(mode) {
		return errors.New("XINGCHEN_NETWORK_MODE 必须是 public、internal 或 offline")
	}
	if automatic && mode == networkModeOffline {
		return errors.New("完全离线模式不能执行自动更新")
	}
	if automatic && s.automaticUpdatePaused(s.readState()) {
		return errors.New("自动更新已暂停，可手动更新或重新启用自动更新")
	}
	if err := s.begin("UPDATING", "正在更新总控服务，控制台将短暂重启"); err != nil {
		return err
	}
	_, err := mutateControllerUpdateState(func(state *controllerUpdateState) {
		s.prepareUpdateState(state, automatic)
	})
	if err != nil {
		s.finish()
		if automatic {
			return fmt.Errorf("save automatic update state: %w", err)
		}
		return fmt.Errorf("save update state: %w", err)
	}
	go s.launchUpdateRunner()
	return nil
}

func (s *controllerUpdateService) launchUpdateRunner() {
	defer s.finish()
	output, err := s.startUpdateRunner()
	waitForRunner := s.waitForUpdateRunner
	if s.waitRunner != nil {
		waitForRunner = s.waitRunner
	}
	if err == nil && waitForRunner() {
		return
	}
	state := s.readState()
	// A detached Docker run can succeed even when the container exits before
	// the update-runner entrypoint starts. Do not leave the durable state stuck
	// in UPDATING in that case.
	if state.State != "UPDATING" {
		return
	}
	log.Printf("controller update runner start failed: %v (%d bytes)", err, len(output))
	state.State = "ERROR"
	state.StartedAt = ""
	state.Message = "更新任务启动失败，请检查 Docker 状态"
	_ = s.writeRuntimeState(state, recordControllerAutomaticFailure)
}

func (s *controllerUpdateService) startUpdateRunner() ([]byte, error) {
	if s.startRunner != nil {
		return s.startRunner()
	}
	args := composeBaseArgs()
	args = append(args, controllerUpdateRunnerArgs()...)
	ctx, cancel := context.WithTimeout(context.Background(), controllerUpdateRunnerStartTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, "docker", args...)
	command.Env = controllerUpdateEnvironment()
	return command.CombinedOutput()
}

func (s *controllerUpdateService) waitForUpdateRunner() bool {
	deadline := time.Now().Add(controllerUpdateRunnerStartTimeout)
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		status, known := controllerUpdateRunnerStatus()
		if !known {
			if time.Now().After(deadline) {
				return false
			}
			<-ticker.C
			continue
		}
		switch status {
		case "":
			return false
		case "created", "running", "restarting", "paused":
			return true
		case "exited", "dead", "removing":
			return false
		}
		if time.Now().After(deadline) {
			return false
		}
		<-ticker.C
	}
}

func (s *controllerUpdateService) runUpdate() error {
	state := s.readState()
	state.State = "UPDATING"
	state.Message = "正在确认目标版本"
	checkContext, cancelCheck := context.WithTimeout(context.Background(), controllerReleaseCheckTimeout)
	if err := s.refreshReleaseState(checkContext, &state, false); err != nil {
		cancelCheck()
		state.State = "ERROR"
		state.StartedAt = ""
		state.Message = "无法确认最新稳定版本，更新未执行"
		_ = s.writeRuntimeState(state, recordControllerAutomaticFailure)
		return errors.New(state.Message)
	}
	cancelCheck()
	if state.CurrentVersion == "" {
		state.State = "ERROR"
		state.StartedAt = ""
		state.Message = "无法识别当前运行版本，更新未执行"
		_ = s.writeRuntimeState(state, recordControllerAutomaticFailure)
		return errors.New(state.Message)
	}
	if state.CurrentVersion != "" && state.LatestVersion != "" && !state.UpdateAvailable {
		state.State = "IDLE"
		state.StartedAt = ""
		state.Message = "当前已经是最新版本"
		state.CheckedAt = s.currentTime().UTC().Format(time.RFC3339)
		return s.writeRuntimeState(state, resetControllerAutomaticFailures)
	}
	targetVersion := state.LatestVersion
	if state.Trigger == "automatic" && !controllerVersionsShareMajor(state.CurrentVersion, targetVersion) {
		state.State = "IDLE"
		state.Phase = "INCOMPATIBLE_VERSION"
		state.RollbackState = "NOT_REQUIRED"
		state.DatabaseCompatibility = "MANUAL_REVIEW_REQUIRED"
		state.StartedAt = ""
		state.Message = "发现新的主版本，已阻止自动更新；请评估兼容性后手动更新"
		state.CheckedAt = s.currentTime().UTC().Format(time.RFC3339)
		return s.writeRuntimeState(state, preserveControllerAutomaticState)
	}
	updaterPath, err := resolveControllerUpdaterPath()
	if err != nil {
		log.Printf("controller updater preflight failed: %v", err)
		state.State = "ERROR"
		state.Phase = "FAILED"
		state.RollbackState = "NOT_REQUIRED"
		state.DatabaseCompatibility = "NOT_EVALUATED"
		state.StartedAt = ""
		state.Message = "Setup 镜像内总控更新器不可用，更新未执行"
		_ = s.writeRuntimeState(state, recordControllerAutomaticFailure)
		return errors.New(state.Message)
	}
	state.Phase = "BACKUP"
	state.RollbackState = "NOT_REQUIRED"
	state.DatabaseCompatibility = "NOT_EVALUATED"
	state.Message = "正在创建更新前数据库备份"
	_ = s.writeRuntimeState(state, preserveControllerAutomaticState)
	backupTime := s.currentTime().UTC()
	backupName := fmt.Sprintf("xingchen-monitor-%s-%d.sql", backupTime.Format("20060102T150405Z"), backupTime.UnixNano())
	backupContext, cancelBackup := context.WithTimeout(context.Background(), controllerBackupCreateTimeout)
	backupPath, backupErr := createControllerBackup(backupContext, backupName)
	cancelBackup()
	backupSHA256 := ""
	if backupErr == nil {
		backupSHA256, backupErr = controllerBackupSHA256(backupPath)
	}
	if backupErr != nil {
		log.Printf("controller pre-update backup failed: %v", backupErr)
		state.State = "ERROR"
		state.Phase = "BACKUP_FAILED"
		state.StartedAt = ""
		state.Message = "更新前数据库备份失败，更新未执行"
		_ = s.writeRuntimeState(state, recordControllerAutomaticFailure)
		return errors.New(state.Message)
	}
	state.BackupName = backupName
	state.Phase = "APPLYING"
	state.Message = "已创建数据库备份，正在暂存 " + targetVersion + " 镜像并更新服务"
	_ = s.writeRuntimeState(state, preserveControllerAutomaticState)

	ctx, cancel := context.WithTimeout(context.Background(), controllerUpdateApplyTimeout)
	defer cancel()
	arguments := []string{"--apply"}
	if s.effectiveNetworkMode() == networkModeOffline {
		arguments = append(arguments, "--offline", "--no-source-fallback")
	}
	command := updateControllerCommand(ctx, updaterPath, arguments...)
	command.Env = overrideEnvironment(
		controllerUpdateEnvironment(targetVersion),
		"XINGCHEN_PREUPDATE_BACKUP_PATH="+filepath.Join(workspace, "backups", backupName),
		"XINGCHEN_PREUPDATE_BACKUP_SHA256="+backupSHA256,
	)
	output, err := command.CombinedOutput()
	state = s.readState()
	if err != nil {
		log.Printf("controller update failed: %v (%d bytes)", err, len(output))
		state.State = "ERROR"
		state.Phase = "FAILED"
		state.StartedAt = ""
		state.Message = "总控更新失败，数据库备份已保留"
		state.DatabaseCompatibility = "MANUAL_REVIEW_REQUIRED"
		var exitError *exec.ExitError
		if errors.As(err, &exitError) {
			switch exitError.ExitCode() {
			case 10:
				state.RollbackState = "SUCCEEDED"
				state.Message = "总控更新失败，旧镜像已恢复；数据库兼容性需人工确认"
			case 11:
				state.RollbackState = "FAILED"
				state.Message = "总控更新与镜像恢复均失败，需要立即人工处理"
			}
		}
		_ = s.writeRuntimeState(state, recordControllerAutomaticFailure)
		return errors.New(state.Message)
	}
	state.State = "IDLE"
	state.Phase = "COMPLETE"
	state.RollbackState = "NOT_REQUIRED"
	state.DatabaseCompatibility = "CURRENT"
	state.StartedAt = ""
	state.Message = "总控服务已更新"
	state.UpdatedAt = s.currentTime().UTC().Format(time.RFC3339)
	state.CheckedAt = state.UpdatedAt
	invalidateControllerInspectionCache()
	s.decorate(&state)
	if state.CurrentVersion == "" {
		state.CurrentVersion = targetVersion
		state.VersionRevision = state.CurrentRevision
	}
	state.LatestRevision = state.CurrentRevision
	state.UpdateAvailable = false
	return s.writeRuntimeState(state, resetControllerAutomaticFailures)
}

func controllerVersionsShareMajor(left, right string) bool {
	leftVersion, leftOK := parseControllerVersion(left)
	rightVersion, rightOK := parseControllerVersion(right)
	return leftOK && rightOK && leftVersion[0] == rightVersion[0]
}

func (s *controllerUpdateService) snapshot() controllerUpdateState {
	state := s.readState()
	s.mu.Lock()
	running := s.running
	s.mu.Unlock()
	runnerMissing := !running && s.updateRunnerMissing(state)
	if !running && (s.isStale(state) || runnerMissing) {
		recovered, err := s.recoverObservedState(state, runnerMissing)
		if err != nil {
			log.Printf("controller stale update state write failed: %v", err)
		} else {
			state = recovered
		}
	}
	s.decorate(&state)
	return state
}

func (s *controllerUpdateService) recoverStaleState() {
	state := s.readState()
	runnerMissing := s.updateRunnerMissing(state)
	if !s.isStale(state) && !runnerMissing {
		return
	}
	if _, err := s.recoverObservedState(state, runnerMissing); err != nil {
		log.Printf("controller startup state recovery failed: %v", err)
	}
}

func (s *controllerUpdateService) recoverObservedState(observed controllerUpdateState, runnerMissing bool) (controllerUpdateState, error) {
	return mutateControllerUpdateState(func(current *controllerUpdateState) {
		if current.State != observed.State || current.StartedAt != observed.StartedAt {
			return
		}
		if !s.isStale(*current) && !runnerMissing {
			return
		}
		current.State = "ERROR"
		current.StartedAt = ""
		current.UpdateAvailable = false
		current.Message = updateRecoveryMessage(runnerMissing)
		s.recordAutomaticFailure(current)
	})
}

func updateRecoveryMessage(runnerMissing bool) string {
	if runnerMissing {
		return "上次更新任务已中断，状态已恢复，请重新检查"
	}
	return "上次更新任务已超时，状态已恢复，请重新检查"
}

func (s *controllerUpdateService) updateRunnerMissing(state controllerUpdateState) bool {
	if state.State != "UPDATING" || !s.updateRunnerStartExpired(state) {
		return false
	}
	status, known := controllerUpdateRunnerStatus()
	return known && (status == "" || status == "created" || status == "exited" || status == "dead" || status == "removing")
}

func (s *controllerUpdateService) updateRunnerStartExpired(state controllerUpdateState) bool {
	if state.State != "UPDATING" || state.StartedAt == "" {
		return false
	}
	started, err := time.Parse(time.RFC3339, state.StartedAt)
	if err != nil {
		return false
	}
	return s.currentTime().UTC().Sub(started) > controllerUpdateRunnerGracePeriod
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
	state.NetworkMode = s.effectiveNetworkMode()
	state.AutoUpdate = strings.EqualFold(configuredEnvironmentValue("CONTROLLER_AUTO_UPDATE"), "true")
	state.AutoPaused = s.automaticUpdatePaused(*state)
	state.NextAutoUpdateAt = s.nextAutoUpdateForState(*state).UTC().Format(time.RFC3339)
	current, latest, currentVersion, services := inspectControllerImages()
	state.CurrentRevision = current
	state.LatestRevision = latest
	if currentVersion != "" {
		state.CurrentVersion = currentVersion
		state.VersionRevision = current
	} else if state.VersionRevision != "" && state.VersionRevision != current {
		state.CurrentVersion = ""
		state.VersionRevision = ""
	}
	state.Services = services
	if state.LatestVersion != "" {
		state.UpdateAvailable = controllerVersionLess(state.CurrentVersion, state.LatestVersion)
	} else {
		state.UpdateAvailable = current != "" && latest != "" && current != latest
	}
}

func (s *controllerUpdateService) readState() controllerUpdateState {
	return readControllerUpdateState()
}

func readControllerUpdateState() controllerUpdateState {
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
	_, err := mutateControllerUpdateState(func(current *controllerUpdateState) {
		*current = state
	})
	return err
}

func mutateControllerUpdateState(mutate func(*controllerUpdateState)) (state controllerUpdateState, err error) {
	controllerUpdateStateProcessLock.Lock()
	defer controllerUpdateStateProcessLock.Unlock()
	if err := os.MkdirAll(filepath.Dir(controllerUpdateStatePath), 0700); err != nil {
		return state, err
	}
	lock, err := acquireControllerUpdateStateFileLock(controllerUpdateStatePath + ".lock")
	if err != nil {
		return state, err
	}
	defer func() {
		if closeErr := lock.Close(); err == nil && closeErr != nil {
			err = closeErr
		}
	}()
	state = readControllerUpdateState()
	mutate(&state)
	err = writeControllerUpdateStateUnlocked(state)
	return state, err
}

func (s *controllerUpdateService) writeRuntimeState(state controllerUpdateState, automaticWrite controllerAutomaticStateWrite) error {
	_, err := mutateControllerUpdateState(func(current *controllerUpdateState) {
		replaceControllerRuntimeState(current, state)
		switch automaticWrite {
		case recordControllerAutomaticFailure:
			s.recordAutomaticFailure(current)
		case resetControllerAutomaticFailures:
			s.resetAutomaticFailures(current)
		}
	})
	return err
}

func replaceControllerRuntimeState(current *controllerUpdateState, runtime controllerUpdateState) {
	autoUpdate := current.AutoUpdate
	autoFailureCount := current.AutoFailureCount
	autoPaused := current.AutoPaused
	autoPausedUntil := current.AutoPausedUntil
	nextAutoUpdateAt := current.NextAutoUpdateAt
	lastAutoRunDate := current.LastAutoRunDate
	*current = runtime
	current.AutoUpdate = autoUpdate
	current.AutoFailureCount = autoFailureCount
	current.AutoPaused = autoPaused
	current.AutoPausedUntil = autoPausedUntil
	current.NextAutoUpdateAt = nextAutoUpdateAt
	current.LastAutoRunDate = lastAutoRunDate
}

func writeControllerUpdateStateUnlocked(state controllerUpdateState) error {
	content, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(controllerUpdateStatePath), 0700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(controllerUpdateStatePath), ".controller-update-state-*")
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

func inspectControllerImages() (string, string, string, []controllerServiceStatus) {
	controllerInspectionCache.Lock()
	if !controllerInspectionCache.at.IsZero() && time.Since(controllerInspectionCache.at) < controllerUpdateInspectionCache {
		value := controllerInspectionCache.value
		controllerInspectionCache.Unlock()
		return value.current, value.latest, value.version, append([]controllerServiceStatus(nil), value.services...)
	}
	controllerInspectionCache.Unlock()

	values, _ := readEnv()
	statuses := make([]controllerServiceStatus, 0, len(controllerImages))
	results := make([]struct {
		status  controllerServiceStatus
		current string
		latest  string
		version string
	}, len(controllerImages))
	var wait sync.WaitGroup
	for index, image := range controllerImages {
		wait.Add(1)
		go func(index int, image controllerImage) {
			defer wait.Done()
			composeArgs := append(composeBaseArgs(), "ps", "-q", image.service)
			containerID := commandOutput("docker", composeArgs...)
			current := ""
			version := ""
			health := "not_found"
			if containerID != "" {
				current, version = inspectReferenceMetadata(containerID, false)
				health = commandOutput("docker", "inspect", "--format", "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}", containerID)
			}
			imageReference := strings.TrimSpace(environmentValue(image.environment, ""))
			if imageReference == "" {
				imageReference = environmentValueFromMap(values, image.environment, "")
			}
			if imageReference == "" {
				imageReference = image.defaultImage
			}
			results[index] = struct {
				status  controllerServiceStatus
				current string
				latest  string
				version string
			}{controllerServiceStatus{Name: image.service, Revision: current, Version: version, Health: health}, current, inspectReference(imageReference, true), version}
		}(index, image)
	}
	wait.Wait()
	currentRevision := ""
	latestRevision := ""
	currentVersion := ""
	for _, result := range results {
		statuses = append(statuses, result.status)
		if result.status.Name == "server" || currentRevision == "" {
			currentRevision = result.current
		}
		if result.status.Name == "server" || latestRevision == "" {
			latestRevision = result.latest
		}
		if result.status.Name == "server" || currentVersion == "" {
			currentVersion = normalizeControllerVersion(result.version)
		}
	}
	value := controllerInspection{current: currentRevision, latest: latestRevision, version: currentVersion, services: append([]controllerServiceStatus(nil), statuses...)}
	controllerInspectionCache.Lock()
	controllerInspectionCache.at = time.Now()
	controllerInspectionCache.value = value
	controllerInspectionCache.Unlock()
	return currentRevision, latestRevision, currentVersion, statuses
}

func invalidateControllerInspectionCache() {
	controllerInspectionCache.Lock()
	controllerInspectionCache.at = time.Time{}
	controllerInspectionCache.Unlock()
}

func inspectReference(reference string, image bool) string {
	revision, _ := inspectReferenceMetadata(reference, image)
	return revision
}

func inspectReferenceMetadata(reference string, image bool) (string, string) {
	fallback := ".Image"
	if image {
		fallback = ".Id"
	}
	format := fmt.Sprintf(`{{index .Config.Labels "org.opencontainers.image.revision"}}|{{index .Config.Labels "org.opencontainers.image.version"}}|{{%s}}`, fallback)
	args := []string{"inspect", "--format", format, reference}
	if image {
		args = append([]string{"image"}, args...)
	}
	value := commandOutput("docker", args...)
	parts := strings.SplitN(value, "|", 3)
	version := ""
	if len(parts) > 1 && strings.TrimSpace(parts[1]) != "<no value>" {
		version = strings.TrimSpace(parts[1])
	}
	if len(parts) > 0 && strings.TrimSpace(parts[0]) != "" && strings.TrimSpace(parts[0]) != "<no value>" {
		return strings.TrimSpace(parts[0]), version
	}
	if len(parts) == 3 {
		return strings.TrimPrefix(strings.TrimSpace(parts[2]), "sha256:"), version
	}
	return "", version
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

func resolveControllerUpdaterPath() (string, error) {
	if controllerUpdaterIsRegular(packagedControllerUpdaterPath) {
		return packagedControllerUpdaterPath, nil
	}
	if !strings.EqualFold(strings.TrimSpace(os.Getenv(controllerUpdateWorkspaceFallbackEnvironment)), "true") {
		return "", fmt.Errorf("packaged controller updater is unavailable: %s", packagedControllerUpdaterPath)
	}
	workspacePath := filepath.Join(workspace, "deploy", "update-controller.sh")
	if !controllerUpdaterIsRegular(workspacePath) {
		return "", fmt.Errorf("workspace controller updater is unavailable: %s", workspacePath)
	}
	return workspacePath, nil
}

func (s *controllerUpdateService) effectiveNetworkMode() string {
	return normalizeNetworkMode(s.networkMode)
}

func controllerUpdaterIsRegular(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && info.Size() > 0
}

func updateControllerCommand(ctx context.Context, updaterPath string, arguments ...string) *exec.Cmd {
	// Invoke through Bash so a root-owned packaged script does not need a writable mount.
	return exec.CommandContext(ctx, "bash", append([]string{updaterPath}, arguments...)...)
}

func controllerUpdateRunnerArgs() []string {
	projectName := environmentValue("COMPOSE_PROJECT_NAME", "xingchen-monitor")
	return []string{"--project-name", projectName + controllerUpdateRunnerProjectSuffix, "run", "--pull", "never", "-d", "--rm", "--no-deps", "-e", "CONTROLLER_UPDATE_RUNNER=true", "-e", "COMPOSE_PROJECT_NAME=" + projectName, "--name", controllerUpdateRunnerName, "setup", "update-runner"}
}

func controllerUpdateRunnerStatus() (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), controllerUpdateInspectTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, "docker", "ps", "-aq", "--filter", "name="+controllerUpdateRunnerName, "--format", "{{.ID}}")
	output, err := command.Output()
	if err != nil {
		return "", false
	}
	containerID := strings.TrimSpace(string(output))
	if containerID == "" {
		return "", true
	}
	status := commandOutput("docker", "inspect", "--format", "{{.State.Status}}", containerID)
	return status, status != ""
}

func composeBaseArgs() []string {
	return []string{"compose", "-f", filepath.Join(workspace, "docker-compose.yml"), "--project-directory", hostWorkspace, "--env-file", envPath}
}

func controllerUpdateEnvironment(targetVersion ...string) []string {
	overrides := []string{
		"COMPOSE_PROJECT_NAME=" + environmentValue("COMPOSE_PROJECT_NAME", "xingchen-monitor"),
		"XINGCHEN_HOST_PROJECT_ROOT=" + hostWorkspace,
	}
	if len(targetVersion) > 0 {
		if normalized := normalizeControllerVersion(targetVersion[0]); normalized != "" {
			overrides = append(overrides, "XINGCHEN_TARGET_VERSION="+normalized)
		}
	}
	return overrideEnvironment(os.Environ(), overrides...)
}

func overrideEnvironment(environment []string, overrides ...string) []string {
	names := make(map[string]struct{}, len(overrides))
	for _, entry := range overrides {
		name, _, ok := strings.Cut(entry, "=")
		if ok && name != "" {
			names[name] = struct{}{}
		}
	}
	result := make([]string, 0, len(environment)+len(overrides))
	for _, entry := range environment {
		name, _, ok := strings.Cut(entry, "=")
		if _, replaced := names[name]; ok && replaced {
			continue
		}
		result = append(result, entry)
	}
	return append(result, overrides...)
}

func controllerBackupSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("open controller backup for verification: %w", err)
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", fmt.Errorf("hash controller backup: %w", err)
	}
	return fmt.Sprintf("%x", digest.Sum(nil)), nil
}

func environmentValueFromMap(values map[string]string, name, fallback string) string {
	if value := strings.TrimSpace(values[name]); value != "" {
		return value
	}
	return fallback
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
	if s.automaticUpdatePaused(state) || now.Hour() != 4 || state.LastAutoRunDate == now.Format("2006-01-02") {
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
	return s.nextAutoUpdateForState(s.readState())
}

func (s *controllerUpdateService) nextAutoUpdateForState(state controllerUpdateState) time.Time {
	now := s.localNow()
	if pausedUntil, ok := parseControllerUpdateTime(state.AutoPausedUntil); ok && pausedUntil.After(s.currentTime().UTC()) {
		pauseLocal := pausedUntil.In(now.Location())
		if pauseLocal.Hour() == 4 {
			return pauseLocal
		}
		now = pauseLocal
	}
	next := time.Date(now.Year(), now.Month(), now.Day(), 4, 0, 0, 0, now.Location())
	if !next.After(now) {
		next = next.AddDate(0, 0, 1)
	}
	return next
}

func (s *controllerUpdateService) automaticUpdatePaused(state controllerUpdateState) bool {
	pausedUntil, ok := parseControllerUpdateTime(state.AutoPausedUntil)
	return ok && pausedUntil.After(s.currentTime().UTC())
}

func parseControllerUpdateTime(value string) (time.Time, bool) {
	parsed, err := time.Parse(time.RFC3339, strings.TrimSpace(value))
	return parsed, err == nil
}

func (s *controllerUpdateService) recordAutomaticFailure(state *controllerUpdateState) {
	if state.Trigger != "automatic" {
		return
	}
	state.AutoFailureCount++
	if state.AutoFailureCount >= controllerAutoFailureLimit {
		state.AutoPausedUntil = s.currentTime().UTC().Add(controllerAutoPauseDuration).Format(time.RFC3339)
	}
	state.AutoPaused = s.automaticUpdatePaused(*state)
}

func (s *controllerUpdateService) prepareUpdateState(state *controllerUpdateState, automatic bool) {
	state.Trigger = "manual"
	if automatic {
		state.Trigger = "automatic"
		state.LastAutoRunDate = s.localNow().Format("2006-01-02")
	}
}

func (s *controllerUpdateService) resetAutomaticFailures(state *controllerUpdateState) {
	state.AutoFailureCount = 0
	state.AutoPaused = false
	state.AutoPausedUntil = ""
}

func methodNotAllowed(w http.ResponseWriter, allowed string) {
	w.Header().Set("Allow", allowed)
	writeError(w, http.StatusMethodNotAllowed, "请求方法不受支持")
}
