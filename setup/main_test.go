package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func validSetupRequest() setupRequest {
	return setupRequest{
		PublicBaseURL: "https://monitor.example.com", AllowedOrigins: "https://monitor.example.com", SiteName: "星辰云巡", Timezone: "Asia/Shanghai",
		AdminUsername: "admin", AdminPassword: "administrator-password", AdminPasswordConfirm: "administrator-password",
	}
}

func TestValidateSetupRequest(t *testing.T) {
	if err := validateSetupRequest(validSetupRequest()); err != nil {
		t.Fatalf("valid setup request rejected: %v", err)
	}

	request := validSetupRequest()
	request.PublicBaseURL = "https://monitor.example.com/"
	request.AllowedOrigins = "https://monitor.example.com/"
	if err := validateSetupRequest(request); err != nil {
		t.Fatalf("trailing origin slash should be accepted: %v", err)
	}

	request = validSetupRequest()
	request.Timezone = "not-a-timezone"
	if err := validateSetupRequest(request); err == nil {
		t.Fatal("invalid IANA timezone was accepted")
	}
}

func TestAgentInstallerOnlyServesAllowlistedPlatforms(t *testing.T) {
	originalWorkspace := workspace
	workspace = t.TempDir()
	t.Cleanup(func() { workspace = originalWorkspace })
	if err := os.MkdirAll(filepath.Join(workspace, "deploy"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "deploy", "install-agent.sh"), []byte("#!/usr/bin/env bash\r\nset -e\r\n"), 0600); err != nil {
		t.Fatal(err)
	}
	service := &setupService{}

	request := httptest.NewRequest(http.MethodGet, "/api/setup/agent-installer?platform=linux", nil)
	response := httptest.NewRecorder()
	service.agentInstaller(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "#!/usr/bin/env bash") || strings.Contains(response.Body.String(), "\r") {
		t.Fatalf("linux installer response = %d %q", response.Code, response.Body.String())
	}
	if response.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("installer response must not be cached")
	}

	request = httptest.NewRequest(http.MethodGet, "/api/setup/agent-installer?platform=../../.env", nil)
	response = httptest.NewRecorder()
	service.agentInstaller(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("invalid platform returned %d, want 400", response.Code)
	}
}

func TestValidateAllowedOriginsRequiresPublicOrigin(t *testing.T) {
	publicURL, err := url.Parse("https://monitor.example.com")
	if err != nil {
		t.Fatal(err)
	}
	if err := validateAllowedOrigins("https://other.example.com", publicURL); err == nil {
		t.Fatal("allowed origins without the public origin were accepted")
	}
	if err := validateAllowedOrigins("https://monitor.example.com, https://127.0.0.1:18080", publicURL); err != nil {
		t.Fatalf("valid additional origin rejected: %v", err)
	}
}

func TestConfiguredEnvRequiresPostgreSQLAndApplicationSecrets(t *testing.T) {
	originalEnvPath := envPath
	envPath = filepath.Join(t.TempDir(), ".env")
	t.Cleanup(func() { envPath = originalEnvPath })

	content := "SPRING_PROFILES_ACTIVE=production\nPOSTGRES_DB=guanlan_monitor\nPOSTGRES_USER=guanlan\nPOSTGRES_PASSWORD=database-password\nBOOTSTRAP_ADMIN_USERNAME=admin\nBOOTSTRAP_ADMIN_PASSWORD=administrator-password\nSETTINGS_ENCRYPTION_KEY=key\n"
	if err := os.WriteFile(envPath, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
	if !configuredEnv() {
		t.Fatal("complete PostgreSQL configuration was not detected")
	}

	if err := os.WriteFile(envPath, []byte(strings.Replace(content, "POSTGRES_PASSWORD=database-password\n", "", 1)), 0600); err != nil {
		t.Fatal(err)
	}
	if configuredEnv() {
		t.Fatal("configuration without PostgreSQL password was accepted")
	}
}

func TestComposeApplyDoesNotRecreateSetupService(t *testing.T) {
	t.Setenv("CONTROLLER_AGENT_ENABLED", "false")
	got := strings.Join(composeApplyArgs(), " ")
	want := "compose -f " + filepath.Join(workspace, "docker-compose.yml") + " --project-directory " + hostWorkspace + " --env-file " + envPath + " up -d --build --no-deps --wait --wait-timeout 300 server web"
	if got != want {
		t.Fatalf("composeApplyArgs() = %q, want %q", got, want)
	}
}

func TestComposeApplyEnablesControllerHostMonitoring(t *testing.T) {
	t.Setenv("CONTROLLER_AGENT_ENABLED", "true")
	got := strings.Join(composeApplyArgs(), " ")
	if !strings.Contains(got, "--profile host-monitoring up") {
		t.Fatalf("controller monitoring profile missing: %q", got)
	}
}

func TestSetupStatusWaitsForProductionCompletionMarker(t *testing.T) {
	originalWorkspace, originalEnvPath, originalMarkerPath := workspace, envPath, completionMarkerPath
	workspace = t.TempDir()
	envPath = filepath.Join(workspace, ".env")
	completionMarkerPath = filepath.Join(workspace, ".setup-complete")
	t.Cleanup(func() {
		workspace, envPath, completionMarkerPath = originalWorkspace, originalEnvPath, originalMarkerPath
	})

	content := "SPRING_PROFILES_ACTIVE=production\nPOSTGRES_DB=guanlan_monitor\nPOSTGRES_USER=guanlan\nPOSTGRES_PASSWORD=database-password\nBOOTSTRAP_ADMIN_USERNAME=admin\nBOOTSTRAP_ADMIN_PASSWORD=administrator-password\nSETTINGS_ENCRYPTION_KEY=key\nPUBLIC_BASE_URL=https://monitor.example.com\n"
	if err := os.WriteFile(envPath, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}

	service := &setupService{applying: true}
	status := requestSetupStatus(t, service)
	if !status.Configured || status.State != "applying" {
		t.Fatalf("active setup status = %+v, want configured applying", status)
	}

	service.applying = false
	status = requestSetupStatus(t, service)
	if !status.Configured || status.State != "applying" {
		t.Fatalf("unmarked setup status = %+v, want configured applying", status)
	}

	if err := writeSetupCompletionMarker(); err != nil {
		t.Fatal(err)
	}
	status = requestSetupStatus(t, service)
	if !status.Configured || status.State != "configured" || status.BaseURL != "https://monitor.example.com" {
		t.Fatalf("completed setup status = %+v", status)
	}
}

func TestWriteEnvironmentPreservesInstallerWebListener(t *testing.T) {
	originalWorkspace, originalEnvPath := workspace, envPath
	workspace = t.TempDir()
	envPath = filepath.Join(workspace, ".env")
	t.Cleanup(func() { workspace, envPath = originalWorkspace, originalEnvPath })
	t.Setenv("POSTGRES_PASSWORD", "database-password")
	t.Setenv("WEB_PORT", "19090")
	t.Setenv("WEB_BIND_ADDRESS", "127.0.0.1")
	t.Setenv("CONTROLLER_AGENT_ENABLED", "true")
	t.Setenv("CONTROLLER_AGENT_DEVICE_ID", "controller-device-id")
	t.Setenv("CONTROLLER_AGENT_KEY", "controller-agent-key")
	if err := os.WriteFile(envPath, []byte("CONTROLLER_AUTO_UPDATE=\"true\"\n"), 0600); err != nil {
		t.Fatal(err)
	}

	if err := writeEnvironment(validSetupRequest()); err != nil {
		t.Fatal(err)
	}
	values, err := readEnv()
	if err != nil {
		t.Fatal(err)
	}
	if values["WEB_PORT"] != "19090" || values["WEB_BIND_ADDRESS"] != "127.0.0.1" {
		t.Fatalf("listener settings were not preserved: port=%q bind=%q", values["WEB_PORT"], values["WEB_BIND_ADDRESS"])
	}
	if values["CONTROLLER_AGENT_ENABLED"] != "true" || values["CONTROLLER_AGENT_DEVICE_ID"] != "controller-device-id" || values["CONTROLLER_AGENT_KEY"] != "controller-agent-key" {
		t.Fatal("controller Agent settings were not preserved")
	}
	if values["CONTROLLER_AUTO_UPDATE"] != "true" {
		t.Fatal("controller automatic update setting was not preserved")
	}
}

func requestSetupStatus(t *testing.T, service *setupService) setupStatus {
	t.Helper()
	request := httptest.NewRequest(http.MethodGet, "/api/setup/status", nil)
	response := httptest.NewRecorder()
	service.status(response, request)
	var status setupStatus
	if err := json.NewDecoder(response.Body).Decode(&status); err != nil {
		t.Fatal(err)
	}
	return status
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
	request := httptest.NewRequest(http.MethodPost, "http://setup:8090/api/setup/complete", nil)
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
	request := httptest.NewRequest(http.MethodPost, "http://setup:8090/api/setup/complete", nil)
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
	request := httptest.NewRequest(http.MethodPost, "http://setup:8090/api/setup/complete", nil)
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
