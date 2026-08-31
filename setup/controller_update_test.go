package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
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

func TestUpdateControllerCommandUsesBash(t *testing.T) {
	command := updateControllerCommand(context.Background(), "--check")
	if got, want := command.Args, []string{"bash", filepath.Join(workspace, "deploy", "update-controller.sh"), "--check"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("updateControllerCommand args = %v, want %v", got, want)
	}
}

func TestComposeBaseArgsUseHostWorkspace(t *testing.T) {
	originalWorkspace, originalHostWorkspace, originalEnvPath := workspace, hostWorkspace, envPath
	workspace = "/container/workspace"
	hostWorkspace = "/host/project"
	envPath = filepath.Join(workspace, ".env")
	t.Cleanup(func() { workspace, hostWorkspace, envPath = originalWorkspace, originalHostWorkspace, originalEnvPath })

	args := composeBaseArgs()
	joined := strings.Join(args, " ")
	expected := "-f " + filepath.Join("/container/workspace", "docker-compose.yml") + " --project-directory /host/project --env-file " + filepath.Join("/container/workspace", ".env")
	if !strings.Contains(joined, expected) {
		t.Fatalf("composeBaseArgs() = %q, does not use host project paths", joined)
	}
}

func TestControllerUpdateRunnerPassesRunnerEnvironment(t *testing.T) {
	t.Setenv("COMPOSE_PROJECT_NAME", "custom-monitor")
	args := controllerUpdateRunnerArgs()
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "-e CONTROLLER_UPDATE_RUNNER=true") {
		t.Fatalf("controllerUpdateRunnerArgs() = %q, missing runner environment", joined)
	}
	if !strings.Contains(joined, "--project-name custom-monitor-update-runner run") {
		t.Fatalf("controllerUpdateRunnerArgs() = %q, runner is not isolated from the controller project", joined)
	}
	if !strings.Contains(joined, "-e COMPOSE_PROJECT_NAME=custom-monitor") {
		t.Fatalf("controllerUpdateRunnerArgs() = %q, inner updater target project was not preserved", joined)
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

func TestControllerUpdateStateExpiryIsRecoverable(t *testing.T) {
	now := time.Date(2026, 8, 23, 12, 0, 0, 0, time.UTC)
	service := &controllerUpdateService{now: func() time.Time { return now }}

	if !service.isStale(controllerUpdateState{State: "UPDATING", StartedAt: now.Add(-controllerUpdateApplyStaleAfter - time.Minute).Format(time.RFC3339)}) {
		t.Fatal("expired update state was not considered stale")
	}
	if service.isStale(controllerUpdateState{State: "UPDATING", StartedAt: now.Add(-time.Minute).Format(time.RFC3339)}) {
		t.Fatal("active update state was incorrectly considered stale")
	}
	if !service.isStale(controllerUpdateState{State: "UPDATING"}) {
		t.Fatal("legacy update state without a start time was not recoverable")
	}
}

func TestControllerUpdateStaleWindowsOutliveCommandTimeouts(t *testing.T) {
	if controllerUpdateCheckStaleAfter <= controllerUpdateCheckTimeout {
		t.Fatalf("check stale window %s must exceed command timeout %s", controllerUpdateCheckStaleAfter, controllerUpdateCheckTimeout)
	}
	if controllerUpdateApplyStaleAfter <= controllerUpdateApplyTimeout {
		t.Fatalf("apply stale window %s must exceed command timeout %s", controllerUpdateApplyStaleAfter, controllerUpdateApplyTimeout)
	}
}

func TestControllerUpdateRunnerStartExpiry(t *testing.T) {
	now := time.Date(2026, 8, 23, 12, 0, 0, 0, time.UTC)
	service := &controllerUpdateService{now: func() time.Time { return now }}

	if service.updateRunnerStartExpired(controllerUpdateState{State: "UPDATING", StartedAt: now.Add(-controllerUpdateRunnerGracePeriod + time.Second).Format(time.RFC3339)}) {
		t.Fatal("runner start grace period expired too early")
	}
	if !service.updateRunnerStartExpired(controllerUpdateState{State: "UPDATING", StartedAt: now.Add(-controllerUpdateRunnerGracePeriod - time.Second).Format(time.RFC3339)}) {
		t.Fatal("missing runner was not eligible for recovery")
	}
	if service.updateRunnerStartExpired(controllerUpdateState{State: "CHECKING", StartedAt: now.Add(-controllerUpdateRunnerGracePeriod - time.Second).Format(time.RFC3339)}) {
		t.Fatal("checking state was treated as a runner update")
	}
}

func TestControllerUpdateSnapshotClearsExpiredState(t *testing.T) {
	originalWorkspace, originalEnvPath, originalStatePath := workspace, envPath, controllerUpdateStatePath
	workspace = t.TempDir()
	envPath = filepath.Join(workspace, ".env")
	controllerUpdateStatePath = filepath.Join(workspace, ".controller-update-state.json")
	t.Cleanup(func() {
		workspace, envPath, controllerUpdateStatePath = originalWorkspace, originalEnvPath, originalStatePath
		invalidateControllerInspectionCache()
	})
	now := time.Date(2026, 8, 23, 12, 0, 0, 0, time.UTC)
	if err := writeControllerUpdateState(controllerUpdateState{State: "UPDATING", StartedAt: now.Add(-controllerUpdateApplyStaleAfter - time.Minute).Format(time.RFC3339), Services: []controllerServiceStatus{}}); err != nil {
		t.Fatal(err)
	}
	controllerInspectionCache.Lock()
	controllerInspectionCache.at = time.Now()
	controllerInspectionCache.value = controllerInspection{services: []controllerServiceStatus{}}
	controllerInspectionCache.Unlock()

	state := (&controllerUpdateService{now: func() time.Time { return now }}).snapshot()
	if state.State != "ERROR" || state.StartedAt != "" {
		t.Fatalf("expired snapshot = %+v, want recoverable error", state)
	}
	persisted := (&controllerUpdateService{now: func() time.Time { return now }}).readState()
	if persisted.State != "ERROR" {
		t.Fatalf("persisted state = %+v, want ERROR", persisted)
	}
}
