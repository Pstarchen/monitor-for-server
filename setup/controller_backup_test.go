package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestCreateControllerBackupUsesSharedDumpPath(t *testing.T) {
	originalWorkspace, originalEnvPath := workspace, envPath
	originalExec := execCommandContext
	workspace = t.TempDir()
	envPath = filepath.Join(workspace, ".env")
	t.Cleanup(func() {
		workspace, envPath = originalWorkspace, originalEnvPath
		execCommandContext = originalExec
	})
	if err := os.WriteFile(envPath, []byte("POSTGRES_DB=xingchen_monitor\nPOSTGRES_USER=xingchen\nPOSTGRES_PASSWORD=test-only\n"), 0600); err != nil {
		t.Fatal(err)
	}
	execCommandContext = func(ctx context.Context, _ string, _ ...string) *exec.Cmd {
		return exec.CommandContext(ctx, os.Args[0], "-test.run=^TestControllerBackupCommandHelper$", "--", "controller-backup-helper")
	}
	name := "xingchen-monitor-20260904T010203Z.sql"
	path, err := createControllerBackup(context.Background(), name)
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "backup-data" {
		t.Fatalf("backup content = %q", content)
	}
}

func TestControllerBackupCommandHelper(t *testing.T) {
	for _, argument := range os.Args {
		if argument == "controller-backup-helper" {
			_, _ = fmt.Fprint(os.Stdout, "backup-data")
			os.Exit(0)
		}
	}
}

func TestControllerBackupRejectsPathTraversalAndUnknownFiles(t *testing.T) {
	originalWorkspace, originalStatePath := workspace, controllerBackupStatePath
	workspace = t.TempDir()
	controllerBackupStatePath = filepath.Join(workspace, ".controller-backup-state.json")
	t.Cleanup(func() { workspace, controllerBackupStatePath = originalWorkspace, originalStatePath })
	service := &controllerBackupService{token: "backup-token", now: time.Now}
	handler := service.authorize(http.HandlerFunc(service.restore))

	for _, name := range []string{"../.env", "backup.sql", "guanlan-monitor-20260831T120000Z.sql"} {
		request := httptest.NewRequest(http.MethodPost, "/internal/controller-backup/restore", strings.NewReader(`{"name":"`+name+`"}`))
		request.Header.Set("X-Controller-Update-Token", "backup-token")
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusBadRequest && response.Code != http.StatusNotFound {
			t.Fatalf("name %q returned %d", name, response.Code)
		}
	}
}

func TestControllerBackupListsOnlyValidatedSqlFiles(t *testing.T) {
	originalWorkspace := workspace
	workspace = t.TempDir()
	t.Cleanup(func() { workspace = originalWorkspace })
	if err := os.MkdirAll(controllerBackupDir(), 0700); err != nil {
		t.Fatal(err)
	}
	valid := filepath.Join(controllerBackupDir(), "xingchen-monitor-20260831T120000Z-4242.sql")
	if err := os.WriteFile(valid, []byte("-- backup\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(controllerBackupDir(), "notes.txt"), []byte("ignore"), 0600); err != nil {
		t.Fatal(err)
	}

	backups := listControllerBackups()
	if len(backups) != 1 || backups[0].Name != filepath.Base(valid) || backups[0].Size == 0 {
		t.Fatalf("unexpected backups: %+v", backups)
	}
}

func TestControllerBackupStateRoundTripsWithPrivatePermissions(t *testing.T) {
	originalStatePath := controllerBackupStatePath
	controllerBackupStatePath = filepath.Join(t.TempDir(), "state.json")
	t.Cleanup(func() { controllerBackupStatePath = originalStatePath })
	want := controllerBackupState{State: "IDLE", Message: "ok", Retention: 3, Backups: []controllerBackupFile{{Name: "guanlan-monitor-20260831T120000Z.sql", Size: 10}}}
	if err := writeControllerBackupState(want); err != nil {
		t.Fatal(err)
	}
	got := (&controllerBackupService{now: time.Now}).readState()
	encoded, err := json.Marshal(got)
	if err != nil || !strings.Contains(string(encoded), "guanlan-monitor-20260831T120000Z.sql") || got.Retention != 3 {
		t.Fatalf("state round trip failed: %+v (%v)", got, err)
	}
	info, err := os.Stat(controllerBackupStatePath)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0600 {
		t.Fatalf("state permissions = %o, want 600", info.Mode().Perm())
	}
}
