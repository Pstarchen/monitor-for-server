package executor

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"guanlan-monitor/agent/internal/model"
)

func TestRunUsesCommandArgumentsWithoutShell(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("portable command fixture uses sh")
	}
	result := Run(context.Background(), model.TaskAssignment{
		Command: "printf", Args: []string{"%s", "hello; touch /tmp/should-not-exist"}, TimeoutSeconds: 2, MaxOutputBytes: 1024,
	}, 1024, true, false, "")
	if result.Status != "SUCCEEDED" || result.Stdout != "hello; touch /tmp/should-not-exist" {
		t.Fatalf("unexpected result: %+v", result)
	}
}

func TestRunTimesOutAndLimitsOutput(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("portable command fixture uses sh")
	}
	result := Run(context.Background(), model.TaskAssignment{
		Command: "sh", Args: []string{"-c", "printf '1234567890'; sleep 2"}, TimeoutSeconds: 1, MaxOutputBytes: 5,
	}, 5, true, false, "")
	if result.Status != "TIMED_OUT" || len(result.Stdout) != 5 || !strings.HasPrefix(result.Stdout, "12345") {
		t.Fatalf("unexpected timeout result: %+v", result)
	}
}

func TestRunHonorsParentCancellation(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("portable command fixture uses sh")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	result := Run(ctx, model.TaskAssignment{Command: "sleep", Args: []string{"2"}, TimeoutSeconds: 30, MaxOutputBytes: 1024}, 1024, true, false, "")
	if result.Status != "TIMED_OUT" {
		t.Fatalf("status = %s, want TIMED_OUT", result.Status)
	}
}

func TestRunRejectsInvalidTaskTimeout(t *testing.T) {
	result := Run(context.Background(), model.TaskAssignment{Command: "printf", TimeoutSeconds: 0}, 1024, true, false, "")
	if result.Status != "FAILED" || !strings.Contains(result.Error, "timeout") {
		t.Fatalf("result = %+v", result)
	}
}

func TestRunFileOperationsUseHostRootAndOptimisticLock(t *testing.T) {
	root := t.TempDir()
	write := model.TaskAssignment{ID: 1, Operation: "FILE_WRITE", Command: "file.file_write", Payload: json.RawMessage(`{"path":"/nested/note.txt","content":"hello","encoding":"utf8","createDirs":true}`), TimeoutSeconds: 2, MaxOutputBytes: 4096}
	result := Run(context.Background(), write, 4096, false, true, root)
	if result.Status != "SUCCEEDED" {
		t.Fatalf("write result = %+v", result)
	}
	if _, err := os.Stat(filepath.Join(root, "nested", "note.txt")); err != nil {
		t.Fatal(err)
	}

	read := model.TaskAssignment{ID: 2, Operation: "FILE_READ", Command: "file.file_read", Payload: json.RawMessage(`{"path":"/nested/note.txt","offset":0,"length":20,"encoding":"utf8"}`), TimeoutSeconds: 2, MaxOutputBytes: 4096}
	result = Run(context.Background(), read, 4096, false, true, root)
	if result.Status != "SUCCEEDED" || !strings.Contains(result.Stdout, `"content":"hello"`) {
		t.Fatalf("read result = %+v", result)
	}

	stale := write
	stale.Payload = json.RawMessage(`{"path":"/nested/note.txt","content":"changed","encoding":"utf8","ifMatchSha256":"0000000000000000000000000000000000000000000000000000000000000000"}`)
	result = Run(context.Background(), stale, 4096, false, true, root)
	if result.Status != "FAILED" || !strings.Contains(result.Error, "changed") {
		t.Fatalf("stale write result = %+v", result)
	}
}

func TestRunFileRejectsRootEscapeAndUnsafeDelete(t *testing.T) {
	root := t.TempDir()
	escape := model.TaskAssignment{Operation: "FILE_READ", Command: "file.file_read", Payload: json.RawMessage(`{"path":"../../outside","length":10}`), TimeoutSeconds: 2, MaxOutputBytes: 4096}
	if result := Run(context.Background(), escape, 4096, false, true, root); result.Status != "FAILED" || !strings.Contains(result.Error, "escapes") {
		t.Fatalf("escape result = %+v", result)
	}
	directory := filepath.Join(root, "directory")
	if err := os.Mkdir(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	delete := model.TaskAssignment{Operation: "FILE_DELETE", Command: "file.file_delete", Payload: json.RawMessage(`{"path":"/directory","recursive":false}`), TimeoutSeconds: 2, MaxOutputBytes: 4096}
	if result := Run(context.Background(), delete, 4096, false, true, root); result.Status != "FAILED" || !strings.Contains(result.Error, "recursive") {
		t.Fatalf("delete result = %+v", result)
	}
	rootDelete := delete
	rootDelete.Payload = json.RawMessage(`{"path":"/","recursive":true}`)
	if result := Run(context.Background(), rootDelete, 4096, false, true, root); result.Status != "FAILED" || !strings.Contains(result.Error, "root itself") {
		t.Fatalf("root delete result = %+v", result)
	}
}

func TestRunFileStopsWhenContextIsCanceled(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "cancel-me")
	if err := os.WriteFile(path, []byte("content"), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	result := Run(ctx, model.TaskAssignment{
		Operation: "FILE_DELETE", Command: "file.file_delete",
		Payload: json.RawMessage(`{"path":"/cancel-me","recursive":false}`), TimeoutSeconds: 2, MaxOutputBytes: 4096,
	}, 4096, false, true, root)
	if result.Status != "TIMED_OUT" {
		t.Fatalf("status = %s, want TIMED_OUT", result.Status)
	}
}
