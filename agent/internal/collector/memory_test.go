package collector

import (
	"testing"

	"github.com/shirou/gopsutil/v4/mem"
)

func TestMemoryUsesAvailableForBytesAndPercent(t *testing.T) {
	// Linux's legacy Used field omits cache differently from MemAvailable.
	// Windows also exposes a rounded integer UsedPercent; neither should
	// override the byte counters shown alongside the percentage.
	virtual := &mem.VirtualMemoryStat{Total: 1000, Available: 333, Used: 500, UsedPercent: 66, Cached: 123}
	result := memoryStatsFromCounters(virtual, nil)
	if result.TotalBytes != 1000 || result.UsedBytes != 667 || result.AvailableBytes != 333 || result.UsagePercent != 66.7 || result.CachedBytes != 123 {
		t.Fatalf("memory = %#v, want consistent 667 used + 333 available at 66.7%%", result)
	}
}

func TestMemoryBoundsRemainValidWithoutUnderflow(t *testing.T) {
	for _, virtual := range []*mem.VirtualMemoryStat{
		{},
		{Total: 100, Available: 200},
		{Total: 100, Available: 0},
	} {
		result := memoryStatsFromCounters(virtual, nil)
		if result.UsedBytes+result.AvailableBytes != result.TotalBytes || result.UsagePercent < 0 || result.UsagePercent > 100 {
			t.Fatalf("invalid memory bounds: %#v", result)
		}
	}
}

func TestMemorySwapPercentUsesTheReportedBytes(t *testing.T) {
	result := memoryStatsFromCounters(&mem.VirtualMemoryStat{}, &mem.SwapMemoryStat{Total: 1000, Used: 125, UsedPercent: 12})
	if result.SwapTotalBytes != 1000 || result.SwapUsedBytes != 125 || result.SwapPercent != 12.5 {
		t.Fatalf("swap = %#v, want 125/1000 at 12.5%%", result)
	}
	result = memoryStatsFromCounters(&mem.VirtualMemoryStat{}, &mem.SwapMemoryStat{Used: 10})
	if result.SwapUsedBytes != 0 || result.SwapPercent != 0 {
		t.Fatalf("zero-total swap = %#v, want zero usage", result)
	}
}
