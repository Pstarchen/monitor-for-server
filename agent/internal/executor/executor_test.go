package executor

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"xingchen-monitor/agent/internal/model"
)

func TestRunUsesCommandArgumentsWithoutShell(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("portable command fixture uses sh")
	}
	result := Run(context.Background(), model.TaskAssignment{
		Command: "printf", Args: []string{"%s", "hello; touch /tmp/should-not-exist"}, TimeoutSeconds: 2, MaxOutputBytes: 1024,
	}, 1024, true, false, "", "", "")
	if result.Status != "SUCCEEDED" || result.Stdout != "hello; touch /tmp/should-not-exist" {
		t.Fatalf("unexpected result: %+v", result)
	}
}

func TestLimitedBufferCapsReadFromOutput(t *testing.T) {
	var buffer limitedBuffer
	buffer.limit = 5
	if _, err := io.Copy(&buffer, strings.NewReader("1234567890")); err != nil {
		t.Fatal(err)
	}
	if got := buffer.String(); got != "12345" {
		t.Fatalf("buffer = %q, want 12345", got)
	}
}

func TestRunTimesOutAndLimitsOutput(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("portable command fixture uses sh")
	}
	result := Run(context.Background(), model.TaskAssignment{
		Command: "sh", Args: []string{"-c", "printf '1234567890'; sleep 2"}, TimeoutSeconds: 1, MaxOutputBytes: 5,
	}, 5, true, false, "", "", "")
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
	result := Run(ctx, model.TaskAssignment{Command: "sleep", Args: []string{"2"}, TimeoutSeconds: 30, MaxOutputBytes: 1024}, 1024, true, false, "", "", "")
	if result.Status != "TIMED_OUT" {
		t.Fatalf("status = %s, want TIMED_OUT", result.Status)
	}
}

func TestRunRejectsInvalidTaskTimeout(t *testing.T) {
	result := Run(context.Background(), model.TaskAssignment{Command: "printf", TimeoutSeconds: 0}, 1024, true, false, "", "", "")
	if result.Status != "FAILED" || !strings.Contains(result.Error, "timeout") {
		t.Fatalf("result = %+v", result)
	}
}

func TestRunFileOperationsUseHostRootAndOptimisticLock(t *testing.T) {
	root := t.TempDir()
	write := model.TaskAssignment{ID: 1, Operation: "FILE_WRITE", Command: "file.file_write", Payload: json.RawMessage(`{"path":"/nested/note.txt","content":"hello","encoding":"utf8","createDirs":true}`), TimeoutSeconds: 2, MaxOutputBytes: 4096}
	result := Run(context.Background(), write, 4096, false, true, root, "", "")
	if result.Status != "SUCCEEDED" {
		t.Fatalf("write result = %+v", result)
	}
	if _, err := os.Stat(filepath.Join(root, "nested", "note.txt")); err != nil {
		t.Fatal(err)
	}

	read := model.TaskAssignment{ID: 2, Operation: "FILE_READ", Command: "file.file_read", Payload: json.RawMessage(`{"path":"/nested/note.txt","offset":0,"length":20,"encoding":"utf8"}`), TimeoutSeconds: 2, MaxOutputBytes: 4096}
	result = Run(context.Background(), read, 4096, false, true, root, "", "")
	if result.Status != "SUCCEEDED" || !strings.Contains(result.Stdout, `"content":"hello"`) {
		t.Fatalf("read result = %+v", result)
	}

	stale := write
	stale.Payload = json.RawMessage(`{"path":"/nested/note.txt","content":"changed","encoding":"utf8","ifMatchSha256":"0000000000000000000000000000000000000000000000000000000000000000"}`)
	result = Run(context.Background(), stale, 4096, false, true, root, "", "")
	if result.Status != "FAILED" || !strings.Contains(result.Error, "changed") {
		t.Fatalf("stale write result = %+v", result)
	}
}

func TestRunFileRejectsRootEscapeAndUnsafeDelete(t *testing.T) {
	root := t.TempDir()
	escape := model.TaskAssignment{Operation: "FILE_READ", Command: "file.file_read", Payload: json.RawMessage(`{"path":"../../outside","length":10}`), TimeoutSeconds: 2, MaxOutputBytes: 4096}
	if result := Run(context.Background(), escape, 4096, false, true, root, "", ""); result.Status != "FAILED" || !strings.Contains(result.Error, "escapes") {
		t.Fatalf("escape result = %+v", result)
	}
	directory := filepath.Join(root, "directory")
	if err := os.Mkdir(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	delete := model.TaskAssignment{Operation: "FILE_DELETE", Command: "file.file_delete", Payload: json.RawMessage(`{"path":"/directory","recursive":false}`), TimeoutSeconds: 2, MaxOutputBytes: 4096}
	if result := Run(context.Background(), delete, 4096, false, true, root, "", ""); result.Status != "FAILED" || !strings.Contains(result.Error, "recursive") {
		t.Fatalf("delete result = %+v", result)
	}
	rootDelete := delete
	rootDelete.Payload = json.RawMessage(`{"path":"/","recursive":true}`)
	if result := Run(context.Background(), rootDelete, 4096, false, true, root, "", ""); result.Status != "FAILED" || !strings.Contains(result.Error, "root itself") {
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
	}, 4096, false, true, root, "", "")
	if result.Status != "TIMED_OUT" {
		t.Fatalf("status = %s, want TIMED_OUT", result.Status)
	}
}

func TestRunAgentUpdatePublishesStrictRequestWithoutCommandPermissions(t *testing.T) {
	directory := t.TempDir()
	requestPath := filepath.Join(directory, "update-request")
	originalTrigger := requestTrigger
	requestTrigger = func(string) error { return nil }
	defer func() { requestTrigger = originalTrigger }()

	result := Run(context.Background(), model.TaskAssignment{
		ID:             19,
		Operation:      model.TaskOperationAgentUpdate,
		Command:        model.TaskCommandAgentUpdate,
		Payload:        json.RawMessage(`{"action":"update","version":"v1.20.14","rolloutId":7,"memberId":11}`),
		TimeoutSeconds: 2,
		MaxOutputBytes: 1024,
	}, 1024, false, false, "", requestPath, "configured-launcher")
	if result.Status != "SUCCEEDED" || result.Stdout != `{"status":"ACCEPTED"}` || result.ExitCode != nil {
		t.Fatalf("unexpected update result: %+v", result)
	}
	body, err := os.ReadFile(requestPath)
	if err != nil {
		t.Fatal(err)
	}
	want := "action=update\nversion=v1.20.14\nrollout_id=7\nmember_id=11\n"
	if string(body) != want {
		t.Fatalf("request = %q, want %q", body, want)
	}
}

func TestRunAgentUpdateRejectsUnsafeOrAmbiguousPayloads(t *testing.T) {
	directory := t.TempDir()
	cases := map[string]model.TaskAssignment{
		"disabled":       {Operation: model.TaskOperationAgentUpdate, Command: model.TaskCommandAgentUpdate, Payload: json.RawMessage(`{"action":"update","version":"v1.20.14"}`), TimeoutSeconds: 2},
		"empty command":  {Operation: model.TaskOperationAgentUpdate, Payload: json.RawMessage(`{"action":"update","version":"v1.20.14"}`), TimeoutSeconds: 2},
		"other command":  {Operation: model.TaskOperationAgentUpdate, Command: "sh", Payload: json.RawMessage(`{"action":"update","version":"v1.20.14"}`), TimeoutSeconds: 2},
		"args":           {Operation: model.TaskOperationAgentUpdate, Command: model.TaskCommandAgentUpdate, Args: []string{"--force"}, Payload: json.RawMessage(`{"action":"update","version":"v1.20.14"}`), TimeoutSeconds: 2},
		"unknown field":  {Operation: model.TaskOperationAgentUpdate, Command: model.TaskCommandAgentUpdate, Payload: json.RawMessage(`{"action":"update","version":"v1.20.14","url":"https://example.com"}`), TimeoutSeconds: 2},
		"prerelease":     {Operation: model.TaskOperationAgentUpdate, Command: model.TaskCommandAgentUpdate, Payload: json.RawMessage(`{"action":"update","version":"v1.20.14-rc.1"}`), TimeoutSeconds: 2},
		"missing prefix": {Operation: model.TaskOperationAgentUpdate, Command: model.TaskCommandAgentUpdate, Payload: json.RawMessage(`{"action":"update","version":"1.20.14"}`), TimeoutSeconds: 2},
		"bad action":     {Operation: model.TaskOperationAgentUpdate, Command: model.TaskCommandAgentUpdate, Payload: json.RawMessage(`{"action":"command","version":"v1.20.14"}`), TimeoutSeconds: 2},
		"partial IDs":    {Operation: model.TaskOperationAgentUpdate, Command: model.TaskCommandAgentUpdate, Payload: json.RawMessage(`{"action":"rollback","version":"v1.20.13","rolloutId":7}`), TimeoutSeconds: 2},
		"zero ID":        {Operation: model.TaskOperationAgentUpdate, Command: model.TaskCommandAgentUpdate, Payload: json.RawMessage(`{"action":"rollback","version":"v1.20.13","rolloutId":0,"memberId":1}`), TimeoutSeconds: 2},
		"null IDs":       {Operation: model.TaskOperationAgentUpdate, Command: model.TaskCommandAgentUpdate, Payload: json.RawMessage(`{"action":"rollback","version":"v1.20.13","rolloutId":null,"memberId":null}`), TimeoutSeconds: 2},
	}
	for name, task := range cases {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(directory, strings.ReplaceAll(name, " ", "-"))
			if name == "disabled" {
				path = ""
			}
			result := Run(context.Background(), task, 1024, true, true, directory, path, "")
			if result.Status != "FAILED" {
				t.Fatalf("unsafe task accepted: %+v", result)
			}
		})
	}
}

func TestRunAgentUpdateDoesNotReplacePendingRequest(t *testing.T) {
	directory := t.TempDir()
	requestPath := filepath.Join(directory, "update-request")
	if err := os.WriteFile(requestPath, []byte("existing"), 0o600); err != nil {
		t.Fatal(err)
	}
	result := Run(context.Background(), model.TaskAssignment{
		Operation: model.TaskOperationAgentUpdate, Command: model.TaskCommandAgentUpdate, Payload: json.RawMessage(`{"action":"update","version":"v1.20.14"}`), TimeoutSeconds: 2,
	}, 1024, false, false, "", requestPath, "")
	if result.Status != "FAILED" || !strings.Contains(result.Error, "pending") {
		t.Fatalf("unexpected pending result: %+v", result)
	}
	body, err := os.ReadFile(requestPath)
	if err != nil || string(body) != "existing" {
		t.Fatalf("pending request was replaced: %q, %v", body, err)
	}
}

func TestRunAgentUpdateRemovesRequestWhenLauncherFails(t *testing.T) {
	directory := t.TempDir()
	requestPath := filepath.Join(directory, "update-request")
	originalTrigger := requestTrigger
	requestTrigger = func(string) error { return errors.New("launcher unavailable") }
	defer func() { requestTrigger = originalTrigger }()

	result := Run(context.Background(), model.TaskAssignment{
		Operation: model.TaskOperationAgentUpdate, Command: model.TaskCommandAgentUpdate, Payload: json.RawMessage(`{"action":"rollback","version":"v1.20.13"}`), TimeoutSeconds: 2,
	}, 1024, false, false, "", requestPath, "configured-launcher")
	if result.Status != "FAILED" || !strings.Contains(result.Error, "triggered") {
		t.Fatalf("unexpected trigger result: %+v", result)
	}
	if _, err := os.Stat(requestPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("failed request remained queued: %v", err)
	}
}
