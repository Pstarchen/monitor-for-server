package collector

import (
	"context"
	"os/exec"
	"path"
	"runtime"
	"strings"
	"time"

	"xingchen-monitor/agent/internal/model"
)

func collectServices(ctx context.Context, names []string, hostRoot string) []model.ServiceStatus {
	result := make([]model.ServiceStatus, 0, len(names))
	for _, name := range names {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		result = append(result, model.ServiceStatus{Name: name, Status: serviceStatus(ctx, name, hostRoot)})
	}
	return result
}

func serviceStatus(parent context.Context, name, hostRoot string) string {
	ctx, cancel := context.WithTimeout(parent, 2*time.Second)
	defer cancel()

	command := serviceCommand(ctx, name, hostRoot)
	if command == nil {
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

func serviceCommand(ctx context.Context, name, hostRoot string) *exec.Cmd {
	return serviceCommandForOS(ctx, runtime.GOOS, name, hostRoot)
}

func serviceCommandForOS(ctx context.Context, goos, name, hostRoot string) *exec.Cmd {
	switch goos {
	case "windows":
		return exec.CommandContext(ctx, "sc.exe", "query", name)
	case "linux":
		if strings.TrimSpace(hostRoot) == "" {
			return exec.CommandContext(ctx, "systemctl", "is-active", "--", name)
		}
		return exec.CommandContext(ctx, "chroot", path.Clean(hostRoot), "systemctl", "is-active", "--", name)
	default:
		return nil
	}
}

func errorsLikeMissing(output string) bool {
	return strings.Contains(output, "not-found") || strings.Contains(output, "does not exist") || strings.Contains(output, "1060")
}
