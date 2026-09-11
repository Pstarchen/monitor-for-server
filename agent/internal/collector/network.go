package collector

import (
	"context"
	"net"
	"sort"
	"strconv"
	"strings"
	"time"

	netstat "github.com/shirou/gopsutil/v4/net"

	"xingchen-monitor/agent/internal/model"
)

type networkSample struct {
	at       time.Time
	sent     uint64
	received uint64
	identity string
}

type networkInterfaceInfo struct {
	identity  string
	index     int
	linkIndex int
	lower     string
	loopback  bool
	tunnel    bool
	bridge    bool
	bond      bool
	master    string
}

func (c *Collector) collectNetwork(ctx context.Context, skipConnectionCount bool) model.NetworkStats {
	counters, err := netstat.IOCountersWithContext(ctx, true)
	// /proc/net/dev (or its platform equivalent) is one counter snapshot.
	// Timestamp it here, independently from slower collectors in this report.
	sampledAt := time.Now()
	if err != nil {
		c.networkPrevious = nil
		return model.NetworkStats{SampledInterfaces: []string{}}
	}
	metadata := networkMetadata(ctx, c.options.HostRoot, counters)
	selected := selectNetworkCounters(counters, c.options.NetworkInterfaces, metadata)
	result, next := networkStatsFromSamples(selected, metadata, c.networkPrevious, sampledAt)
	c.networkPrevious = next
	if !skipConnectionCount {
		connections, err := netstat.ConnectionsWithContext(ctx, "tcp")
		if err == nil {
			result.TCPConnections = len(connections)
		}
	}
	return result
}

func selectNetworkCounters(counters []netstat.IOCountersStat, allowlist []string, metadata map[string]networkInterfaceInfo) []netstat.IOCountersStat {
	allowed := make(map[string]bool, len(allowlist))
	for _, name := range allowlist {
		if name = strings.TrimSpace(name); name != "" {
			allowed[name] = true
		}
	}
	selected := make([]netstat.IOCountersStat, 0, len(counters))
	seen := make(map[string]bool, len(counters))
	present := make(map[string]bool, len(counters))
	for _, counter := range counters {
		present[counter.Name] = true
	}
	for _, counter := range counters {
		name := counter.Name
		if name == "" || seen[name] {
			continue
		}
		seen[name] = true
		if len(allowlist) > 0 {
			// An explicit list is authoritative, including VPNs and loopback.
			if allowed[name] {
				selected = append(selected, counter)
			}
			continue
		}
		info := metadata[name]
		if info.loopback || info.tunnel || info.bridge || excludedNetworkName(name) {
			continue
		}
		// A bond master already accounts for its member interfaces. Physical
		// ports of a bridge are retained because the bridge itself is omitted.
		if master, exists := metadata[info.master]; exists && master.bond {
			continue
		}
		// VLAN/macvlan layers duplicate their lower interface when it is in
		// this namespace. A lone virtual eth0 with an external peer is valid.
		if !info.bond && info.lower != "" && present[info.lower] {
			lower := metadata[info.lower]
			if !lower.loopback && !lower.tunnel && !lower.bridge && !excludedNetworkName(info.lower) {
				continue
			}
		}
		selected = append(selected, counter)
	}
	sort.Slice(selected, func(i, j int) bool { return selected[i].Name < selected[j].Name })
	return selected
}

func excludedNetworkName(name string) bool {
	name = strings.ToLower(strings.TrimSpace(name))
	if name == "lo" || name == "lo0" || name == "cni0" || name == "kube-ipvs0" {
		return true
	}
	for _, prefix := range []string{
		"docker", "veth", "br-", "virbr", "cni-", "flannel", "cali", "cilium", "lxc",
		"tun", "tap", "utun", "wg", "tailscale", "zerotier", "zt", "wireguard", "wintun",
		"vxlan", "genev", "gre", "gretap", "erspan", "ip6tnl", "ip6gre", "sit", "ipip",
		"vethernet", "vmware", "virtualbox", "loopback pseudo-interface",
	} {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}

func networkStatsFromSamples(counters []netstat.IOCountersStat, metadata map[string]networkInterfaceInfo, previous map[string]networkSample, sampledAt time.Time) (model.NetworkStats, map[string]networkSample) {
	result := model.NetworkStats{
		SampledInterfaces: make([]string, 0, len(counters)),
		Available:         len(counters) > 0, RatesAvailable: len(counters) > 0,
	}
	next := make(map[string]networkSample, len(counters))
	for _, counter := range counters {
		result.SampledInterfaces = append(result.SampledInterfaces, counter.Name)
		result.BytesSent += counter.BytesSent
		result.BytesRecv += counter.BytesRecv
		current := networkSample{at: sampledAt, sent: counter.BytesSent, received: counter.BytesRecv, identity: metadata[counter.Name].identity}
		next[counter.Name] = current
		before, exists := previous[counter.Name]
		seconds := current.at.Sub(before.at).Seconds()
		if !exists || before.at.IsZero() || before.identity != current.identity || seconds <= 0 || current.sent < before.sent || current.received < before.received {
			result.RatesAvailable = false
			continue
		}
		result.BytesSentPerSec += float64(current.sent-before.sent) / seconds
		result.BytesRecvPerSec += float64(current.received-before.received) / seconds
	}
	if !result.RatesAvailable {
		// Do not expose a partial aggregate as if every selected interface was
		// sampled. The next valid interval will have baselines for them all.
		result.BytesSentPerSec, result.BytesRecvPerSec = 0, 0
	}
	return result, next
}

func basicNetworkMetadata() map[string]networkInterfaceInfo {
	result := make(map[string]networkInterfaceInfo)
	interfaces, _ := net.Interfaces()
	for _, item := range interfaces {
		result[item.Name] = networkInterfaceInfo{
			identity: strconv.Itoa(item.Index), index: item.Index,
			loopback: item.Flags&net.FlagLoopback != 0,
			tunnel:   item.Flags&net.FlagPointToPoint != 0,
		}
	}
	return result
}
