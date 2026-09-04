//go:build !windows

package executor

func triggerAgentUpdate(_ string) error {
	// systemd.path watches the request file and invokes the root-owned handler.
	return nil
}
