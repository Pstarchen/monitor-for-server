package collector

import (
	"context"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"xingchen-monitor/agent/internal/model"
)

func TestDockerCPUPercent(t *testing.T) {
	var stats dockerContainerStats
	stats.PreCPUStats.CPUUsage.TotalUsage = 1_000
	stats.CPUStats.CPUUsage.TotalUsage = 3_000
	stats.PreCPUStats.SystemCPUUsage = 10_000
	stats.CPUStats.SystemCPUUsage = 20_000
	stats.CPUStats.OnlineCPUs = 4
	if got, want := dockerCPUPercent(stats), 80.0; got != want {
		t.Fatalf("docker cpu percent = %v, want %v", got, want)
	}
}

func TestDockerMemoryPercentSubtractsCache(t *testing.T) {
	stats := dockerContainerStats{}
	stats.MemoryStats.Usage = 900
	stats.MemoryStats.Limit = 1_000
	stats.MemoryStats.Stats = map[string]uint64{"cache": 100}
	usage, limit, percent := dockerMemoryPercent(stats)
	if usage != 800 || limit != 1_000 || percent != 80 {
		t.Fatalf("docker memory = %d/%d %.1f, want 800/1000 80", usage, limit, percent)
	}
}

func TestDockerNetworkTotals(t *testing.T) {
	received, sent := dockerNetworkTotals(map[string]dockerNetStats{
		"eth0": {RxBytes: 10, TxBytes: 20},
		"eth1": {RxBytes: 3, TxBytes: 7},
	})
	if received != 13 || sent != 27 {
		t.Fatalf("docker network totals = %d/%d, want 13/27", received, sent)
	}
}

func TestContainerModelKeepsStableFields(t *testing.T) {
	item := model.ContainerStats{ID: "abc", Name: "api", State: "running", CPUPercent: 12.5}
	if item.ID != "abc" || item.Name != "api" || item.State != "running" || item.CPUPercent != 12.5 {
		t.Fatalf("unexpected container model: %#v", item)
	}
}

func TestCollectContainersFromDockerSocket(t *testing.T) {
	socket := filepath.Join(t.TempDir(), "docker.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/v1.41/containers/json":
			_, _ = writer.Write([]byte(`[{"Id":"abc123456789","Names":["/api"],"Image":"example/api:latest","State":"running","Status":"Up 2 hours"}]`))
		case "/v1.41/containers/abc123456789/stats":
			_, _ = writer.Write([]byte(`{"cpu_stats":{"cpu_usage":{"total_usage":3000},"system_cpu_usage":20000,"online_cpus":4},"precpu_stats":{"cpu_usage":{"total_usage":1000},"system_cpu_usage":10000},"memory_stats":{"usage":900,"limit":1000,"stats":{"cache":100}},"networks":{"eth0":{"rx_bytes":13,"tx_bytes":27}},"restart_count":2}`))
		default:
			http.NotFound(writer, request)
		}
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Shutdown(context.Background()) })

	items := collectContainers(context.Background(), socket, "", false, maxContainerCount)
	if len(items) != 1 {
		t.Fatalf("containers = %#v, want one item", items)
	}
	item := items[0]
	if item.Name != "api" || item.CPUPercent != 80 || item.MemoryPercent != 80 || item.NetworkRxBytes != 13 || item.NetworkTxBytes != 27 || item.RestartCount != 2 {
		t.Fatalf("container = %#v, want populated Docker stats", item)
	}
}

func TestResolveDockerSocketFallsBackToHostRoot(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix socket paths are not portable on Windows")
	}
	for _, candidate := range []string{"/var/run/docker.sock", "/run/podman/podman.sock"} {
		if isDockerSocket(candidate) {
			t.Skipf("host runtime socket %s would take precedence", candidate)
		}
	}
	hostRoot := t.TempDir()
	socketPath := filepath.Join(hostRoot, "var", "run", "docker.sock")
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o755); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	if got := resolveDockerSocket(filepath.Join(hostRoot, "missing.sock"), hostRoot); got != socketPath {
		t.Fatalf("resolved socket = %q, want %q", got, socketPath)
	}
}
