package collector

import (
	"os"
	"strings"
)

func reportedHostname(hostRoot, fallback string) string {
	if strings.TrimSpace(hostRoot) == "" {
		return fallback
	}
	// proc/sys/kernel/hostname resolves the reader's UTS namespace even when
	// proc is bind-mounted from the host, so it can still name the container.
	if raw, err := os.ReadFile(hostPath(hostRoot, "/etc/hostname")); err == nil {
		if hostname := strings.TrimSpace(string(raw)); hostname != "" {
			return hostname
		}
	}
	return fallback
}
