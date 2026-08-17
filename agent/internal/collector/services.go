package collector

import (
	"context"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"guanlan-monitor/agent/internal/model"
)

func collectServices(ctx context.Context, names []string) []model.ServiceStatus {
	result := make([]model.ServiceStatus, 0, len(names))
	for _, name := range names {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		result = append(result, model.ServiceStatus{Name: name, Status: serviceStatus(ctx, name)})
	}
	return result
}

func serviceStatus(parent context.Context, name string) string {
	ctx, cancel := context.WithTimeout(parent, 2*time.Second)
	defer cancel()

	var command *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		command = exec.CommandContext(ctx, "sc.exe", "query", name)
	case "linux":
		command = exec.CommandContext(ctx, "systemctl", "is-active", name)
	default:
		return "unsupported"
	}
	output, err := command.CombinedOutput()
	text := strings.ToLower(string(output))
	if err == nil && (strings.Contains(text, "running") || strings.TrimSpace(text) == "active") {
		return "running"
	}
	if errorsLikeMissing(text) {
		return "not_found"
	}
	return "stopped"
}

func errorsLikeMissing(output string) bool {
	return strings.Contains(output, "not-found") || strings.Contains(output, "does not exist") || strings.Contains(output, "1060")
}
