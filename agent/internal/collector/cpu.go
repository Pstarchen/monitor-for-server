package collector

import (
	"context"
	"errors"
	"math"
	"runtime"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/load"

	"xingchen-monitor/agent/internal/model"
)

type cpuSample struct {
	times []cpu.TimesStat
}

func (c *Collector) collectCPU(ctx context.Context) (model.CPUStats, error) {
	current, err := cpu.TimesWithContext(ctx, true)
	if err != nil {
		return model.CPUStats{}, err
	}
	if len(current) == 0 {
		return model.CPUStats{}, errors.New("no CPU counters available")
	}
	previous := c.cpuPrevious.times
	if !sameCPUs(previous, current) {
		// Establish a real interval on startup and after CPU hotplug. Later
		// reports use the full interval since this Collector's preceding sample.
		previous = current
		timer := time.NewTimer(250 * time.Millisecond)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return model.CPUStats{}, ctx.Err()
		case <-timer.C:
		}
		current, err = cpu.TimesWithContext(ctx, true)
		if err != nil {
			return model.CPUStats{}, err
		}
		if len(current) == 0 {
			return model.CPUStats{}, errors.New("no CPU counters available")
		}
	}
	c.cpuPrevious = cpuSample{times: current}
	usage, perCore := cpuPercentFromSamples(previous, current, runtime.GOOS)
	physical, _ := cpu.CountsWithContext(ctx, false)
	models, _ := cpu.InfoWithContext(ctx)
	avg, _ := load.AvgWithContext(ctx)
	result := model.CPUStats{
		LogicalCores: len(current), PhysicalCores: physical,
		UsagePercent: usage, PerCorePercent: perCore,
	}
	if len(models) > 0 {
		result.Model = strings.TrimSpace(models[0].ModelName)
	}
	if avg != nil {
		result.Load1, result.Load5, result.Load15 = avg.Load1, avg.Load5, avg.Load15
	}
	return result, nil
}

func sameCPUs(previous, current []cpu.TimesStat) bool {
	if len(previous) == 0 || len(previous) != len(current) {
		return false
	}
	seen := make(map[string]bool, len(previous))
	for _, item := range previous {
		seen[item.CPU] = true
	}
	for _, item := range current {
		if !seen[item.CPU] {
			return false
		}
		delete(seen, item.CPU)
	}
	return len(seen) == 0
}

// Both overall and per-core utilization use these same counter snapshots.
// Overall CPU is weighted by elapsed ticks, not by separately sampled usage.
func cpuPercentFromSamples(previous, current []cpu.TimesStat, goos string) (float64, []float64) {
	perCore := make([]float64, len(current))
	if !sameCPUs(previous, current) {
		return 0, perCore
	}
	byCPU := make(map[string]cpu.TimesStat, len(previous))
	for _, item := range previous {
		byCPU[item.CPU] = item
	}
	var totalDelta, busyDelta float64
	for index, item := range current {
		beforeTotal, beforeBusy := cpuTotalAndBusy(byCPU[item.CPU], goos)
		afterTotal, afterBusy := cpuTotalAndBusy(item, goos)
		total, busy := afterTotal-beforeTotal, afterBusy-beforeBusy
		if !finiteCPUValue(total) || !finiteCPUValue(busy) || total <= 0 || busy < 0 {
			continue
		}
		busy = math.Min(total, busy)
		perCore[index] = busy / total * 100
		totalDelta += total
		busyDelta += busy
	}
	if totalDelta <= 0 {
		return 0, perCore
	}
	return busyDelta / totalDelta * 100, perCore
}

func cpuTotalAndBusy(item cpu.TimesStat, goos string) (float64, float64) {
	total := item.User + item.System + item.Idle + item.Nice + item.Iowait +
		item.Irq + item.Softirq + item.Steal
	// On Linux guest times are already included in user/nice counters.
	if goos != "linux" {
		total += item.Guest + item.GuestNice
	}
	return total, total - item.Idle - item.Iowait
}

func finiteCPUValue(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0)
}
