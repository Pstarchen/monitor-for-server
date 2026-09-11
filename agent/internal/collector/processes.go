package collector

import (
	"context"
	"sort"
	"time"

	"github.com/shirou/gopsutil/v4/mem"
	"github.com/shirou/gopsutil/v4/process"

	"xingchen-monitor/agent/internal/model"
)

type processSample struct {
	createdAt  int64
	cpuSeconds float64
	at         time.Time
}

func (c *Collector) collectProcesses(ctx context.Context, limit int, monitored []string) []model.ProcessStats {
	items, _ := process.ProcessesWithContext(ctx)
	result := make([]model.ProcessStats, 0, len(items))
	next := make(map[int32]processSample, len(items))
	var totalMemory uint64
	if memory, err := mem.VirtualMemoryWithContext(ctx); err == nil {
		totalMemory = memory.Total
	}
	for _, item := range items {
		name, err := item.NameWithContext(ctx)
		if err != nil {
			continue
		}
		var cpuPercent float64
		var cpuSampled bool
		createdAt, createdErr := item.CreateTimeWithContext(ctx)
		times, timesErr := item.TimesWithContext(ctx)
		if createdErr == nil && createdAt > 0 && timesErr == nil {
			current := processSample{createdAt: createdAt, cpuSeconds: times.User + times.System, at: time.Now()}
			if finiteCPUValue(current.cpuSeconds) && current.cpuSeconds >= 0 {
				cpuSampled = processCPUSampled(c.processPrevious[item.Pid], current)
				cpuPercent = processCPUPercent(c.processPrevious[item.Pid], current)
				next[item.Pid] = current
			}
		}
		var memoryPercent float32
		if memory, err := item.MemoryInfoWithContext(ctx); err == nil {
			memoryPercent = processMemoryPercent(memory.RSS, totalMemory)
		}
		username, _ := item.UsernameWithContext(ctx)
		commandLine, _ := item.CmdlineWithContext(ctx)
		statuses, _ := item.StatusWithContext(ctx)
		status := "unknown"
		if len(statuses) > 0 {
			status = statuses[0]
		}
		result = append(result, model.ProcessStats{PID: item.Pid, Name: name, CommandLine: trimCommandLine(commandLine), Username: username, CPUPercent: cpuPercent, CPUSampled: cpuSampled, MemoryPercent: memoryPercent, Status: status})
	}
	// Drop exited or unreadable processes so a later PID reuse or recovered
	// read starts a new baseline rather than spanning unrelated samples.
	c.processPrevious = next
	return selectReportedProcesses(result, limit, monitored)
}

func processCPUPercent(previous, current processSample) float64 {
	if !processCPUSampled(previous, current) {
		return 0
	}
	elapsed := current.at.Sub(previous.at).Seconds()
	delta := current.cpuSeconds - previous.cpuSeconds
	if elapsed <= 0 || delta < 0 || !finiteCPUValue(delta) {
		return 0
	}
	percent := delta / elapsed * 100
	if !finiteCPUValue(percent) {
		return 0
	}
	// Like top's default display, one fully used logical core is 100%.
	// A multithreaded process can therefore legitimately exceed 100%.
	return percent
}

func processCPUSampled(previous, current processSample) bool {
	return !previous.at.IsZero() && current.createdAt > 0 && previous.createdAt == current.createdAt &&
		current.at.After(previous.at) && finiteCPUValue(previous.cpuSeconds) && finiteCPUValue(current.cpuSeconds) &&
		previous.cpuSeconds >= 0 && current.cpuSeconds >= previous.cpuSeconds
}

func processMemoryPercent(rss, total uint64) float32 {
	if total == 0 {
		return 0
	}
	return float32(float64(min(rss, total)) / float64(total) * 100)
}

func selectReportedProcesses(result []model.ProcessStats, limit int, monitored []string) []model.ProcessStats {
	sort.Slice(result, func(i, j int) bool {
		if result[i].CPUPercent == result[j].CPUPercent {
			if result[i].MemoryPercent == result[j].MemoryPercent {
				return result[i].PID < result[j].PID
			}
			return result[i].MemoryPercent > result[j].MemoryPercent
		}
		return result[i].CPUPercent > result[j].CPUPercent
	})
	if limit <= 0 || limit > maxProcessCount {
		limit = 12
	}
	if len(result) > limit {
		selected := append([]model.ProcessStats(nil), result[:limit]...)
		maxSelected := min(limit+maxMonitoredProcesses, maxProcessCount)
		seen := make(map[int32]struct{}, len(selected))
		for _, item := range selected {
			seen[item.PID] = struct{}{}
		}
		for _, item := range result[limit:] {
			if len(selected) >= maxSelected {
				break
			}
			if !matchesMonitoredProcess(item.Name, monitored) {
				continue
			}
			if _, exists := seen[item.PID]; exists {
				continue
			}
			selected = append(selected, item)
			seen[item.PID] = struct{}{}
		}
		return selected
	}
	return result
}
