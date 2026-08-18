package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func validSetupRequest() setupRequest {
	return setupRequest{
		MySQLAdminHost: "host.docker.internal", MySQLAdminPort: 3306, MySQLAdminUsername: "root", MySQLAdminPassword: "admin-password",
		MySQLAppHost: "host.docker.internal", MySQLAppPort: 3306, DatabaseName: "monitor", AppUsername: "monitor", AppPassword: "application-password", AppPasswordConfirm: "application-password",
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
