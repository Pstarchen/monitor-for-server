package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"syscall"
	"time"
)

func updateControllerCommand(ctx context.Context, updaterPath string, arguments ...string) *exec.Cmd {
	command := exec.CommandContext(ctx, "bash", append([]string{updaterPath}, arguments...)...)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		return signalControllerUpdateGroup(command, syscall.SIGTERM)
	}
	command.WaitDelay = controllerUpdateRecoveryGracePeriod + controllerUpdateOutputDrainTimeout
	return command
}

func signalControllerUpdateGroup(command *exec.Cmd, signal syscall.Signal) error {
	if command.Process == nil {
		return os.ErrProcessDone
	}
	err := syscall.Kill(-command.Process.Pid, signal)
	if errors.Is(err, syscall.ESRCH) {
		return os.ErrProcessDone
	}
	return err
}

func runControllerUpdateCommand(ctx context.Context, command *exec.Cmd) ([]byte, error) {
	return runControllerUpdateCommandWithGrace(ctx, command, controllerUpdateRecoveryGracePeriod)
}

func runControllerUpdateCommandWithGrace(ctx context.Context, command *exec.Cmd, grace time.Duration) ([]byte, error) {
	if command.Stdout != nil || command.Stderr != nil {
		return nil, errors.New("controller update command output is already configured")
	}
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = &output
	command.WaitDelay = grace + controllerUpdateOutputDrainTimeout
	if err := command.Start(); err != nil {
		return nil, err
	}
	finished := make(chan struct{})
	watcherDone := make(chan struct{})
	go func() {
		defer close(watcherDone)
		select {
		case <-finished:
			return
		case <-ctx.Done():
		}
		timer := time.NewTimer(grace)
		defer timer.Stop()
		select {
		case <-finished:
			return
		case <-timer.C:
		}
		select {
		case <-finished:
			return
		default:
			_ = signalControllerUpdateGroup(command, syscall.SIGKILL)
		}
	}()
	err := command.Wait()
	close(finished)
	// Join the watcher before returning so no delayed signal can outlive this command.
	<-watcherDone
	if ctx.Err() != nil {
		// A canceled parent can exit before children that redirected their output.
		_ = signalControllerUpdateGroup(command, syscall.SIGKILL)
		if err == nil {
			err = ctx.Err()
		}
	}
	return output.Bytes(), err
}
