package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestControllerUpdateInternalAuthentication(t *testing.T) {
	service := &controllerUpdateService{token: "internal-token", now: time.Now}
	handler := service.authorize(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }))

	for _, token := range []string{"", "wrong-token"} {
		request := httptest.NewRequest(http.MethodGet, "/internal/controller-update/status", nil)
		request.Header.Set("X-Controller-Update-Token", token)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("token %q returned %d, want 401", token, response.Code)
		}
	}

	request := httptest.NewRequest(http.MethodGet, "/internal/controller-update/status", nil)
	request.Header.Set("X-Controller-Update-Token", "internal-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("valid token returned %d, want 204", response.Code)
	}
}

func TestUpdateEnvironmentSettingAddsAndReplacesValue(t *testing.T) {
	originalEnvPath := envPath
	envPath = filepath.Join(t.TempDir(), ".env")
	t.Cleanup(func() { envPath = originalEnvPath })
	if err := os.WriteFile(envPath, []byte("EXISTING=value\nCONTROLLER_AUTO_UPDATE=\"false\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := updateEnvironmentSetting("CONTROLLER_AUTO_UPDATE", "true"); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(envPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(content), "CONTROLLER_AUTO_UPDATE=") != 1 || !strings.Contains(string(content), `CONTROLLER_AUTO_UPDATE="true"`) {
		t.Fatalf("unexpected environment content: %q", content)
	}
}

func TestNextAutoUpdateUsesConfiguredLocalTime(t *testing.T) {
	originalEnvPath := envPath
	envPath = filepath.Join(t.TempDir(), ".env")
	t.Cleanup(func() { envPath = originalEnvPath })
	if err := os.WriteFile(envPath, []byte("APP_TIMEZONE=Asia/Shanghai\n"), 0600); err != nil {
		t.Fatal(err)
	}
	service := &controllerUpdateService{now: func() time.Time {
		return time.Date(2026, 8, 20, 20, 30, 0, 0, time.UTC)
	}}
	next := service.nextAutoUpdate()
	if got := next.Format("2006-01-02 15:04 MST"); got != "2026-08-22 04:00 CST" {
		t.Fatalf("nextAutoUpdate() = %q", got)
	}
}
