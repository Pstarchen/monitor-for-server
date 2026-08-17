package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadRejectsRemotePlainHTTP(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.json")
	body := []byte(`{"server_url":"http://example.com","device_id":"device","agent_key":"secret"}`)
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load([]string{"-config", path}); err == nil {
		t.Fatal("expected insecure remote URL to be rejected")
	}
}

func TestLoadAllowsLocalDevelopmentHTTP(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.json")
	body := []byte(`{"server_url":"http://127.0.0.1:8080","device_id":"device","agent_key":"secret"}`)
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load([]string{"-config", path})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Interval.Seconds() != 3 {
		t.Fatalf("unexpected interval: %s", cfg.Interval)
	}
}
