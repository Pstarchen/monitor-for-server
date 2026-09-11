//go:build linux

package collector

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/shirou/gopsutil/v4/common"
	netstat "github.com/shirou/gopsutil/v4/net"
)

func networkMetadata(ctx context.Context, hostRoot string, counters []netstat.IOCountersStat) map[string]networkInterfaceInfo {
	root := strings.TrimSpace(os.Getenv("HOST_SYS"))
	if values, ok := ctx.Value(common.EnvKey).(common.EnvMap); ok {
		if configured, exists := values[common.HostSysEnvKey]; exists {
			root = configured
		}
	}
	if root == "" {
		root = hostPath(hostRoot, "/sys")
	}
	return linuxNetworkMetadata(root, counters, basicNetworkMetadata())
}

func linuxNetworkMetadata(sysRoot string, counters []netstat.IOCountersStat, result map[string]networkInterfaceInfo) map[string]networkInterfaceInfo {
	for _, counter := range counters {
		name := counter.Name
		if filepath.Base(name) != name || name == "." || name == ".." {
			continue
		}
		path := filepath.Join(sysRoot, "class", "net", name)
		info := result[name]
		if index := readNetworkNumber(filepath.Join(path, "ifindex")); index > 0 {
			info.index, info.identity = index, strconv.Itoa(index)
		}
		info.linkIndex = readNetworkNumber(filepath.Join(path, "iflink"))
		// Unlike iflink, lower_* names refer to an interface in this network
		// namespace; a veth peer's index may refer to another namespace and
		// coincidentally match an unrelated local device.
		if entries, err := os.ReadDir(path); err == nil {
			for _, entry := range entries {
				if strings.HasPrefix(entry.Name(), "lower_") {
					info.lower = strings.TrimPrefix(entry.Name(), "lower_")
					break
				}
			}
		}
		kind := readNetworkNumber(filepath.Join(path, "type"))
		info.loopback = info.loopback || kind == 772
		// ARPHRD tunnel types plus tun_flags cover custom-named VPN devices.
		switch kind {
		case 768, 769, 776, 778, 823, 824, 65534:
			info.tunnel = true
		}
		if _, err := os.Stat(filepath.Join(path, "tun_flags")); err == nil {
			info.tunnel = true
		}
		if entry, err := os.Stat(filepath.Join(path, "bridge")); err == nil && entry.IsDir() {
			info.bridge = true
		}
		if entry, err := os.Stat(filepath.Join(path, "bonding")); err == nil && entry.IsDir() {
			info.bond = true
		}
		if master, err := os.Readlink(filepath.Join(path, "master")); err == nil {
			info.master = filepath.Base(master)
		}
		result[name] = info
	}
	return result
}

func readNetworkNumber(path string) int {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	value, _ := strconv.Atoi(strings.TrimSpace(string(data)))
	return value
}
