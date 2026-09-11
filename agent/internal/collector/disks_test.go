package collector

import (
	"errors"
	"runtime"
	"testing"
	"time"

	"github.com/shirou/gopsutil/v4/disk"

	"xingchen-monitor/agent/internal/model"
)

func TestDiskRatesUseEachDeviceOnce(t *testing.T) {
	start := time.Unix(100, 0)
	collector := &Collector{}
	reports := func() []model.DiskStats {
		return []model.DiskStats{
			{Mountpoint: "/", IODevice: "block:8:1"},
			{Mountpoint: "/data", IODevice: "block:8:17"},
			{Mountpoint: "/backup-bind", IODevice: "block:8:17"},
		}
	}
	first := reports()
	collector.applyDiskRates(first, map[string]diskIOSample{
		"block:8:0":  {readBytes: 1000, writeBytes: 2000, identity: "sda"},
		"block:8:1":  {readBytes: 1000, writeBytes: 2000, identity: "sda1"},
		"block:8:16": {readBytes: 5000, writeBytes: 7000, identity: "sdb"},
		"block:8:17": {readBytes: 5000, writeBytes: 7000, identity: "sdb1"},
	}, start)
	for _, item := range first {
		if item.IOAvailable || item.ReadBytesPerSec != 0 || item.WriteBytesPerSec != 0 {
			t.Fatalf("first sample must be unavailable: %#v", item)
		}
	}
	second := reports()
	collector.applyDiskRates(second, map[string]diskIOSample{
		"block:8:0":  {readBytes: 1600, writeBytes: 2400, identity: "sda"},
		"block:8:1":  {readBytes: 1600, writeBytes: 2400, identity: "sda1"},
		"block:8:16": {readBytes: 7000, writeBytes: 10000, identity: "sdb"},
		"block:8:17": {readBytes: 7000, writeBytes: 10000, identity: "sdb1"},
	}, start.Add(2*time.Second))
	if !second[0].IOAvailable || second[0].ReadBytesPerSec != 300 || second[0].WriteBytesPerSec != 200 {
		t.Fatalf("system partition inherited other device counters: %#v", second[0])
	}
	for _, item := range second[1:] {
		if !item.IOAvailable || item.ReadBytesPerSec != 1000 || item.WriteBytesPerSec != 1500 {
			t.Fatalf("data partition/bind rate = %#v", item)
		}
	}
	if len(collector.diskPrevious) != 2 {
		t.Fatalf("baselines should include only the two distinct mounted devices: %#v", collector.diskPrevious)
	}
}

func TestDiskRatesInvalidateMissingResetAndReplacedDevices(t *testing.T) {
	for _, test := range []struct {
		name    string
		counter map[string]diskIOSample
	}{
		{name: "read failed", counter: nil},
		{name: "device removed", counter: map[string]diskIOSample{}},
		{name: "counter reset", counter: map[string]diskIOSample{"C:": {readBytes: 1, writeBytes: 3, identity: "C:"}}},
		{name: "device replaced", counter: map[string]diskIOSample{"C:": {readBytes: 10000, writeBytes: 10000, identity: "replacement"}}},
	} {
		t.Run(test.name, func(t *testing.T) {
			start := time.Unix(100, 0)
			collector := &Collector{diskPrevious: map[string]diskIOSample{"C:": {at: start, readBytes: 1000, writeBytes: 2000, identity: "C:"}}}
			report := []model.DiskStats{{IODevice: "C:"}}
			collector.applyDiskRates(report, test.counter, start.Add(time.Second))
			if report[0].IOAvailable || report[0].ReadBytesPerSec != 0 || report[0].WriteBytesPerSec != 0 {
				t.Fatalf("invalid sample became a measurement: %#v", report)
			}
			if len(test.counter) == 0 {
				report = []model.DiskStats{{IODevice: "C:"}}
				collector.applyDiskRates(report, map[string]diskIOSample{"C:": {readBytes: 9000, writeBytes: 9000, identity: "C:"}}, start.Add(2*time.Second))
				if report[0].IOAvailable {
					t.Fatalf("reappearing device reused stale baseline: %#v", report)
				}
			}
		})
	}
}

func TestDiskRatesKeepDeviceIdentityWhenIdle(t *testing.T) {
	start := time.Unix(100, 0)
	collector := &Collector{diskPrevious: map[string]diskIOSample{"C:": {at: start, identity: "C:"}}}
	reports := []model.DiskStats{{IODevice: "C:"}, {IODevice: "D:"}}
	collector.applyDiskRates(reports, map[string]diskIOSample{"C:": {identity: "C:"}}, start.Add(time.Second))
	if !reports[0].IOAvailable || reports[0].IODevice != "C:" || reports[0].ReadBytesPerSec != 0 {
		t.Fatalf("valid idle device should remain an available zero: %#v", reports[0])
	}
	if reports[1].IOAvailable || reports[1].IODevice != "" {
		t.Fatalf("unsupported volume should not claim a mapped counter: %#v", reports[1])
	}
}

func TestDiskReportsDeduplicateFilesystemButHonorExplicitMounts(t *testing.T) {
	mounts := []diskMount{
		{partition: disk.PartitionStat{Mountpoint: "/backup", Device: "/dev/vdb1", Fstype: "ext4"}, usagePath: "/host/backup", filesystemID: "ext4:252:17", ioDevice: "block:252:17"},
		{partition: disk.PartitionStat{Mountpoint: "/www", Device: "/dev/vdb1", Fstype: "ext4"}, usagePath: "/host/www", filesystemID: "ext4:252:17", ioDevice: "block:252:17", rootMount: true},
		{partition: disk.PartitionStat{Mountpoint: "/", Device: "/dev/vda1", Fstype: "xfs"}, usagePath: "/host", filesystemID: "xfs:252:1", ioDevice: "block:252:1", rootMount: true},
	}
	usage := func(string) (*disk.UsageStat, error) {
		// Reserved blocks intentionally make Used+Free smaller than Total.
		return &disk.UsageStat{Total: 1000, Used: 450, Free: 450, UsedPercent: 50}, nil
	}
	reports := diskReports(mounts, nil, usage)
	if len(reports) != 2 || reports[0].Mountpoint != "/" || reports[1].Mountpoint != "/www" {
		t.Fatalf("default reports repeat a bind or lose its canonical mount: %#v", reports)
	}
	if reports[1].TotalBytes != 1000 || reports[1].UsedBytes != 450 || reports[1].FreeBytes != 450 || reports[1].UsagePercent != 50 {
		t.Fatalf("df reserved-block semantics were changed: %#v", reports[1])
	}
	reports = diskReports(mounts, []string{"/backup", "/www"}, usage)
	if len(reports) != 2 || reports[0].Mountpoint != "/backup" || reports[1].Mountpoint != "/www" {
		t.Fatalf("explicit selection should preserve both filesystem views: %#v", reports)
	}
}

func TestDiskReportsKeepAccessibleBindAndDistinctSubvolumes(t *testing.T) {
	mounts := []diskMount{
		{partition: disk.PartitionStat{Mountpoint: "/data"}, usagePath: "/data", filesystemID: "ext4:8:1", rootMount: true},
		{partition: disk.PartitionStat{Mountpoint: "/bind"}, usagePath: "/bind", filesystemID: "ext4:8:1"},
		{partition: disk.PartitionStat{Mountpoint: "/btrfs/a", Fstype: "btrfs"}, usagePath: "/btrfs/a"},
		{partition: disk.PartitionStat{Mountpoint: "/btrfs/b", Fstype: "btrfs"}, usagePath: "/btrfs/b"},
	}
	reports := diskReports(mounts, nil, func(path string) (*disk.UsageStat, error) {
		if path == "/data" {
			return nil, errors.New("inaccessible mount")
		}
		return &disk.UsageStat{Total: 100}, nil
	})
	if len(reports) != 3 || reports[0].Mountpoint != "/bind" {
		t.Fatalf("accessible filesystem views were lost: %#v", reports)
	}
}

func TestDiskCounterKeyKeepsWindowsVolumesDistinct(t *testing.T) {
	for _, test := range []struct{ input, want string }{{`c:\`, "C:"}, {"C:/", "C:"}, {"C:.", "C:"}, {"D:", "D:"}, {"disk1s1", "disk1s1"}} {
		if got := diskCounterKey(test.input); got != test.want {
			t.Fatalf("diskCounterKey(%q) = %q, want %q", test.input, got, test.want)
		}
	}
}

func TestWindowsDiskMountAllowlistAcceptsVolumeRootPaths(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows drive path normalization")
	}
	if !allowedMountpoint("C:", []string{`c:\`}) || !allowedMountpoint("D:", []string{"D:/"}) {
		t.Fatal("drive discovery keys must match explicit volume roots")
	}
	if allowedMountpoint("C:", []string{`D:\`, `C:\data`}) {
		t.Fatal("another drive or subdirectory must not match the volume root")
	}
}

func TestDiskReportsIgnoreReadOnlyImagesUnlessSelected(t *testing.T) {
	mounts := []diskMount{
		{partition: disk.PartitionStat{Mountpoint: "/snap/base/1", Fstype: "squashfs"}, usagePath: "/snap/base/1"},
		{partition: disk.PartitionStat{Mountpoint: "/media/cd", Fstype: "iso9660"}, usagePath: "/media/cd"},
		{partition: disk.PartitionStat{Mountpoint: "/media/dvd", Fstype: "udf", Opts: []string{"ro"}}, usagePath: "/media/dvd"},
		{partition: disk.PartitionStat{Mountpoint: "/archive", Fstype: "udf", Opts: []string{"rw"}}, usagePath: "/archive"},
		{partition: disk.PartitionStat{Mountpoint: "/data", Fstype: "ext4", Opts: []string{"ro"}}, usagePath: "/data"},
	}
	usage := func(string) (*disk.UsageStat, error) {
		return &disk.UsageStat{Total: 100, Used: 100, UsedPercent: 100}, nil
	}
	reports := diskReports(mounts, nil, usage)
	if len(reports) != 2 || reports[0].Mountpoint != "/archive" || reports[1].Mountpoint != "/data" {
		t.Fatalf("image filesystems should not trigger full-disk metrics, while data disks remain: %#v", reports)
	}
	reports = diskReports(mounts, []string{"/snap/base/1", "/media/dvd"}, usage)
	if len(reports) != 2 {
		t.Fatalf("explicitly selected image filesystems should remain visible: %#v", reports)
	}
}
