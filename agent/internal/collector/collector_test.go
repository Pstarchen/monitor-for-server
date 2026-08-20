package collector

import (
	"path/filepath"
	"runtime"
	"testing"
)

func TestAllowedMountpoint(t *testing.T) {
	if !allowedMountpoint("/data", nil) {
		t.Fatal("empty allowlist should include every mountpoint")
	}
	if !allowedMountpoint("/data", []string{"/", "/data"}) {
		t.Fatal("listed mountpoint should be included")
	}
	if allowedMountpoint("/boot", []string{"/", "/data"}) {
		t.Fatal("unlisted mountpoint should be excluded")
	}
}

func TestHostPath(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("host-root bind mounts are only used by the Linux controller Agent")
	}
	if got := hostPath("/host", "/"); got != filepath.Clean("/host") {
		t.Fatalf("host root path = %q", got)
	}
	if got := hostPath("/host", "/data/metrics"); got != filepath.Join(filepath.Clean("/host"), "data", "metrics") {
		t.Fatalf("host mount path = %q", got)
	}
	if got := hostPath("/host", "relative"); got != "" {
		t.Fatalf("relative mount path = %q, want empty", got)
	}
}
