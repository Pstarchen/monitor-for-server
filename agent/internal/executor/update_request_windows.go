//go:build windows

package executor

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func triggerAgentUpdate(launcherPath string) error {
	if launcherPath == "" || !filepath.IsAbs(launcherPath) {
		return errors.New("update launcher unavailable")
	}
	windowsRoot := os.Getenv("SystemRoot")
	if windowsRoot == "" {
		windowsRoot = `C:\Windows`
	}
	powerShell := filepath.Join(windowsRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	command := exec.Command(powerShell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", launcherPath)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP | 0x00000008}
	if err := command.Start(); err != nil {
		return err
	}
	return command.Process.Release()
}
