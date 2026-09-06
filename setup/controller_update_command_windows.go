package main

import (
	"context"
	"os/exec"
)

func updateControllerCommand(ctx context.Context, updaterPath string, arguments ...string) *exec.Cmd {
	command := exec.CommandContext(ctx, "bash", append([]string{updaterPath}, arguments...)...)
	command.WaitDelay = controllerUpdateRecoveryGracePeriod + controllerUpdateOutputDrainTimeout
	return command
}

func runControllerUpdateCommand(_ context.Context, command *exec.Cmd) ([]byte, error) {
	return command.CombinedOutput()
}
