package collector

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestReportedHostnameUsesHostFileWithoutChangingNativeIdentity(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Linux host-root installation")
	}
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "etc"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "etc", "hostname"), []byte("host-server\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if got := reportedHostname(root, "container-id"); got != "host-server" {
		t.Fatalf("hostname=%q", got)
	}
	if got := reportedHostname("", "native-server"); got != "native-server" {
		t.Fatalf("native hostname=%q", got)
	}
	if got := reportedHostname(t.TempDir(), "fallback"); got != "fallback" {
		t.Fatalf("fallback=%q", got)
	}
}
