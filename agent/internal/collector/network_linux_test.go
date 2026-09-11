//go:build linux

package collector

import (
	"os"
	"path/filepath"
	"testing"

	netstat "github.com/shirou/gopsutil/v4/net"
)

func TestLinuxNetworkMetadataDetectsCustomTopologyAndTunnelNames(t *testing.T) {
	sysRoot := t.TempDir()
	for name, files := range map[string]map[string]string{
		"eth0":   {"ifindex": "2\n", "iflink": "2\n", "type": "1\n"},
		"uplink": {"ifindex": "3\n", "iflink": "3\n", "type": "1\n"},
		"lan":    {"ifindex": "4\n", "iflink": "4\n", "type": "1\n"},
		"vpn":    {"ifindex": "5\n", "iflink": "5\n", "type": "65534\n"},
		"custom": {"ifindex": "6\n", "iflink": "6\n", "type": "1\n", "tun_flags": "0x1002\n"},
		"vlan":   {"ifindex": "7\n", "iflink": "3\n", "type": "1\n"},
	} {
		path := filepath.Join(sysRoot, "class", "net", name)
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
		for filename, content := range files {
			if err := os.WriteFile(filepath.Join(path, filename), []byte(content), 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}
	for _, path := range []string{"uplink/bonding", "lan/bridge"} {
		if err := os.MkdirAll(filepath.Join(sysRoot, "class", "net", filepath.FromSlash(path)), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink("../uplink", filepath.Join(sysRoot, "class", "net", "eth0", "master")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../uplink", filepath.Join(sysRoot, "class", "net", "vlan", "lower_uplink")); err != nil {
		t.Fatal(err)
	}
	counters := []netstat.IOCountersStat{{Name: "eth0"}, {Name: "uplink"}, {Name: "lan"}, {Name: "vpn"}, {Name: "custom"}, {Name: "vlan"}}
	metadata := linuxNetworkMetadata(sysRoot, counters, make(map[string]networkInterfaceInfo))
	if metadata["eth0"].identity != "2" || metadata["eth0"].master != "uplink" || !metadata["uplink"].bond || !metadata["lan"].bridge || !metadata["vpn"].tunnel || !metadata["custom"].tunnel || metadata["vlan"].lower != "uplink" {
		t.Fatalf("unexpected sysfs metadata: %#v", metadata)
	}
	selected := selectNetworkCounters(counters, nil, metadata)
	if len(selected) != 1 || selected[0].Name != "uplink" {
		t.Fatalf("custom topology selected = %#v, want bond master", selected)
	}
}
