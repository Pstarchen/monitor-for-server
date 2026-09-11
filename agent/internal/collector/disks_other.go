//go:build !linux

package collector

import (
	"context"
	"path/filepath"
	"runtime"

	"github.com/shirou/gopsutil/v4/disk"
)

func mountedDisks(ctx context.Context, hostRoot string) ([]diskMount, error) {
	partitions, err := disk.PartitionsWithContext(ctx, false)
	if err != nil && len(partitions) == 0 {
		return nil, err
	}
	result := make([]diskMount, 0, len(partitions))
	for _, partition := range partitions {
		path := hostPath(hostRoot, partition.Mountpoint)
		if path == "" {
			continue
		}
		key := partition.Device
		if runtime.GOOS != "windows" {
			key = filepath.Base(key)
		}
		key = diskCounterKey(key)
		if runtime.GOOS == "windows" && hostRoot == "" && len(key) == 2 && key[1] == ':' {
			// A bare C: means the current directory on that drive to Win32;
			// always query the volume root when reporting drive capacity.
			path = key + `\`
		}
		// Only exact OS counter matches are accepted. In particular, a Darwin
		// volume such as disk1s1 must not inherit the whole disk1's I/O.
		result = append(result, diskMount{partition: partition, usagePath: path, ioDevice: key, rootMount: true})
	}
	return result, nil
}

func readDiskCounters(ctx context.Context, _ string) (map[string]diskIOSample, error) {
	counters, err := disk.IOCountersWithContext(ctx)
	if err != nil {
		return nil, err
	}
	result := make(map[string]diskIOSample, len(counters))
	for key, counter := range counters {
		result[diskCounterKey(key)] = diskIOSample{
			readBytes: counter.ReadBytes, writeBytes: counter.WriteBytes, identity: key,
		}
	}
	return result, nil
}
