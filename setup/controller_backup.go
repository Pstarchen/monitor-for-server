package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	controllerBackupCheckInterval    = time.Minute
	controllerBackupCreateTimeout    = 20 * time.Minute
	controllerBackupRestoreTimeout   = 30 * time.Minute
	controllerBackupStaleAfter       = 45 * time.Minute
	defaultControllerBackupRetention = 7
)

var controllerBackupStatePath = "/workspace/.controller-backup-state.json"
var controllerBackupNamePattern = regexp.MustCompile(`^guanlan-monitor-[0-9]{8}T[0-9]{6}Z\.sql$`)

type controllerBackupService struct {
	mu      sync.Mutex
	running bool
	token   string
	now     func() time.Time
}

type controllerBackupState struct {
	State           string                 `json:"state"`
	Message         string                 `json:"message,omitempty"`
	StartedAt       string                 `json:"startedAt,omitempty"`
	FinishedAt      string                 `json:"finishedAt,omitempty"`
	LastBackup      string                 `json:"lastBackup,omitempty"`
	LastAutoRunDate string                 `json:"lastAutoRunDate,omitempty"`
	AutoBackup      bool                   `json:"autoBackup"`
	Retention       int                    `json:"retention"`
	Backups         []controllerBackupFile `json:"backups"`
}

type controllerBackupFile struct {
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	CreatedAt string `json:"createdAt"`
}

type controllerBackupRestoreRequest struct {
	Name string `json:"name"`
}

type controllerBackupAutoRequest struct {
	Enabled   bool `json:"enabled"`
	Retention int  `json:"retention"`
}

func newControllerBackupService() *controllerBackupService {
	return &controllerBackupService{token: strings.TrimSpace(os.Getenv("CONTROLLER_UPDATE_TOKEN")), now: time.Now}
}

func (s *controllerBackupService) register(mux *http.ServeMux) {
	mux.Handle("/internal/controller-backup/status", s.authorize(http.HandlerFunc(s.status)))
	mux.Handle("/internal/controller-backup/create", s.authorize(http.HandlerFunc(s.create)))
	mux.Handle("/internal/controller-backup/restore", s.authorize(http.HandlerFunc(s.restore)))
	mux.Handle("/internal/controller-backup/auto", s.authorize(http.HandlerFunc(s.auto)))
}

func (s *controllerBackupService) authorize(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		provided := strings.TrimSpace(r.Header.Get("X-Controller-Update-Token"))
		leftHash := sha256.Sum256([]byte(provided))
		rightHash := sha256.Sum256([]byte(s.token))
		if s.token == "" || subtle.ConstantTimeCompare(leftHash[:], rightHash[:]) != 1 {
			writeError(w, http.StatusUnauthorized, "内部备份服务认证失败")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *controllerBackupService) status(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, s.snapshot())
}

func (s *controllerBackupService) create(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}
	if err := s.begin("CREATING", "正在导出 PostgreSQL 数据库"); err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	go s.runCreate()
	writeJSON(w, http.StatusAccepted, s.snapshot())
}

func (s *controllerBackupService) restore(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}
	var request controllerBackupRestoreRequest
	if err := decodeJSON(r, &request); err != nil || !controllerBackupNamePattern.MatchString(strings.TrimSpace(request.Name)) {
		writeError(w, http.StatusBadRequest, "备份文件名无效")
		return
	}
	request.Name = strings.TrimSpace(request.Name)
	path := filepath.Join(controllerBackupDir(), request.Name)
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		writeError(w, http.StatusNotFound, "备份文件不存在")
		return
	}
	if err := s.begin("RESTORING", "正在停止服务并恢复 PostgreSQL 数据库"); err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	go s.runRestore(request.Name)
	writeJSON(w, http.StatusAccepted, s.snapshot())
}

func (s *controllerBackupService) auto(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		methodNotAllowed(w, http.MethodPut)
		return
	}
	var request controllerBackupAutoRequest
	if err := decodeJSON(r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "备份策略格式不正确")
		return
	}
	retention := request.Retention
	if retention == 0 {
		retention = s.snapshot().Retention
	}
	if retention < 1 || retention > 100 {
		writeError(w, http.StatusBadRequest, "备份保留数量必须在 1-100 之间")
		return
	}
	if err := updateEnvironmentSetting("CONTROLLER_BACKUP_AUTO", strconv.FormatBool(request.Enabled)); err != nil {
		writeError(w, http.StatusInternalServerError, "备份策略保存失败")
		return
	}
	if err := updateEnvironmentSetting("CONTROLLER_BACKUP_RETENTION", strconv.Itoa(retention)); err != nil {
		writeError(w, http.StatusInternalServerError, "备份保留数量保存失败")
		return
	}
	state := s.readState()
	state.AutoBackup = request.Enabled
	state.Retention = retention
	state.Message = map[bool]string{true: "已启用每日自动备份", false: "已关闭自动备份"}[request.Enabled]
	state.Backups = listControllerBackups()
	_ = writeControllerBackupState(state)
	writeJSON(w, http.StatusOK, s.snapshot())
}

func (s *controllerBackupService) begin(stateName, message string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	state := s.readState()
	if s.running || (state.State == "CREATING" || state.State == "RESTORING") && !s.isStale(state) {
		return errors.New("已有备份任务正在执行")
	}
	s.running = true
	state.State = stateName
	state.Message = message
	state.StartedAt = s.currentTime().UTC().Format(time.RFC3339)
	state.FinishedAt = ""
	state.Backups = listControllerBackups()
	if err := writeControllerBackupState(state); err != nil {
		s.running = false
		return errors.New("备份状态保存失败")
	}
	return nil
}

func (s *controllerBackupService) finish() {
	s.mu.Lock()
	s.running = false
	s.mu.Unlock()
}

func (s *controllerBackupService) currentTime() time.Time {
	if s.now != nil {
		return s.now()
	}
	return time.Now()
}

func (s *controllerBackupService) runCreate() {
	defer s.finish()
	if err := os.MkdirAll(controllerBackupDir(), 0700); err != nil {
		s.fail("备份目录创建失败")
		return
	}
	name := "guanlan-monitor-" + s.currentTime().UTC().Format("20060102T150405Z") + ".sql"
	path := filepath.Join(controllerBackupDir(), name)
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		s.fail("备份文件创建失败")
		return
	}
	defer file.Close()
	values, _ := readEnv()
	database := strings.TrimSpace(configuredEnvironmentValueFrom(values, "POSTGRES_DB", "guanlan_monitor"))
	user := strings.TrimSpace(configuredEnvironmentValueFrom(values, "POSTGRES_USER", "guanlan"))
	password := strings.TrimSpace(configuredEnvironmentValueFrom(values, "POSTGRES_PASSWORD", ""))
	if password == "" {
		os.Remove(path)
		s.fail("PostgreSQL 凭据未配置，无法创建备份")
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), controllerBackupCreateTimeout)
	defer cancel()
	args := postgresExecArgs("pg_dump", "--clean", "--if-exists", "--no-owner", "--no-privileges", "-U", user, "-d", database)
	command := execCommandContext(ctx, "docker", args...)
	command.Env = controllerUpdateEnvironment()
	command.Stdout = file
	var stderr bytes.Buffer
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		log.Printf("controller backup failed: %v (%d bytes)", err, stderr.Len())
		os.Remove(path)
		s.fail("数据库备份失败，请检查 PostgreSQL 与 Docker 状态")
		return
	}
	if err := file.Sync(); err != nil {
		os.Remove(path)
		s.fail("数据库备份写入失败")
		return
	}
	state := s.readState()
	state.State = "IDLE"
	state.Message = "数据库备份已完成"
	state.StartedAt = ""
	state.FinishedAt = s.currentTime().UTC().Format(time.RFC3339)
	state.LastBackup = name
	state.Backups = listControllerBackups()
	pruneControllerBackups(state.Retention)
	state.Backups = listControllerBackups()
	if err := writeControllerBackupState(state); err != nil {
		log.Printf("controller backup state write failed: %v", err)
	}
}

func (s *controllerBackupService) runRestore(name string) {
	defer s.finish()
	path := filepath.Join(controllerBackupDir(), name)
	values, _ := readEnv()
	database := strings.TrimSpace(configuredEnvironmentValueFrom(values, "POSTGRES_DB", "guanlan_monitor"))
	user := strings.TrimSpace(configuredEnvironmentValueFrom(values, "POSTGRES_USER", "guanlan"))
	password := strings.TrimSpace(configuredEnvironmentValueFrom(values, "POSTGRES_PASSWORD", ""))
	if password == "" {
		s.fail("PostgreSQL 凭据未配置，无法恢复备份")
		return
	}
	env := controllerUpdateEnvironment()
	stopCtx, stopCancel := context.WithTimeout(context.Background(), 2*time.Minute)
	stop := execCommandContext(stopCtx, "docker", append(composeBaseArgs(), "stop", "server", "web")...)
	stop.Env = env
	stopErr := stop.Run()
	stopCancel()
	if stopErr != nil {
		s.fail("停止总控服务失败，数据库未恢复")
		return
	}
	restoreCtx, restoreCancel := context.WithTimeout(context.Background(), controllerBackupRestoreTimeout)
	restore := execCommandContext(restoreCtx, "docker", postgresExecArgs("psql", "-v", "ON_ERROR_STOP=1", "-U", user, "-d", database)...)
	restore.Env = env
	file, err := os.Open(path)
	if err != nil {
		restoreCancel()
		s.restartAfterRestore(env)
		s.fail("备份文件读取失败，总控服务已尝试恢复")
		return
	}
	restore.Stdin = file
	var stderr bytes.Buffer
	restore.Stderr = &stderr
	restoreErr := restore.Run()
	file.Close()
	restoreCancel()
	if restoreErr != nil {
		log.Printf("controller restore failed: %v (%d bytes)", restoreErr, stderr.Len())
		s.restartAfterRestore(env)
		s.fail("数据库恢复失败，总控服务已重新启动")
		return
	}
	if err := s.restartAfterRestore(env); err != nil {
		s.fail("数据库已恢复，但总控服务启动失败，请检查 Docker 状态")
		return
	}
	state := s.readState()
	state.State = "IDLE"
	state.Message = "数据库已恢复，总控服务已重新启动"
	state.StartedAt = ""
	state.FinishedAt = s.currentTime().UTC().Format(time.RFC3339)
	state.Backups = listControllerBackups()
	_ = writeControllerBackupState(state)
}

func (s *controllerBackupService) restartAfterRestore(env []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	command := execCommandContext(ctx, "docker", append(composeBaseArgs(), "up", "-d", "--no-deps", "--wait", "--wait-timeout", "300", "server", "web")...)
	command.Env = env
	return command.Run()
}

func (s *controllerBackupService) fail(message string) {
	state := s.readState()
	state.State = "ERROR"
	state.Message = message
	state.StartedAt = ""
	state.FinishedAt = s.currentTime().UTC().Format(time.RFC3339)
	state.Backups = listControllerBackups()
	if err := writeControllerBackupState(state); err != nil {
		log.Printf("controller backup error state write failed: %v", err)
	}
}

func (s *controllerBackupService) snapshot() controllerBackupState {
	state := s.readState()
	s.mu.Lock()
	running := s.running
	s.mu.Unlock()
	if !running && (s.isStale(state) || state.State == "CREATING" || state.State == "RESTORING" && state.StartedAt == "") {
		state.State = "ERROR"
		state.Message = "上次备份任务已中断，状态已恢复，请重新检查"
		state.StartedAt = ""
		state.Backups = listControllerBackups()
		_ = writeControllerBackupState(state)
	}
	if state.Retention < 1 {
		state.Retention = backupRetention()
	}
	state.AutoBackup = strings.EqualFold(configuredEnvironmentValue("CONTROLLER_BACKUP_AUTO"), "true")
	state.Backups = listControllerBackups()
	return state
}

func (s *controllerBackupService) recoverStaleState() {
	state := s.readState()
	if !s.isStale(state) {
		return
	}
	state.State = "ERROR"
	state.Message = "上次备份任务已中断，状态已恢复，请重新检查"
	state.StartedAt = ""
	state.Backups = listControllerBackups()
	_ = writeControllerBackupState(state)
}

func (s *controllerBackupService) isStale(state controllerBackupState) bool {
	if state.State != "CREATING" && state.State != "RESTORING" {
		return false
	}
	if state.StartedAt == "" {
		return true
	}
	started, err := time.Parse(time.RFC3339, state.StartedAt)
	return err != nil || s.currentTime().UTC().Sub(started) > controllerBackupStaleAfter
}

func (s *controllerBackupService) readState() controllerBackupState {
	state := controllerBackupState{State: "IDLE", Message: "尚未创建数据库备份", Retention: backupRetention(), Backups: []controllerBackupFile{}}
	content, err := os.ReadFile(controllerBackupStatePath)
	if err == nil && json.Unmarshal(content, &state) != nil {
		state = controllerBackupState{State: "ERROR", Message: "备份状态文件无法读取", Retention: backupRetention(), Backups: []controllerBackupFile{}}
	}
	return state
}

func writeControllerBackupState(state controllerBackupState) error {
	content, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(controllerBackupStatePath), 0700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(controllerBackupStatePath), ".controller-backup-state-*")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer os.Remove(name)
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
	return os.Rename(name, controllerBackupStatePath)
}

func controllerBackupDir() string {
	return filepath.Join(workspace, "backups")
}

func postgresExecArgs(command string, args ...string) []string {
	compose := composeBaseArgs()
	compose = append(compose, "exec", "-T", "postgres", "sh", "-ec", `PGPASSWORD="$POSTGRES_PASSWORD" exec "$@"`, "--", command)
	return append(compose, args...)
}

func listControllerBackups() []controllerBackupFile {
	entries, err := os.ReadDir(controllerBackupDir())
	if err != nil {
		return []controllerBackupFile{}
	}
	backups := make([]controllerBackupFile, 0, len(entries))
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !controllerBackupNamePattern.MatchString(entry.Name()) {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		backups = append(backups, controllerBackupFile{Name: entry.Name(), Size: info.Size(), CreatedAt: info.ModTime().UTC().Format(time.RFC3339)})
	}
	sort.Slice(backups, func(i, j int) bool { return backups[i].Name > backups[j].Name })
	return backups
}

func pruneControllerBackups(retention int) {
	if retention < 1 || retention > 100 {
		retention = defaultControllerBackupRetention
	}
	backups := listControllerBackups()
	for _, backup := range backups[retention:] {
		_ = os.Remove(filepath.Join(controllerBackupDir(), backup.Name))
	}
}

func backupRetention() int {
	value := strings.TrimSpace(configuredEnvironmentValue("CONTROLLER_BACKUP_RETENTION"))
	if value == "" {
		return defaultControllerBackupRetention
	}
	retention, err := strconv.Atoi(value)
	if err != nil || retention < 1 || retention > 100 {
		return defaultControllerBackupRetention
	}
	return retention
}

func configuredEnvironmentValueFrom(values map[string]string, name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	if value := strings.TrimSpace(values[name]); value != "" {
		return value
	}
	return fallback
}

func (s *controllerBackupService) runScheduler() {
	ticker := time.NewTicker(controllerBackupCheckInterval)
	defer ticker.Stop()
	for {
		s.maybeRunAutomaticBackup()
		<-ticker.C
	}
}

func (s *controllerBackupService) maybeRunAutomaticBackup() {
	if !strings.EqualFold(configuredEnvironmentValue("CONTROLLER_BACKUP_AUTO"), "true") {
		return
	}
	now := s.currentTime().In(configuredLocation())
	if now.Hour() != 3 || now.Minute() != 0 {
		return
	}
	state := s.readState()
	if state.LastAutoRunDate == now.Format("2006-01-02") {
		return
	}
	state.LastAutoRunDate = now.Format("2006-01-02")
	state.Retention = backupRetention()
	_ = writeControllerBackupState(state)
	if err := s.begin("CREATING", "正在执行每日数据库备份"); err != nil {
		return
	}
	go s.runCreate()
}

func configuredLocation() *time.Location {
	name := configuredEnvironmentValue("APP_TIMEZONE")
	if name == "" {
		name = "Asia/Shanghai"
	}
	location, err := time.LoadLocation(name)
	if err != nil {
		return time.Local
	}
	return location
}

// execCommandContext is a variable so setup tests can replace process execution
// without touching the production command path.
var execCommandContext = func(ctx context.Context, name string, args ...string) *exec.Cmd {
	return exec.CommandContext(ctx, name, args...)
}
