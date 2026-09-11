package collector

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v4/disk"

	"xingchen-monitor/agent/internal/model"
)

type diskIOSample struct {
	at         time.Time
	readBytes  uint64
	writeBytes uint64
	identity   string
}

// diskMount keeps filesystem identity separate from the block device used for
// I/O. A bind mount shares capacity; multiple partitions do not share counters.
type diskMount struct {
	partition    disk.PartitionStat
	usagePath    string
	filesystemID string
	ioDevice     string
	rootMount    bool
}

// collectDisks is called while the Collector's sampling mutex is held.
func (c *Collector) collectDisks(ctx context.Context, allowlist []string, hostRoot string) []model.DiskStats {
	mounts, err := mountedDisks(ctx, hostRoot)
	if err != nil {
		c.diskPrevious = nil
		return []model.DiskStats{}
	}
	disks := diskReports(mounts, allowlist, func(path string) (*disk.UsageStat, error) {
		return disk.UsageWithContext(ctx, path)
	})
	counters, err := readDiskCounters(ctx, hostRoot)
	if err != nil {
		counters = nil
	}
	c.applyDiskRates(disks, counters, time.Now())
	return disks
}

func diskReports(mounts []diskMount, allowlist []string, usage func(string) (*disk.UsageStat, error)) []model.DiskStats {
	// Prefer a filesystem's original root mount over directory binds, regardless
	// of mountinfo order. Explicit mountpoint selections retain each chosen view.
	mounts = append([]diskMount(nil), mounts...)
	sort.SliceStable(mounts, func(i, j int) bool {
		if mounts[i].rootMount != mounts[j].rootMount {
			return mounts[i].rootMount
		}
		left, right := mounts[i].partition.Mountpoint, mounts[j].partition.Mountpoint
		if len(left) != len(right) {
			return len(left) < len(right)
		}
		return left < right
	})
	result := make([]model.DiskStats, 0, len(mounts))
	seenPaths := make(map[string]bool)
	seenFilesystems := make(map[string]bool)
	for _, mount := range mounts {
		partition := mount.partition
		if len(allowlist) == 0 && imageFilesystem(partition) {
			continue
		}
		if !allowedMountpoint(partition.Mountpoint, allowlist) || seenPaths[partition.Mountpoint] {
			continue
		}
		if len(allowlist) == 0 && mount.filesystemID != "" && seenFilesystems[mount.filesystemID] {
			continue
		}
		stats, err := usage(mount.usagePath)
		if err != nil || stats == nil || stats.Total == 0 {
			continue
		}
		seenPaths[partition.Mountpoint] = true
		seenFilesystems[mount.filesystemID] = true
		result = append(result, model.DiskStats{
			Device: partition.Device, Mountpoint: partition.Mountpoint, FileSystem: partition.Fstype,
			TotalBytes: stats.Total, UsedBytes: stats.Used, FreeBytes: stats.Free, UsagePercent: stats.UsedPercent,
			IODevice: mount.ioDevice,
		})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Mountpoint < result[j].Mountpoint })
	return result
}

func imageFilesystem(partition disk.PartitionStat) bool {
	switch strings.ToLower(partition.Fstype) {
	case "squashfs", "iso9660":
		return true
	case "udf":
		for _, option := range partition.Opts {
			if option == "ro" {
				return true
			}
		}
	}
	return false
}

func (c *Collector) applyDiskRates(disks []model.DiskStats, counters map[string]diskIOSample, at time.Time) {
	next := make(map[string]diskIOSample)
	for index := range disks {
		item := &disks[index]
		item.ReadBytesPerSec, item.WriteBytesPerSec, item.IOAvailable = 0, 0, false
		current, ok := counters[item.IODevice]
		if !ok || item.IODevice == "" {
			item.IODevice = ""
			continue
		}
		current.at = at
		next[item.IODevice] = current
		previous, exists := c.diskPrevious[item.IODevice]
		seconds := at.Sub(previous.at).Seconds()
		if !exists || previous.identity != current.identity || seconds <= 0 ||
			current.readBytes < previous.readBytes || current.writeBytes < previous.writeBytes {
			continue
		}
		item.ReadBytesPerSec = rate(current.readBytes, previous.readBytes, seconds)
		item.WriteBytesPerSec = rate(current.writeBytes, previous.writeBytes, seconds)
		item.IOAvailable = true
	}
	// Missing devices and failed reads lose their baseline, so recovery cannot
	// turn a fresh cumulative counter into a spike or a misleading zero interval.
	c.diskPrevious = next
}

func diskCounterKey(device string) string {
	device = strings.TrimSpace(device)
	// gopsutil returns Windows volume keys as C:, not C:\ or physical disks.
	if len(device) >= 2 && device[1] == ':' {
		device = strings.ToUpper(strings.TrimRight(device, `\/`))
		// filepath.Clean turns the discovery key "C:" into "C:.". Normalize only
		// that drive form; C:\data must still remain a distinct path.
		if len(device) == 3 && device[2] == '.' {
			return device[:2]
		}
		return device
	}
	return device
}
