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
var setupHostGateway string

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
	MySQLHost            string `json:"mysqlHost"`
	MySQLPort            int    `json:"mysqlPort"`
	DatabaseName         string `json:"databaseName"`
	MySQLUsername        string `json:"mysqlUsername"`
	MySQLPassword        string `json:"mysqlPassword"`
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
	setupHostGateway = strings.TrimSpace(os.Getenv("SETUP_HOST_GATEWAY"))
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
	db, err := connectAndPrepareMySQL(ctx, request.Host, request.Port, request.Username, request.Password, request.DatabaseName)
	if err != nil {
		writeError(w, http.StatusBadRequest, mysqlSetupErrorMessage(err))
		return
	}
	defer db.Close()
	if err := initializeMySQLSchema(ctx, db); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"message": "MySQL 连接和表结构初始化通过"})
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

	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	db, err := connectAndPrepareMySQL(ctx, request.MySQLHost, request.MySQLPort, request.MySQLUsername, request.MySQLPassword, request.DatabaseName)
	if err != nil {
		s.mu.Lock()
		s.applying = false
		s.lastErr = mysqlSetupErrorMessage(err)
		s.mu.Unlock()
		writeError(w, http.StatusBadRequest, mysqlSetupErrorMessage(err))
		return
	}
	if err := initializeMySQLSchema(ctx, db); err != nil {
		db.Close()
		s.mu.Lock()
		s.applying = false
		s.lastErr = err.Error()
		s.mu.Unlock()
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	db.Close()

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
	writeJSON(w, http.StatusAccepted, setupStatus{State: "applying", Message: "数据库表结构和配置已完成，正在重建服务", BaseURL: request.PublicBaseURL})
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

var requiredSchemaTables = []string{"app_users", "devices", "metric_snapshots", "alert_rules", "alert_events", "system_settings", "audit_logs"}

func initializeMySQLSchema(ctx context.Context, db *sql.DB) error {
	rows, err := db.QueryContext(ctx, "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'")
	if err != nil {
		return errors.New("MySQL 已连接，但无法读取目标数据库表结构，请确认账号具有建表权限")
	}
	defer rows.Close()
	tables := make(map[string]bool)
	for rows.Next() {
		var tableName string
		if err := rows.Scan(&tableName); err != nil {
			return errors.New("读取目标数据库表结构失败")
		}
		tables[tableName] = true
	}
	if err := rows.Err(); err != nil {
		return errors.New("读取目标数据库表结构失败")
	}
	if len(tables) == 0 {
		schemaPath := filepath.Join(workspace, "server", "src", "main", "resources", "db", "migration", "V1__initial_schema.sql")
		contents, err := os.ReadFile(schemaPath)
		if err != nil {
			return errors.New("找不到服务端数据库表结构文件，请重新部署完整项目")
		}
		for _, statement := range splitSQLStatements(string(contents)) {
			if _, err := db.ExecContext(ctx, statement); err != nil {
				return errors.New("数据库表结构初始化失败，请确认 MySQL 账号具有建表和索引权限")
			}
		}
		return ensureFlywayBaseline(ctx, db)
	}
	for _, tableName := range requiredSchemaTables {
		if !tables[tableName] {
			return errors.New("目标数据库已有不完整表结构，请使用空数据库或先完成数据库迁移")
		}
	}
	return ensureFlywayBaseline(ctx, db)
}

func ensureFlywayBaseline(ctx context.Context, db *sql.DB) error {
	var tableCount int
	if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'flyway_schema_history'").Scan(&tableCount); err != nil {
		return errors.New("无法检查 Flyway 迁移记录，请确认 MySQL 账号具有建表权限")
	}
	if tableCount == 0 {
		const createHistoryTable = `CREATE TABLE flyway_schema_history (
            installed_rank INT NOT NULL,
            version VARCHAR(50),
            description VARCHAR(200) NOT NULL,
            type VARCHAR(20) NOT NULL,
            script VARCHAR(1000) NOT NULL,
            checksum INT,
            installed_by VARCHAR(100) NOT NULL,
            installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            execution_time INT NOT NULL,
            success BOOLEAN NOT NULL,
            PRIMARY KEY (installed_rank)
        ) ENGINE=InnoDB`
		if _, err := db.ExecContext(ctx, createHistoryTable); err != nil {
			return errors.New("无法创建 Flyway 迁移记录表，请确认 MySQL 账号具有建表权限")
		}
	}
	var migrationCount int
	if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM flyway_schema_history").Scan(&migrationCount); err != nil {
		return errors.New("无法读取 Flyway 迁移记录")
	}
	if migrationCount == 0 {
		if _, err := db.ExecContext(ctx, `INSERT INTO flyway_schema_history
            (installed_rank, version, description, type, script, checksum, installed_by, execution_time, success)
            VALUES (1, '1', '<< Flyway Baseline >>', 'BASELINE', '<< Flyway Baseline >>', NULL, CURRENT_USER(), 0, TRUE)`); err != nil {
			return errors.New("无法写入 Flyway 初始迁移记录")
		}
	}
	return nil
}

func splitSQLStatements(contents string) []string {
	statements := make([]string, 0)
	for _, raw := range strings.Split(contents, ";") {
		lines := make([]string, 0)
		for _, line := range strings.Split(raw, "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "--") {
				continue
			}
			lines = append(lines, line)
		}
		if statement := strings.TrimSpace(strings.Join(lines, "\n")); statement != "" {
			statements = append(statements, statement)
		}
	}
	return statements
}

func openMySQL(ctx context.Context, host string, port int, username, password, database string) (*sql.DB, error) {
	return openMySQLWithDatabase(ctx, host, port, username, password, database)
}

func openMySQLWithDatabase(ctx context.Context, host string, port int, username, password, database string) (*sql.DB, error) {
	host = normalizeMySQLHost(host)
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

func connectAndPrepareMySQL(ctx context.Context, host string, port int, username, password, database string) (*sql.DB, error) {
	serverDB, err := openMySQLWithDatabase(ctx, host, port, username, password, "")
	if err != nil {
		return nil, setupMySQLError{stage: "连接 MySQL 服务", err: err}
	}
	defer serverDB.Close()
	if err := ensureTargetDatabase(ctx, serverDB, database); err != nil {
		return nil, setupMySQLError{stage: "创建或检查目标数据库", err: err}
	}
	db, err := openMySQLWithDatabase(ctx, host, port, username, password, database)
	if err != nil {
		return nil, setupMySQLError{stage: "打开目标数据库", err: err}
	}
	return db, nil
}

func ensureTargetDatabase(ctx context.Context, db *sql.DB, database string) error {
	var exists int
	if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = ?", database).Scan(&exists); err != nil {
		return err
	}
	if exists > 0 {
		return nil
	}
	_, err := db.ExecContext(ctx, fmt.Sprintf("CREATE DATABASE IF NOT EXISTS %s CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci", quoteMySQLIdentifier(database)))
	return err
}

func quoteMySQLIdentifier(value string) string {
	return "`" + strings.ReplaceAll(value, "`", "``") + "`"
}

type setupMySQLError struct {
	stage string
	err   error
}

func (e setupMySQLError) Error() string { return e.stage + ": " + e.err.Error() }
func (e setupMySQLError) Unwrap() error { return e.err }

func mysqlSetupErrorMessage(err error) string {
	var setupErr setupMySQLError
	stage := "MySQL 操作"
	if errors.As(err, &setupErr) {
		stage = setupErr.stage
		err = setupErr.err
	}
	var mysqlErr *mysqlDriver.MySQLError
	if errors.As(err, &mysqlErr) {
		switch mysqlErr.Number {
		case 1045:
			return stage + "失败：MySQL 拒绝了用户名或密码。若填写 127.0.0.1/localhost，Docker 连接来源通常是宿主机网桥地址，请确认该账号允许从 Docker 网段登录。"
		case 1130:
			return stage + "失败：MySQL 拒绝了当前来源主机（错误码 1130）。请为该账号授权 Docker 网桥来源（通常使用账号@%或账号@宿主机网桥网段），仅允许 localhost 的账号不能从容器登录。"
		case 1044:
			return stage + "失败：当前 MySQL 用户没有目标数据库访问权限。请授予该用户目标库权限，或使用具备建库权限的账号。"
		case 1049:
			return stage + "失败：目标数据库不存在，且当前账号没有创建数据库权限。请授予 CREATE 权限或先创建空数据库。"
		case 1142, 1143, 1227:
			return stage + "失败：当前 MySQL 用户缺少建库、建表或索引权限。"
		case 1007:
			return stage + "失败：目标数据库已存在，但 MySQL 返回了重复建库错误；请确认账号对该库有访问权限。"
		}
		return fmt.Sprintf("%s失败：MySQL 错误码 %d，请检查账号来源、数据库权限和服务器日志。", stage, mysqlErr.Number)
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		return stage + "失败：网络连接超时或被拒绝，请检查 MySQL 监听地址、端口、防火墙和 Docker 网桥访问。"
	}
	return stage + "失败：请检查 MySQL 地址、端口、数据库名、用户名、密码和权限。"
}

func normalizeMySQLHost(host string) string {
	host = strings.TrimSpace(host)
	if setupHostGateway != "" && isLoopbackMySQLHost(host) {
		return setupHostGateway
	}
	return host
}

func isLoopbackMySQLHost(host string) bool {
	host = strings.Trim(strings.TrimSpace(host), "[]")
	return strings.EqualFold(host, "localhost") || host == "127.0.0.1" || host == "::1"
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
		"DB_URL=" + dotenvValue(fmt.Sprintf("jdbc:mysql://%s:%d/%s?useUnicode=true&characterEncoding=utf8&serverTimezone=UTC", normalizeMySQLHost(request.MySQLHost), request.MySQLPort, request.DatabaseName)),
		"DB_USERNAME=" + dotenvValue(request.MySQLUsername),
		"DB_PASSWORD=" + dotenvValue(request.MySQLPassword),
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
		return errors.New("请输入 MySQL 用户名和密码")
	}
	return nil
}

func validateSetupRequest(request setupRequest) error {
	if err := validateDatabaseTest(databaseTestRequest{Host: request.MySQLHost, Port: request.MySQLPort, DatabaseName: request.DatabaseName, Username: request.MySQLUsername, Password: request.MySQLPassword}); err != nil {
		return err
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
