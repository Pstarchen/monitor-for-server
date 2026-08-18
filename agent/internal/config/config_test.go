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

func TestLoadAppliesLightweightCollectionOptions(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.json")
	body := []byte(`{
        "server_url":"https://monitor.example.com",
        "device_id":"device",
        "agent_key":"secret",
        "skip_process_collection":true,
        "skip_connection_count":true,
        "disk_mountpoints":["/", " /data ", "/data", ""]
    }`)
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load([]string{"-config", path})
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.SkipProcesses || !cfg.SkipConnectionCount {
		t.Fatal("expected lightweight collection options to be enabled")
	}
	if len(cfg.DiskMountpoints) != 2 || cfg.DiskMountpoints[1] != "/data" {
		t.Fatalf("unexpected disk allowlist: %#v", cfg.DiskMountpoints)
	}
}

func TestLoadAcceptsUtf8BomAndSixtySecondInterval(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.json")
	body := append([]byte{0xEF, 0xBB, 0xBF}, []byte(`{"server_url":"https://monitor.example.com","device_id":"device","agent_key":"secret","interval":"60s"}`)...)
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load([]string{"-config", path})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Interval.Seconds() != 60 {
		t.Fatalf("unexpected interval: %s", cfg.Interval)
	}
}
