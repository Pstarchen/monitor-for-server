package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestControllerUpdateCancellationAllowsParentAndChildRecovery(t *testing.T) {
	root := t.TempDir()
	ready := filepath.Join(root, "ready")
	parentRecovered := filepath.Join(root, "parent-recovered")
	childRecovered := filepath.Join(root, "child-recovered")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	script := `parent_recovered="$1"
child_recovered="$2"
ready="$3"
recover_update() {
  trap '' TERM
  wait "$child" || true
  printf 'restored\n' > "$parent_recovered"
  exit 0
}
trap recover_update TERM
bash -c 'trap '\''printf "restored\\n" > "$1"; exit 0'\'' TERM; printf ready > "$2"; while :; do sleep 0.05; done' bash "$child_recovered" "$ready" &
child=$!
wait "$child"
`
	command := updateControllerCommand(ctx, "-c", script, "bash", parentRecovered, childRecovered, ready)
	result := startControllerUpdateTestCommand(t, ctx, cancel, command, time.Second)
	waitForControllerUpdateTestFile(t, ready)
	cancel()
	if err := waitForControllerUpdateTestResult(t, result); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled update error = %v, want context.Canceled", err)
	}
	for _, path := range []string{parentRecovered, childRecovered} {
		if content, err := os.ReadFile(path); err != nil || !strings.Contains(string(content), "restored") {
			t.Fatalf("recovery marker %s = %q, %v", path, content, err)
		}
	}
}

func TestControllerUpdateCancellationKillsUnresponsiveProcessGroup(t *testing.T) {
	root := t.TempDir()
	ready := filepath.Join(root, "ready")
	heartbeats := filepath.Join(root, "heartbeats")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	script := `trap '' TERM
bash -c 'trap "" TERM; printf ready > "$1"; while :; do printf . >> "$2"; sleep 0.02; done' bash "$1" "$2" &
wait "$!"
`
	command := updateControllerCommand(ctx, "-c", script, "bash", ready, heartbeats)
	result := startControllerUpdateTestCommand(t, ctx, cancel, command, 100*time.Millisecond)
	waitForControllerUpdateTestFile(t, ready)
	started := time.Now()
	cancel()
	var exitError *exec.ExitError
	if err := waitForControllerUpdateTestResult(t, result); !errors.As(err, &exitError) {
		t.Fatalf("unresponsive update error = %v, want an exit error", err)
	}
	if time.Since(started) >= 2*time.Second {
		t.Fatal("unresponsive update did not stop within the configured recovery grace")
	}
	before, err := os.ReadFile(heartbeats)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	after, err := os.ReadFile(heartbeats)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Fatal("child process kept running after the update command returned")
	}
}

func TestControllerUpdateCompletionStopsCancellationWatcher(t *testing.T) {
	root := t.TempDir()
	finished := filepath.Join(root, "child-finished")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	command := updateControllerCommand(ctx, "-c", `bash -c 'sleep 0.3; printf finished > "$1"' bash "$1" >/dev/null 2>&1 &`, "bash", finished)
	if _, err := runControllerUpdateCommandWithGrace(ctx, command, 20*time.Millisecond); err != nil {
		t.Fatal(err)
	}
	cancel()
	waitForControllerUpdateTestFile(t, finished)
}

func TestControllerUpdateCancellationCleansChildrenAfterParentExits(t *testing.T) {
	root := t.TempDir()
	ready := filepath.Join(root, "ready")
	heartbeats := filepath.Join(root, "heartbeats")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	script := `trap 'exit 0' TERM
bash -c 'trap "" TERM; printf . >> "$2"; printf ready > "$1"; while :; do printf . >> "$2"; sleep 0.02; done' bash "$1" "$2" >/dev/null 2>&1 &
wait "$!"
`
	command := updateControllerCommand(ctx, "-c", script, "bash", ready, heartbeats)
	result := startControllerUpdateTestCommand(t, ctx, cancel, command, time.Second)
	waitForControllerUpdateTestFile(t, ready)
	cancel()
	if err := waitForControllerUpdateTestResult(t, result); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled parent error = %v, want context.Canceled", err)
	}
	before, err := os.ReadFile(heartbeats)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	after, err := os.ReadFile(heartbeats)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Fatal("redirected child survived after its canceled parent exited")
	}
}

func TestControllerUpdateCommandPreservesRollbackExitCodes(t *testing.T) {
	for _, code := range []string{"10", "11"} {
		command := updateControllerCommand(context.Background(), "-c", "exit "+code)
		_, err := runControllerUpdateCommandWithGrace(context.Background(), command, time.Second)
		var exitError *exec.ExitError
		if !errors.As(err, &exitError) || exitError.Error() != "exit status "+code {
			t.Fatalf("rollback exit %s returned %v", code, err)
		}
		if status, ok := exitError.Sys().(syscall.WaitStatus); !ok || !status.Exited() {
			t.Fatalf("rollback exit %s was not preserved as a normal process exit", code)
		}
	}
}

func startControllerUpdateTestCommand(t *testing.T, ctx context.Context, cancel context.CancelFunc, command *exec.Cmd, grace time.Duration) <-chan error {
	t.Helper()
	result := make(chan error, 1)
	completed := make(chan struct{})
	go func() {
		defer close(completed)
		_, err := runControllerUpdateCommandWithGrace(ctx, command, grace)
		result <- err
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-completed:
			return
		case <-time.After(2 * time.Second):
			_ = signalControllerUpdateGroup(command, syscall.SIGKILL)
		}
		select {
		case <-completed:
		case <-time.After(controllerUpdateOutputDrainTimeout + time.Second):
			t.Error("controller update test command did not clean up")
		}
	})
	return result
}

func waitForControllerUpdateTestFile(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if content, err := os.ReadFile(path); err == nil && len(content) > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", path)
}

func waitForControllerUpdateTestResult(t *testing.T, result <-chan error) error {
	t.Helper()
	select {
	case err := <-result:
		return err
	case <-time.After(3 * time.Second):
		t.Fatal("controller update command did not finish")
		return nil
	}
}
