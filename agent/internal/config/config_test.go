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

func TestLoadRejectsNonOriginServerURL(t *testing.T) {
	for _, serverURL := range []string{
		"ftp://monitor.example.com",
		"https://user:password@monitor.example.com",
		"https://monitor.example.com/monitor",
		"https://monitor.example.com?token=secret",
	} {
		t.Run(serverURL, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "agent.json")
			body := []byte(`{"server_url":"` + serverURL + `","device_id":"device","agent_key":"secret"}`)
			if err := os.WriteFile(path, body, 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := Load([]string{"-config", path}); err == nil {
				t.Fatal("expected invalid server URL to be rejected")
			}
		})
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
	if cfg.ProcessCollectionLimit != 12 || cfg.PortCollectionLimit != 512 || cfg.ContainerCollectionLimit != 100 {
		t.Fatalf("unexpected collection limits: %+v", cfg)
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
		"collect_all_processes":true,
		"process_collection_limit":64,
		"skip_connection_count":true,
		"skip_port_collection":true,
		"port_collection_limit":128,
		"skip_container_collection":true,
		"container_collection_limit":20,
		"disk_mountpoints":["/", " /data ", "/data", ""],
		"monitored_processes":[" java ", "", "postgres"],
		"host_root":" /host ",
		"docker_socket":" /host/var/run/docker.sock "
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
	if !cfg.CollectAllProcesses || cfg.ProcessCollectionLimit != 64 || !cfg.SkipPortCollection || cfg.PortCollectionLimit != 128 || !cfg.SkipContainerCollection || cfg.ContainerCollectionLimit != 20 {
		t.Fatalf("unexpected extended collection options: %+v", cfg)
	}
	if len(cfg.DiskMountpoints) != 2 || cfg.DiskMountpoints[1] != "/data" {
		t.Fatalf("unexpected disk allowlist: %#v", cfg.DiskMountpoints)
	}
	if cfg.HostRoot != "/host" {
		t.Fatalf("unexpected host root: %q", cfg.HostRoot)
	}
	if len(cfg.MonitoredProcesses) != 2 || cfg.MonitoredProcesses[0] != "java" || cfg.MonitoredProcesses[1] != "postgres" {
		t.Fatalf("unexpected monitored processes: %#v", cfg.MonitoredProcesses)
	}
	if cfg.DockerSocket != "/host/var/run/docker.sock" {
		t.Fatalf("unexpected docker socket: %q", cfg.DockerSocket)
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

func TestCommandExecutionIsOptIn(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.json")
	body := []byte(`{"server_url":"https://monitor.example.com","device_id":"device","agent_key":"secret"}`)
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load([]string{"-config", path})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AllowCommandExecution {
		t.Fatal("command execution must be disabled by default")
	}
	if cfg.CommandPollInterval.Seconds() != 1 || cfg.MaxCommandOutputBytes != 65536 {
		t.Fatalf("unexpected command defaults: %+v", cfg)
	}
}

func TestLoadNormalizesCustomMetrics(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.json")
	body := []byte(`{"server_url":"https://monitor.example.com","device_id":"device","agent_key":"secret","custom_metrics":[{"name":" queue ","command":"printf","args":["42"],"kind":"number"},{"name":"release","command":"release-name","kind":"text"}]}`)
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load([]string{"-config", path})
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.CustomMetrics) != 2 || cfg.CustomMetrics[0].Name != "queue" || cfg.CustomMetrics[0].Kind != "number" || cfg.CustomMetrics[1].Kind != "text" {
		t.Fatalf("unexpected custom metrics: %#v", cfg.CustomMetrics)
	}
}

func TestLoadRejectsUnsafeResourceLimits(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.json")
	body := []byte(`{"server_url":"https://monitor.example.com","device_id":"device","agent_key":"secret","request_timeout":"3m","max_buffered_reports":100001}`)
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load([]string{"-config", path}); err == nil {
		t.Fatal("expected unsafe resource limits to be rejected")
	}
}

func TestEnvCompatPrefersXingchenNamespace(t *testing.T) {
	t.Setenv("GUANLAN_AGENT_CONFIG", "legacy.json")
	t.Setenv("XINGCHEN_AGENT_CONFIG", "xingchen.json")
	if got := envCompat("XINGCHEN_AGENT_CONFIG", "GUANLAN_AGENT_CONFIG", "default.json"); got != "xingchen.json" {
		t.Fatalf("envCompat() = %q, want XINGCHEN value", got)
	}
	t.Setenv("XINGCHEN_AGENT_CONFIG", "")
	if got := envCompat("XINGCHEN_AGENT_CONFIG", "GUANLAN_AGENT_CONFIG", "default.json"); got != "legacy.json" {
		t.Fatalf("envCompat() = %q, want legacy fallback", got)
	}
}
