package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

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
	valid := filepath.Join(controllerBackupDir(), "guanlan-monitor-20260831T120000Z.sql")
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
