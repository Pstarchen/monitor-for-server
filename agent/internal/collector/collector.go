package collector

import (
	"context"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/disk"
	"github.com/shirou/gopsutil/v4/host"
	"github.com/shirou/gopsutil/v4/load"
	"github.com/shirou/gopsutil/v4/mem"
	netstat "github.com/shirou/gopsutil/v4/net"
	"github.com/shirou/gopsutil/v4/process"
	"github.com/shirou/gopsutil/v4/sensors"

	"guanlan-monitor/agent/internal/model"
)

type ioSample struct {
	at        time.Time
	netSent   uint64
	netRecv   uint64
	diskRead  uint64
	diskWrite uint64
}

type Collector struct {
	services []string
	mu       sync.Mutex
	previous ioSample
}

func New(services []string) *Collector {
	return &Collector{services: append([]string(nil), services...)}
}

func (c *Collector) Collect(ctx context.Context) (model.Report, error) {
	now := time.Now().UTC()
	hostInfo, err := collectHost(ctx)
	if err != nil {
		return model.Report{}, err
	}
	cpuInfo, err := collectCPU(ctx)
	if err != nil {
		return model.Report{}, err
	}
	memory, err := collectMemory(ctx)
	if err != nil {
		return model.Report{}, err
	}
	disks, diskRead, diskWrite := collectDisks(ctx)
	network, netSent, netRecv := collectNetwork(ctx)

	c.mu.Lock()
	previous := c.previous
	c.previous = ioSample{at: now, netSent: netSent, netRecv: netRecv, diskRead: diskRead, diskWrite: diskWrite}
	c.mu.Unlock()

	if !previous.at.IsZero() {
		seconds := now.Sub(previous.at).Seconds()
		if seconds > 0 {
			network.BytesSentPerSec = rate(netSent, previous.netSent, seconds)
			network.BytesRecvPerSec = rate(netRecv, previous.netRecv, seconds)
			readRate := rate(diskRead, previous.diskRead, seconds)
			writeRate := rate(diskWrite, previous.diskWrite, seconds)
			for index := range disks {
				disks[index].ReadBytesPerSec = readRate
				disks[index].WriteBytesPerSec = writeRate
			}
		}
	}

	return model.Report{
		CollectedAt: now,
		Host:        hostInfo,
		CPU:         cpuInfo,
		Memory:      memory,
		Disks:       disks,
		Network:     network,
		Processes:   collectProcesses(ctx, 12),
		Services:    collectServices(ctx, c.services),
	}, nil
}

func collectHost(ctx context.Context) (model.HostInfo, error) {
	info, err := host.InfoWithContext(ctx)
	if err != nil {
		return model.HostInfo{}, err
	}
	temperatures, _ := sensors.TemperaturesWithContext(ctx)
	result := model.HostInfo{
		Hostname: info.Hostname, OS: info.OS, Platform: info.Platform,
		PlatformVersion: info.PlatformVersion, KernelVersion: info.KernelVersion,
		Architecture: runtime.GOARCH, UptimeSeconds: info.Uptime, BootTime: info.BootTime,
	}
	for _, sensor := range temperatures {
		if sensor.Temperature > 0 {
			result.Temperatures = append(result.Temperatures, model.Temperature{Sensor: sensor.SensorKey, Value: sensor.Temperature})
		}
	}
	return result, nil
}

func collectCPU(ctx context.Context) (model.CPUStats, error) {
	usage, err := cpu.PercentWithContext(ctx, 250*time.Millisecond, false)
	if err != nil {
		return model.CPUStats{}, err
	}
	perCore, _ := cpu.PercentWithContext(ctx, 0, true)
	logical, _ := cpu.CountsWithContext(ctx, true)
	physical, _ := cpu.CountsWithContext(ctx, false)
	models, _ := cpu.InfoWithContext(ctx)
	avg, _ := load.AvgWithContext(ctx)
	result := model.CPUStats{LogicalCores: logical, PhysicalCores: physical, PerCorePercent: perCore}
	if len(usage) > 0 {
		result.UsagePercent = usage[0]
	}
	if len(models) > 0 {
		result.Model = strings.TrimSpace(models[0].ModelName)
	}
	if avg != nil {
		result.Load1, result.Load5, result.Load15 = avg.Load1, avg.Load5, avg.Load15
	}
	return result, nil
}

func collectMemory(ctx context.Context) (model.MemoryStats, error) {
	virtual, err := mem.VirtualMemoryWithContext(ctx)
	if err != nil {
		return model.MemoryStats{}, err
	}
	swap, _ := mem.SwapMemoryWithContext(ctx)
	result := model.MemoryStats{
		TotalBytes: virtual.Total, UsedBytes: virtual.Used, AvailableBytes: virtual.Available,
		UsagePercent: virtual.UsedPercent, CachedBytes: virtual.Cached,
	}
	if swap != nil {
		result.SwapTotalBytes, result.SwapUsedBytes, result.SwapPercent = swap.Total, swap.Used, swap.UsedPercent
	}
	return result, nil
}

func collectDisks(ctx context.Context) ([]model.DiskStats, uint64, uint64) {
	partitions, _ := disk.PartitionsWithContext(ctx, false)
	result := make([]model.DiskStats, 0, len(partitions))
	seen := make(map[string]struct{})
	for _, partition := range partitions {
		if _, exists := seen[partition.Mountpoint]; exists {
			continue
		}
		usage, err := disk.UsageWithContext(ctx, partition.Mountpoint)
		if err != nil || usage.Total == 0 {
			continue
		}
		seen[partition.Mountpoint] = struct{}{}
		result = append(result, model.DiskStats{
			Device: partition.Device, Mountpoint: partition.Mountpoint, FileSystem: partition.Fstype,
			TotalBytes: usage.Total, UsedBytes: usage.Used, FreeBytes: usage.Free, UsagePercent: usage.UsedPercent,
		})
	}
	counters, _ := disk.IOCountersWithContext(ctx)
	var readBytes, writeBytes uint64
	for _, counter := range counters {
		readBytes += counter.ReadBytes
		writeBytes += counter.WriteBytes
	}
	return result, readBytes, writeBytes
}

func collectNetwork(ctx context.Context) (model.NetworkStats, uint64, uint64) {
	counters, _ := netstat.IOCountersWithContext(ctx, false)
	connections, _ := netstat.ConnectionsWithContext(ctx, "tcp")
	result := model.NetworkStats{TCPConnections: len(connections)}
	if len(counters) == 0 {
		return result, 0, 0
	}
	return result, counters[0].BytesSent, counters[0].BytesRecv
}

func collectProcesses(ctx context.Context, limit int) []model.ProcessStats {
	items, _ := process.ProcessesWithContext(ctx)
	result := make([]model.ProcessStats, 0, len(items))
	for _, item := range items {
		name, err := item.NameWithContext(ctx)
		if err != nil {
			continue
		}
		cpuPercent, _ := item.CPUPercentWithContext(ctx)
		memoryPercent, _ := item.MemoryPercentWithContext(ctx)
		username, _ := item.UsernameWithContext(ctx)
		statuses, _ := item.StatusWithContext(ctx)
		status := "unknown"
		if len(statuses) > 0 {
			status = statuses[0]
		}
		result = append(result, model.ProcessStats{PID: item.Pid, Name: name, Username: username, CPUPercent: cpuPercent, MemoryPercent: memoryPercent, Status: status})
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].CPUPercent == result[j].CPUPercent {
			return result[i].MemoryPercent > result[j].MemoryPercent
		}
		return result[i].CPUPercent > result[j].CPUPercent
	})
	if len(result) > limit {
		result = result[:limit]
	}
	return result
}

func rate(current, previous uint64, seconds float64) float64 {
	if current < previous || seconds <= 0 {
		return 0
	}
	return float64(current-previous) / seconds
}
