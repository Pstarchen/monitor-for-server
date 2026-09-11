package collector

import (
	"reflect"
	"testing"
	"time"

	netstat "github.com/shirou/gopsutil/v4/net"
)

func TestNetworkDefaultExcludesDuplicateContainerAndTunnelTraffic(t *testing.T) {
	counters := []netstat.IOCountersStat{
		{Name: "eth0", BytesSent: 100, BytesRecv: 200},
		{Name: "lo", BytesSent: 1000, BytesRecv: 1000},
		{Name: "docker0", BytesSent: 300, BytesRecv: 400},
		{Name: "veth123", BytesSent: 400, BytesRecv: 300},
		{Name: "br-a1b2", BytesSent: 500, BytesRecv: 600},
		{Name: "wg0", BytesSent: 700, BytesRecv: 800},
		{Name: "tun0", BytesSent: 900, BytesRecv: 1000},
	}
	selected := selectNetworkCounters(counters, nil, nil)
	if len(selected) != 1 || selected[0].Name != "eth0" || selected[0].BytesSent != 100 || selected[0].BytesRecv != 200 {
		t.Fatalf("selected counters = %#v, want only uplink traffic", selected)
	}
}

func TestNetworkExplicitAllowlistCanMonitorVPNAndReportsMissingNames(t *testing.T) {
	counters := []netstat.IOCountersStat{{Name: "eth0"}, {Name: "wg0"}, {Name: "lo"}}
	selected := selectNetworkCounters(counters, []string{" wg0 ", "lo", "wg0"}, nil)
	if len(selected) != 2 || selected[0].Name != "lo" || selected[1].Name != "wg0" {
		t.Fatalf("explicit interfaces = %#v, want lo and wg0 once", selected)
	}
	selected = selectNetworkCounters(counters, []string{"missing0"}, nil)
	result, _ := networkStatsFromSamples(selected, nil, nil, time.Now())
	if result.Available || result.RatesAvailable || len(result.SampledInterfaces) != 0 {
		t.Fatalf("missing allowlist must not silently fall back to all NICs: %#v", result)
	}
}

func TestNetworkBondAndBridgeTopologyAvoidsDoubleCounting(t *testing.T) {
	counters := []netstat.IOCountersStat{
		{Name: "eth0"}, {Name: "eth1"}, {Name: "uplink"}, {Name: "lan"}, {Name: "uplink.100"}, {Name: "vpn"},
	}
	metadata := map[string]networkInterfaceInfo{
		"eth0":       {master: "uplink"},
		"eth1":       {master: "uplink"},
		"uplink":     {bond: true, master: "lan", lower: "eth0"},
		"lan":        {bridge: true},
		"uplink.100": {lower: "uplink"},
		"vpn":        {tunnel: true},
	}
	selected := selectNetworkCounters(counters, nil, metadata)
	if len(selected) != 1 || selected[0].Name != "uplink" {
		t.Fatalf("topology selected = %#v, want bond master only", selected)
	}
	// Bridge ports remain useful; only their bridge and virtual container
	// ports duplicate the external traffic seen by the physical interface.
	metadata = map[string]networkInterfaceInfo{"eth0": {master: "lan"}, "lan": {bridge: true}}
	selected = selectNetworkCounters([]netstat.IOCountersStat{{Name: "eth0"}, {Name: "lan"}, {Name: "veth1"}}, nil, metadata)
	if len(selected) != 1 || selected[0].Name != "eth0" {
		t.Fatalf("bridge selected = %#v, want physical bridge port", selected)
	}
}

func TestNetworkKeepsVirtualEth0WhosePeerIsOutsideNamespace(t *testing.T) {
	metadata := map[string]networkInterfaceInfo{
		"eth0": {index: 2, linkIndex: 45},
		"lo":   {index: 1, loopback: true},
	}
	selected := selectNetworkCounters([]netstat.IOCountersStat{{Name: "eth0"}, {Name: "lo"}}, nil, metadata)
	if len(selected) != 1 || selected[0].Name != "eth0" {
		t.Fatalf("virtual eth0 must remain measurable: %#v", selected)
	}
}

func TestNetworkRatesUseEachInterfacesCounterInterval(t *testing.T) {
	start := time.Unix(1000, 0)
	counters := []netstat.IOCountersStat{{Name: "eth0", BytesSent: 500, BytesRecv: 700}, {Name: "eth1", BytesSent: 1100, BytesRecv: 1300}}
	metadata := map[string]networkInterfaceInfo{"eth0": {identity: "2"}, "eth1": {identity: "3"}}
	previous := map[string]networkSample{
		"eth0": {at: start, sent: 100, received: 100, identity: "2"},
		"eth1": {at: start.Add(2 * time.Second), sent: 900, received: 900, identity: "3"},
	}
	result, next := networkStatsFromSamples(counters, metadata, previous, start.Add(4*time.Second))
	if !result.Available || !result.RatesAvailable || result.BytesSentPerSec != 200 || result.BytesRecvPerSec != 350 || result.BytesSent != 1600 || result.BytesRecv != 2000 {
		t.Fatalf("network result = %#v, want measured per-interface rates 200/350", result)
	}
	if !reflect.DeepEqual(result.SampledInterfaces, []string{"eth0", "eth1"}) || len(next) != 2 {
		t.Fatalf("sample identities = %#v / %#v", result.SampledInterfaces, next)
	}
}

func TestNetworkInterfaceChangesDoNotCauseRateSpikes(t *testing.T) {
	start := time.Unix(1000, 0)
	metadata := map[string]networkInterfaceInfo{"eth0": {identity: "2"}, "eth1": {identity: "3"}}
	first, previous := networkStatsFromSamples([]netstat.IOCountersStat{{Name: "eth0", BytesSent: 100, BytesRecv: 200}}, metadata, nil, start)
	if !first.Available || first.RatesAvailable || first.BytesSentPerSec != 0 {
		t.Fatalf("first sample = %#v, want totals with unavailable rates", first)
	}
	added, previous := networkStatsFromSamples([]netstat.IOCountersStat{{Name: "eth0", BytesSent: 200, BytesRecv: 400}, {Name: "eth1", BytesSent: 1_000_000, BytesRecv: 2_000_000}}, metadata, previous, start.Add(time.Second))
	if added.RatesAvailable || added.BytesSentPerSec != 0 || added.BytesRecvPerSec != 0 {
		t.Fatalf("new NIC cumulative counters caused a spike: %#v", added)
	}
	removed, previous := networkStatsFromSamples([]netstat.IOCountersStat{{Name: "eth0", BytesSent: 300, BytesRecv: 600}}, metadata, previous, start.Add(2*time.Second))
	if !removed.RatesAvailable || removed.BytesSentPerSec != 100 || removed.BytesRecvPerSec != 200 || len(previous) != 1 {
		t.Fatalf("removed interface corrupted the remaining NIC rate: %#v", removed)
	}
	recreatedMetadata := map[string]networkInterfaceInfo{"eth0": {identity: "9"}}
	recreated, _ := networkStatsFromSamples([]netstat.IOCountersStat{{Name: "eth0", BytesSent: 5_000_000, BytesRecv: 6_000_000}}, recreatedMetadata, previous, start.Add(3*time.Second))
	if recreated.RatesAvailable || recreated.BytesSentPerSec != 0 || recreated.BytesRecvPerSec != 0 {
		t.Fatalf("same-name NIC recreation caused a spike: %#v", recreated)
	}
}

func TestNetworkCounterResetsAndInvalidIntervalsRequireNewBaseline(t *testing.T) {
	start := time.Unix(1000, 0)
	previous := map[string]networkSample{"eth0": {at: start, sent: 100, received: 200}}
	for _, test := range []struct {
		name string
		at   time.Time
		sent uint64
		recv uint64
	}{
		{"sent reset", start.Add(time.Second), 1, 300},
		{"received reset", start.Add(time.Second), 200, 1},
		{"no elapsed time", start, 200, 300},
		{"time reversed", start.Add(-time.Second), 200, 300},
	} {
		t.Run(test.name, func(t *testing.T) {
			result, _ := networkStatsFromSamples([]netstat.IOCountersStat{{Name: "eth0", BytesSent: test.sent, BytesRecv: test.recv}}, nil, previous, test.at)
			if !result.Available || result.RatesAvailable || result.BytesSentPerSec != 0 || result.BytesRecvPerSec != 0 {
				t.Fatalf("invalid interval produced rates: %#v", result)
			}
		})
	}
}
