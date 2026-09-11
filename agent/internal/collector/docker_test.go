package collector

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"testing"
	"time"

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

func TestDockerMemoryPercentSubtractsInactiveFile(t *testing.T) {
	stats := dockerContainerStats{}
	stats.MemoryStats.Usage = 900
	stats.MemoryStats.Limit = 1_000
	stats.MemoryStats.Stats = map[string]uint64{"cache": 400, "total_inactive_file": 100}
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
	var cycle atomic.Int64
	cycle.Store(1)
	server := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/v1.41/containers/json":
			_, _ = writer.Write([]byte(`[{"Id":"abc123456789","Names":["/api"],"Image":"example/api:latest","State":"running","Status":"Up 2 hours"}]`))
		case "/v1.41/containers/abc123456789/json":
			_, _ = writer.Write([]byte(`{"RestartCount":2,"State":{"StartedAt":"2026-09-01T00:00:00Z"}}`))
		case "/v1.41/containers/abc123456789/stats":
			if request.URL.Query().Get("one-shot") != "true" {
				t.Error("stats must request one-shot")
			}
			n := cycle.Load()
			_, _ = fmt.Fprintf(writer, `{"read":"2026-09-11T00:00:0%dZ","cpu_stats":{"cpu_usage":{"total_usage":%d},"system_cpu_usage":%d,"online_cpus":4},"memory_stats":{"usage":900,"limit":1000,"stats":{"cache":400,"total_inactive_file":100}},"networks":{"eth0":{"rx_bytes":13,"tx_bytes":27}}}`, n, 1000+(n-1)*2000, n*10000)
		default:
			http.NotFound(writer, request)
		}
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Shutdown(context.Background()) })

	collector := New(Options{})
	items := collector.collectContainers(context.Background(), socket, "", false, maxContainerCount)
	if len(items) != 1 || !items[0].StatsAvailable || items[0].CPUSampled {
		t.Fatalf("first sample must contain memory but no CPU interval: %+v", items)
	}
	cycle.Store(2)
	items = collector.collectContainers(context.Background(), socket, "", false, maxContainerCount)
	if len(items) != 1 {
		t.Fatalf("containers = %#v, want one item", items)
	}
	item := items[0]
	if !item.StatsAvailable || !item.CPUSampled || !item.RestartCountAvailable || item.Name != "api" || item.CPUPercent != 80 || item.MemoryPercent != 80 || item.NetworkRxBytes != 13 || item.NetworkTxBytes != 27 || item.RestartCount != 2 {
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

func TestDockerMemoryMatchesBothCgroupVersions(t *testing.T) {
	for _, tt := range []struct {
		name     string
		counters map[string]uint64
		want     uint64
	}{
		{"v1", map[string]uint64{"cache": 600, "total_inactive_file": 100, "inactive_file": 200}, 800},
		{"v2", map[string]uint64{"cache": 600, "inactive_file": 200}, 700},
		{"no inactive counter", map[string]uint64{"cache": 600}, 900},
		{"invalid inactive", map[string]uint64{"inactive_file": 1000}, 900},
	} {
		t.Run(tt.name, func(t *testing.T) {
			stats := dockerContainerStats{}
			stats.MemoryStats = dockerMemoryStats{Usage: 900, Limit: 1000, Stats: tt.counters}
			got, _, _ := dockerMemoryPercent(stats)
			if got != tt.want {
				t.Fatalf("usage=%d want=%d", got, tt.want)
			}
		})
	}
}

func TestDockerCPUUsesPerCoreFallback(t *testing.T) {
	var stats dockerContainerStats
	stats.CPUStats.CPUUsage.TotalUsage = 200
	stats.CPUStats.SystemCPUUsage = 1000
	stats.CPUStats.CPUUsage.PerCPUUsage = []uint64{100, 100, 0, 0}
	if got := dockerCPUPercent(stats); got != 80 {
		t.Fatalf("CPU=%v, want 80", got)
	}
	stats.PreCPUStats = stats.CPUStats
	if got := dockerCPUPercent(stats); got != 0 {
		t.Fatalf("duplicate stats CPU=%v", got)
	}
}

func TestDockerSlowContainerDoesNotBlockOtherContainersOrInventZero(t *testing.T) {
	var inFlight, peak atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := inFlight.Add(1)
		defer inFlight.Add(-1)
		for old := peak.Load(); n > old; old = peak.Load() {
			if peak.CompareAndSwap(old, n) {
				break
			}
		}
		switch r.URL.Path {
		case "/v1.41/containers/json":
			fmt.Fprint(w, `[{"Id":"slow","Names":["/a"],"State":"running"},{"Id":"fast","Names":["/b"],"State":"running"}]`)
		case "/v1.41/containers/slow/json":
			<-r.Context().Done()
		case "/v1.41/containers/fast/json":
			fmt.Fprint(w, `{"RestartCount":3,"State":{"StartedAt":"2026-09-01T00:00:00Z"}}`)
		case "/v1.41/containers/fast/stats":
			fmt.Fprint(w, `{"read":"2026-09-11T00:00:01Z","memory_stats":{"usage":100,"limit":1000}}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	client := server.Client()
	client.Transport = rewriteDockerTransport{base: client.Transport, url: server.URL}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	items := New(Options{}).collectDockerContainers(ctx, client, 100)
	if len(items) != 2 || items[0].StatsAvailable || items[0].RestartCountAvailable || !items[1].StatsAvailable || items[1].MemoryUsageBytes != 100 || items[1].RestartCount != 3 {
		t.Fatalf("container availability=%+v", items)
	}
	if peak.Load() > 4 {
		t.Fatalf("unbounded concurrency %d", peak.Load())
	}
}

func TestDockerSamplingRejectsCrossRestartAndDuplicateSnapshots(t *testing.T) {
	var cycle, statsRead atomic.Int64
	type snapshot struct {
		read        string
		started     string
		cpu, system uint64
		cores       int
		statsOK     bool
		wantStats   bool
		wantCPU     bool
		wantPercent float64
	}
	snapshots := []snapshot{
		{read: "2026-09-11T00:00:01Z", started: "2026-09-01T00:00:00Z", cpu: 1000, system: 10000, cores: 4, statsOK: true, wantStats: true},
		{read: "2026-09-11T00:00:01Z", started: "2026-09-01T00:00:00Z", cpu: 1000, system: 10000, cores: 4, statsOK: true, wantStats: true},
		{read: "2026-09-11T00:00:03Z", started: "2026-09-01T00:00:00Z", cpu: 3000, system: 20000, cores: 4, statsOK: true, wantStats: true, wantCPU: true, wantPercent: 80},
		// A restart occurs after stats but before inspect. These old-instance
		// counters are larger, so a simple cumulative-counter reset check fails.
		{read: "2026-09-11T00:00:04Z", started: "2026-09-11T00:00:04.5Z", cpu: 5000, system: 30000, cores: 4, statsOK: true},
		{read: "2026-09-11T00:00:05Z", started: "2026-09-11T00:00:04.5Z", cpu: 100, system: 40000, cores: 4, statsOK: true, wantStats: true},
		{read: "2026-09-11T00:00:06Z", started: "2026-09-11T00:00:04.5Z", cpu: 2100, system: 50000, cores: 4, statsOK: true, wantStats: true, wantCPU: true, wantPercent: 80},
		{read: "2026-09-11T00:00:07Z", started: "2026-09-11T00:00:04.5Z", cpu: 10, system: 60000, cores: 4, statsOK: true, wantStats: true},
		{read: "2026-09-11T00:00:08Z", started: "2026-09-11T00:00:04.5Z", cpu: 20, system: 70000, cores: 8, statsOK: true, wantStats: true},
		{read: "2026-09-11T00:00:09Z", started: "2026-09-11T00:00:04.5Z", cpu: 1020, system: 80000, cores: 8, statsOK: true, wantStats: true, wantCPU: true, wantPercent: 80},
		{started: "2026-09-11T00:00:04.5Z"},
		{read: "2026-09-11T00:00:11Z", started: "2026-09-11T00:00:04.5Z", cpu: 3020, system: 100000, cores: 8, statsOK: true, wantStats: true},
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		index := cycle.Load()
		current := snapshots[index]
		switch r.URL.Path {
		case "/v1.41/containers/json":
			fmt.Fprint(w, `[{"Id":"api","Names":["/api"],"State":"running"}]`)
		case "/v1.41/containers/api/stats":
			statsRead.Store(index + 1)
			if !current.statsOK {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			fmt.Fprintf(w, `{"read":%q,"cpu_stats":{"cpu_usage":{"total_usage":%d},"system_cpu_usage":%d,"online_cpus":%d},"memory_stats":{"usage":100,"limit":1000}}`, current.read, current.cpu, current.system, current.cores)
		case "/v1.41/containers/api/json":
			if statsRead.Load() != index+1 {
				t.Error("instance metadata must be checked after reading its counters")
			}
			fmt.Fprintf(w, `{"RestartCount":0,"State":{"StartedAt":%q}}`, current.started)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	client := server.Client()
	client.Transport = rewriteDockerTransport{base: client.Transport, url: server.URL}
	collector := New(Options{})
	for index, expected := range snapshots {
		cycle.Store(int64(index))
		items := collector.collectDockerContainers(context.Background(), client, 100)
		if len(items) != 1 {
			t.Fatalf("cycle %d: items=%+v", index, items)
		}
		item := items[0]
		if item.StatsAvailable != expected.wantStats || item.CPUSampled != expected.wantCPU || item.CPUPercent != expected.wantPercent {
			t.Fatalf("cycle %d: got stats=%v sampled=%v CPU=%v, want %v/%v/%v", index, item.StatsAvailable, item.CPUSampled, item.CPUPercent, expected.wantStats, expected.wantCPU, expected.wantPercent)
		}
		if !item.RestartCountAvailable || item.RestartCount != 0 {
			t.Fatalf("explicit zero restart count must remain available: %+v", item)
		}
	}
}

func TestDockerMissingRestartCountIsUnavailable(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1.41/containers/json":
			fmt.Fprint(w, `[{"Id":"api","Names":["/api"],"State":"exited"}]`)
		case "/v1.41/containers/api/json":
			fmt.Fprint(w, `{"State":{"StartedAt":"2026-09-01T00:00:00Z"}}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	client := server.Client()
	client.Transport = rewriteDockerTransport{base: client.Transport, url: server.URL}
	items := New(Options{}).collectDockerContainers(context.Background(), client, 100)
	if len(items) != 1 || items[0].RestartCountAvailable || items[0].StatsAvailable {
		t.Fatalf("missing fields/stopped container must not become real zero measurements: %+v", items)
	}
}

type rewriteDockerTransport struct {
	base http.RoundTripper
	url  string
}

func (t rewriteDockerTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	clone := r.Clone(r.Context())
	target, _ := http.NewRequest(http.MethodGet, t.url, nil)
	clone.URL.Scheme = target.URL.Scheme
	clone.URL.Host = target.URL.Host
	return t.base.RoundTrip(clone)
}
