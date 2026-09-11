//go:build linux

package collector

import (
	"bufio"
	"context"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/shirou/gopsutil/v4/common"
	"github.com/shirou/gopsutil/v4/disk"
	"golang.org/x/sys/unix"
)

type linuxDiskMount struct {
	majorMinor string
	root       string
	mountpoint string
	device     string
	filesystem string
}

func diskHostContext(ctx context.Context, hostRoot string) context.Context {
	if strings.TrimSpace(hostRoot) == "" {
		return ctx
	}
	values := common.EnvMap{}
	if current, ok := ctx.Value(common.EnvKey).(common.EnvMap); ok {
		for key, value := range current {
			values[key] = value
		}
	}
	for key, suffix := range map[common.EnvKeyType]string{
		common.HostProcEnvKey: "/proc", common.HostSysEnvKey: "/sys",
		common.HostDevEnvKey: "/dev", common.HostRunEnvKey: "/run",
	} {
		values[key] = hostPath(hostRoot, suffix)
	}
	return context.WithValue(ctx, common.EnvKey, values)
}

func diskEnvPath(ctx context.Context, key common.EnvKeyType, fallback string) string {
	if values, ok := ctx.Value(common.EnvKey).(common.EnvMap); ok && values[key] != "" {
		return values[key]
	}
	if value := os.Getenv(string(key)); value != "" {
		return value
	}
	return fallback
}

func mountedDisks(ctx context.Context, hostRoot string) ([]diskMount, error) {
	ctx = diskHostContext(ctx, hostRoot)
	partitions, err := disk.PartitionsWithContext(ctx, false)
	if err != nil {
		return nil, err
	}
	procRoot := diskEnvPath(ctx, common.HostProcEnvKey, "/proc")
	mountinfoPath := diskEnvPath(ctx, common.HostProcMountinfo, "")
	if mountinfoPath != "" {
		// Match gopsutil, which uses the directory of this setting.
		mountinfoPath = filepath.Join(filepath.Dir(mountinfoPath), "mountinfo")
	} else {
		mountinfoPath = filepath.Join(procRoot, "1", "mountinfo")
		if _, err := os.Stat(mountinfoPath); err != nil {
			mountinfoPath = filepath.Join(procRoot, "self", "mountinfo")
		}
	}
	content, err := os.ReadFile(mountinfoPath)
	if err != nil {
		return nil, err
	}
	mountinfo, err := parseLinuxDiskMounts(string(content))
	if err != nil {
		return nil, err
	}
	result := make([]diskMount, 0, len(partitions))
	for _, partition := range partitions {
		mount, ok := mountinfo[partition.Mountpoint]
		if !ok || partition.Fstype != mount.filesystem {
			continue
		}
		usagePath := verifiedDiskUsagePath(hostRoot, procRoot, partition.Mountpoint, mount.majorMinor, diskPathDevice)
		if usagePath == "" {
			continue
		}
		filesystemID := partition.Fstype + ":" + mount.majorMinor
		// Subvolumes can have distinct quota/capacity semantics. Do not merge
		// Btrfs or ZFS views merely because they use the same underlying storage.
		if partition.Fstype == "btrfs" || partition.Fstype == "zfs" {
			filesystemID = ""
		}
		// Keep the host's device name. gopsutil can resolve mapper aliases to
		// /host/dev/dm-0; counters instead use the authoritative major:minor.
		partition.Device = mount.device
		result = append(result, diskMount{
			partition: partition, usagePath: usagePath, filesystemID: filesystemID,
			ioDevice: "block:" + mount.majorMinor, rootMount: mount.root == "/",
		})
	}
	return result, nil
}

func parseLinuxDiskMounts(content string) (map[string]linuxDiskMount, error) {
	result := make(map[string]linuxDiskMount)
	scanner := bufio.NewScanner(strings.NewReader(content))
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	for scanner.Scan() {
		parts := strings.SplitN(scanner.Text(), " - ", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("invalid disk mountinfo record")
		}
		fields := strings.Fields(parts[0])
		details := strings.Fields(parts[1])
		if len(fields) < 6 || len(details) < 2 || !validBlockDeviceID(fields[2]) {
			return nil, fmt.Errorf("invalid disk mountinfo fields")
		}
		root, err := strconv.Unquote(`"` + fields[3] + `"`)
		if err != nil {
			return nil, fmt.Errorf("invalid disk mount root")
		}
		mountpoint, err := strconv.Unquote(`"` + fields[4] + `"`)
		if err != nil || !filepath.IsAbs(mountpoint) {
			return nil, fmt.Errorf("invalid disk mountpoint")
		}
		device, err := strconv.Unquote(`"` + details[1] + `"`)
		if err != nil {
			return nil, fmt.Errorf("invalid disk device")
		}
		result[mountpoint] = linuxDiskMount{
			majorMinor: fields[2], root: root, mountpoint: mountpoint, device: device, filesystem: details[0],
		}
	}
	return result, scanner.Err()
}

func validBlockDeviceID(value string) bool {
	parts := strings.Split(value, ":")
	if len(parts) != 2 {
		return false
	}
	for _, part := range parts {
		if _, err := strconv.ParseUint(part, 10, 32); err != nil {
			return false
		}
	}
	return true
}

func diskPathDevice(path string) (string, error) {
	var stat unix.Stat_t
	if err := unix.Stat(path, &stat); err != nil {
		return "", err
	}
	return fmt.Sprintf("%d:%d", unix.Major(uint64(stat.Dev)), unix.Minor(uint64(stat.Dev))), nil
}

func verifiedDiskUsagePath(hostRoot, procRoot, mountpoint, device string, statDevice func(string) (string, error)) string {
	path := hostPath(hostRoot, mountpoint)
	if path == "" {
		return ""
	}
	if actual, err := statDevice(path); err == nil && actual == device {
		return path
	}
	if hostRoot == "" {
		return ""
	}
	// Existing containers use private bind mounts. A mount added on the host
	// later may not exist under /host; proc's root link follows PID 1's actual
	// mount namespace. Use it only when its filesystem device also matches.
	fallback := filepath.Join(procRoot, "1", "root", strings.TrimPrefix(filepath.Clean(mountpoint), "/"))
	if actual, err := statDevice(fallback); err == nil && actual == device {
		return fallback
	}
	return ""
}

func readDiskCounters(ctx context.Context, hostRoot string) (map[string]diskIOSample, error) {
	ctx = diskHostContext(ctx, hostRoot)
	path := filepath.Join(diskEnvPath(ctx, common.HostProcEnvKey, "/proc"), "diskstats")
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseLinuxDiskCounters(string(content)), nil
}

func parseLinuxDiskCounters(content string) map[string]diskIOSample {
	result := make(map[string]diskIOSample)
	for _, line := range strings.Split(content, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 14 || !validBlockDeviceID(fields[0]+":"+fields[1]) {
			continue
		}
		readSectors, readErr := strconv.ParseUint(fields[5], 10, 64)
		writeSectors, writeErr := strconv.ParseUint(fields[9], 10, 64)
		if readErr != nil || writeErr != nil || readSectors > math.MaxUint64/512 || writeSectors > math.MaxUint64/512 {
			continue
		}
		// Linux diskstats always expresses sectors in 512-byte units,
		// including devices whose physical/logical sector size is 4096 bytes.
		result["block:"+fields[0]+":"+fields[1]] = diskIOSample{
			readBytes: readSectors * 512, writeBytes: writeSectors * 512, identity: fields[2],
		}
	}
	return result
}
