package collector

import (
	"context"

	"github.com/shirou/gopsutil/v4/mem"

	"xingchen-monitor/agent/internal/model"
)

func collectMemory(ctx context.Context) (model.MemoryStats, error) {
	virtual, err := mem.VirtualMemoryWithContext(ctx)
	if err != nil {
		return model.MemoryStats{}, err
	}
	swap, _ := mem.SwapMemoryWithContext(ctx)
	return memoryStatsFromCounters(virtual, swap), nil
}

func memoryStatsFromCounters(virtual *mem.VirtualMemoryStat, swap *mem.SwapMemoryStat) model.MemoryStats {
	// Available includes memory the OS can reclaim without swapping. Using
	// its complement keeps the used bytes, percentage and available bytes
	// consistent across Linux and Windows.
	available := min(virtual.Available, virtual.Total)
	used := virtual.Total - available
	result := model.MemoryStats{
		TotalBytes: virtual.Total, UsedBytes: used, AvailableBytes: available,
		CachedBytes: virtual.Cached,
	}
	if virtual.Total > 0 {
		result.UsagePercent = float64(used) / float64(virtual.Total) * 100
	}
	if swap != nil {
		result.SwapTotalBytes = swap.Total
		result.SwapUsedBytes = min(swap.Used, swap.Total)
		if swap.Total > 0 {
			result.SwapPercent = float64(result.SwapUsedBytes) / float64(swap.Total) * 100
		}
	}
	return result
}
