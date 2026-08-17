package collector

import "testing"

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
