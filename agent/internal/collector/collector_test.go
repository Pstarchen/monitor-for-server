package collector

import (
	"context"
	"path/filepath"
	"runtime"
	"testing"

	netstat "github.com/shirou/gopsutil/v4/net"
)

func TestNetworkCountersAggregateAllInterfaces(t *testing.T) {
	counters := []netstat.IOCountersStat{
		{BytesSent: 100, BytesRecv: 200},
		{BytesSent: 30, BytesRecv: 40},
	}
	gotSent, gotRecv := aggregateNetworkCounters(counters)
	if gotSent != 130 || gotRecv != 240 {
		t.Fatalf("aggregated network counters = %d/%d, want 130/240", gotSent, gotRecv)
	}
}

func TestListeningPortsFiltersAndSorts(t *testing.T) {
	ports := listeningPorts([]netstat.ConnectionStat{
		{Type: 1, Status: "ESTABLISHED", Laddr: netstat.Addr{IP: "127.0.0.1", Port: 9000}, Pid: 8},
		{Type: 1, Status: "LISTEN", Laddr: netstat.Addr{IP: "0.0.0.0", Port: 443}, Pid: 2},
		{Type: 2, Laddr: netstat.Addr{IP: "0.0.0.0", Port: 53}, Pid: 3},
		{Type: 1, Status: "LISTEN", Laddr: netstat.Addr{IP: "0.0.0.0", Port: 443}, Pid: 2},
	}, 512)
	if len(ports) != 2 {
		t.Fatalf("listening ports = %#v, want two unique listeners", ports)
	}
	if ports[0].Port != 53 || ports[0].Protocol != "UDP" || ports[1].Port != 443 || ports[1].Protocol != "TCP" {
		t.Fatalf("listening ports = %#v, want UDP 53 then TCP 443", ports)
	}
}

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

func TestServiceCommandUsesHostRoot(t *testing.T) {
	command := serviceCommandForOS(context.Background(), "linux", "nginx", "/host")
	want := []string{"chroot", "/host", "systemctl", "is-active", "--", "nginx"}
	if len(command.Args) != len(want) {
		t.Fatalf("service command args = %q, want %q", command.Args, want)
	}
	for index := range want {
		if filepath.Base(command.Args[index]) != filepath.Base(want[index]) {
			t.Fatalf("service command args = %q, want %q", command.Args, want)
		}
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

func TestMatchesMonitoredProcess(t *testing.T) {
	if !matchesMonitoredProcess("java", []string{" nginx ", "JAVA"}) {
		t.Fatal("configured process name should match case-insensitively")
	}
	if matchesMonitoredProcess("postgres", []string{"redis"}) {
		t.Fatal("unconfigured process should not match")
	}
}

func TestNewCapsMonitoredProcesses(t *testing.T) {
	names := make([]string, maxMonitoredProcesses+5)
	for index := range names {
		names[index] = "process"
	}
	collector := New(Options{MonitoredProcesses: names})
	if len(collector.options.MonitoredProcesses) != maxMonitoredProcesses {
		t.Fatalf("monitored process count = %d, want %d", len(collector.options.MonitoredProcesses), maxMonitoredProcesses)
	}
}
