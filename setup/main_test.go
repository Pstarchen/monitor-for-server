package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	mysqlDriver "github.com/go-sql-driver/mysql"
)

func validSetupRequest() setupRequest {
	return setupRequest{
		MySQLHost: "host.docker.internal", MySQLPort: 3306, DatabaseName: "monitor", MySQLUsername: "monitor", MySQLPassword: "database-password",
		PublicBaseURL: "https://monitor.example.com", AllowedOrigins: "https://monitor.example.com", SiteName: "观澜监控", Timezone: "Asia/Shanghai", WebPort: 18080, WebBindAddress: "127.0.0.1",
		AdminUsername: "admin", AdminPassword: "administrator-password", AdminPasswordConfirm: "administrator-password",
	}
}

func TestValidateSetupRequest(t *testing.T) {
	if err := validateSetupRequest(validSetupRequest()); err != nil {
		t.Fatalf("valid setup request rejected: %v", err)
	}

	request := validSetupRequest()
	request.DatabaseName = "monitor-prod;drop"
	if err := validateSetupRequest(request); err == nil {
		t.Fatal("unsafe database identifier was accepted")
	}
}

func TestValidateDatabaseTestRequiresTargetDatabase(t *testing.T) {
	request := databaseTestRequest{Host: "127.0.0.1", Port: 3306, Username: "root", Password: "secret"}
	if err := validateDatabaseTest(request); err == nil {
		t.Fatal("database connection test accepted an empty target database")
	}
}

func TestNormalizeMySQLHostUsesDockerHostGateway(t *testing.T) {
	previousGateway := setupHostGateway
	setupHostGateway = "host.docker.internal"
	defer func() { setupHostGateway = previousGateway }()

	for _, host := range []string{"127.0.0.1", "localhost", "[::1]"} {
		if got := normalizeMySQLHost(host); got != "host.docker.internal" {
			t.Fatalf("normalizeMySQLHost(%q) = %q, want host gateway", host, got)
		}
	}
	if got := normalizeMySQLHost("10.0.0.12"); got != "10.0.0.12" {
		t.Fatalf("remote MySQL host was rewritten: %q", got)
	}
}

func TestNormalizeMySQLHostLeavesLoopbackWhenGatewayIsUnset(t *testing.T) {
	previousGateway := setupHostGateway
	setupHostGateway = ""
	defer func() { setupHostGateway = previousGateway }()

	if got := normalizeMySQLHost("127.0.0.1"); got != "127.0.0.1" {
		t.Fatalf("native setup unexpectedly rewrote loopback host: %q", got)
	}
}

func TestMySQLSetupErrorMessageExplainsAccessDenied(t *testing.T) {
	err := setupMySQLError{stage: "连接 MySQL 服务", err: &mysqlDriver.MySQLError{Number: 1045}}
	message := mysqlSetupErrorMessage(err)
	if !strings.Contains(message, "用户名或密码") || !strings.Contains(message, "Docker 网段") {
		t.Fatalf("unexpected access denied message: %s", message)
	}
}

func TestMySQLSetupErrorMessageExplainsHostDenied(t *testing.T) {
	err := setupMySQLError{stage: "连接 MySQL 服务", err: &mysqlDriver.MySQLError{Number: 1130}}
	message := mysqlSetupErrorMessage(err)
	if !strings.Contains(message, "来源主机") || !strings.Contains(message, "仅允许 localhost") {
		t.Fatalf("unexpected host denied message: %s", message)
	}
}

func TestMySQLSetupErrorMessageExplainsMissingDatabasePermission(t *testing.T) {
	err := setupMySQLError{stage: "创建或检查目标数据库", err: &mysqlDriver.MySQLError{Number: 1049}}
	message := mysqlSetupErrorMessage(err)
	if !strings.Contains(message, "数据库不存在") || !strings.Contains(message, "CREATE 权限") {
		t.Fatalf("unexpected missing database message: %s", message)
	}
}

func TestQuoteMySQLIdentifier(t *testing.T) {
	if got := quoteMySQLIdentifier("monitor"); got != "`monitor`" {
		t.Fatalf("quoteMySQLIdentifier() = %q", got)
	}
}

func TestSplitSQLStatementsRemovesComments(t *testing.T) {
	statements := splitSQLStatements("-- first table\nCREATE TABLE one (id INT);\n\nCREATE TABLE two (id INT);")
	if len(statements) != 2 || statements[0] != "CREATE TABLE one (id INT)" || statements[1] != "CREATE TABLE two (id INT)" {
		t.Fatalf("splitSQLStatements() = %#v", statements)
	}
}

func TestDotenvValueEscapesComposeInterpolation(t *testing.T) {
	got := dotenvValue(`pa$ss\"word`)
	want := `"pa$$ss\\\"word"`
	if got != want {
		t.Fatalf("dotenvValue() = %q, want %q", got, want)
	}
}

func TestOriginGuardAcceptsForwardedPort(t *testing.T) {
	handler := withOriginGuard(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	request := httptest.NewRequest(http.MethodPost, "http://setup:8090/api/setup/test-database", nil)
	request.Host = "111.170.155.150"
	request.Header.Set("Origin", "http://111.170.155.150:18080")
	request.Header.Set("X-Forwarded-Host", "111.170.155.150:18080")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("forwarded origin rejected with status %d", response.Code)
	}
}

func TestOriginGuardAcceptsForwardedPublicHost(t *testing.T) {
	handler := withOriginGuard(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	request := httptest.NewRequest(http.MethodPost, "http://setup:8090/api/setup/test-database", nil)
	request.Host = "localhost"
	request.Header.Set("Origin", "http://monitor.xciy.cn")
	request.Header.Set("X-Forwarded-Host", "monitor.xciy.cn")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("forwarded public host rejected with status %d", response.Code)
	}
}

func TestOriginGuardRejectsDifferentHost(t *testing.T) {
	handler := withOriginGuard(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	request := httptest.NewRequest(http.MethodPost, "http://setup:8090/api/setup/test-database", nil)
	request.Host = "monitor.example.com"
	request.Header.Set("Origin", "https://evil.example.com")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("different origin accepted with status %d", response.Code)
	}
}

func TestOriginMatchesHostNormalizesDefaultPort(t *testing.T) {
	origin, err := url.Parse("https://monitor.example.com")
	if err != nil || !originMatchesHost(origin, "monitor.example.com:443") {
		t.Fatal("https origin should match its default port")
	}
}
