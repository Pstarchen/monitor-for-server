//go:build linux

package collector

import (
	"errors"
	"testing"
)

func TestLinuxDiskMountsPreserveDeviceIdentityAndEscapedPaths(t *testing.T) {
	content := "36 25 253:0 / / rw,relatime - xfs /dev/mapper/vg-root rw\n" +
		"40 25 259:2 / /data\\040files rw - ext4 /dev/nvme0n1p2 rw\n" +
		"41 25 259:2 /backups /backup rw - ext4 /dev/nvme0n1p2 rw\n" +
		"42 25 252:1 / /boot rw - ext4 /dev/root rw\n"
	mounts, err := parseLinuxDiskMounts(content)
	if err != nil {
		t.Fatal(err)
	}
	if mounts["/"].majorMinor != "253:0" || mounts["/"].device != "/dev/mapper/vg-root" || mounts["/data files"].majorMinor != "259:2" {
		t.Fatalf("LVM/NVMe identities or escaped path changed: %#v", mounts)
	}
	if mounts["/backup"].root != "/backups" || mounts["/backup"].majorMinor != mounts["/data files"].majorMinor || mounts["/boot"].majorMinor != "252:1" {
		t.Fatalf("bind and root aliases were not mapped to actual devices: %#v", mounts)
	}
	if _, err := parseLinuxDiskMounts("bad mount record\n"); err == nil {
		t.Fatal("invalid mountinfo must not produce guessed device identities")
	}
}

func TestLinuxDiskCountersKeepWholeDiskPartitionAndLVMSeparate(t *testing.T) {
	counters := parseLinuxDiskCounters("" +
		"8 0 sda 1 0 2048 0 2 0 4096 0 0 0 0\n" +
		"8 1 sda1 1 0 2048 0 2 0 4096 0 0 0 0\n" +
		"253 0 dm-0 1 0 2048 0 2 0 4096 0 0 0 0\n" +
		"259 2 nvme0n1p2 1 0 8 0 2 0 16 0 0 0 0\n" +
		"8 17 sdb1 0 0 0 0 0 0 0 0 0 0 0\n" +
		"8 18 sdb2 0 0 18446744073709551615 0 0 0 0 0 0 0 0\n" +
		"8 19 sdb3 malformed\n")
	if len(counters) != 5 {
		t.Fatalf("valid identities/idle device dropped or malformed counters accepted: %#v", counters)
	}
	for _, key := range []string{"block:8:0", "block:8:1", "block:253:0"} {
		if counters[key].readBytes != 1048576 || counters[key].writeBytes != 2097152 {
			t.Fatalf("%s must have its own byte counters: %#v", key, counters[key])
		}
	}
	if counters["block:259:2"].readBytes != 4096 || counters["block:259:2"].writeBytes != 8192 {
		t.Fatalf("diskstats sector units must remain 512 bytes on NVMe: %#v", counters["block:259:2"])
	}
}

func TestVerifiedDiskUsagePathRejectsStaleHostMountAndValidatesFallback(t *testing.T) {
	for _, test := range []struct {
		name    string
		devices map[string]string
		want    string
	}{
		{name: "correct bind", devices: map[string]string{"/host/www": "252:17"}, want: "/host/www"},
		{name: "new host mount", devices: map[string]string{"/host/www": "252:1", "/host/proc/1/root/www": "252:17"}, want: "/host/proc/1/root/www"},
		{name: "wrong fallback", devices: map[string]string{"/host/www": "252:1", "/host/proc/1/root/www": "252:1"}},
		{name: "inaccessible fallback", devices: map[string]string{"/host/www": "252:1"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			got := verifiedDiskUsagePath("/host", "/host/proc", "/www", "252:17", func(path string) (string, error) {
				if device, ok := test.devices[path]; ok {
					return device, nil
				}
				return "", errors.New("not accessible")
			})
			if got != test.want {
				t.Fatalf("capacity path = %q, want %q; never label one filesystem with another device", got, test.want)
			}
		})
	}
}
