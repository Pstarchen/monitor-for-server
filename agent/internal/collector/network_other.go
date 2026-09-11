//go:build !linux

package collector

import (
	"context"

	netstat "github.com/shirou/gopsutil/v4/net"
)

func networkMetadata(_ context.Context, _ string, _ []netstat.IOCountersStat) map[string]networkInterfaceInfo {
	return basicNetworkMetadata()
}
