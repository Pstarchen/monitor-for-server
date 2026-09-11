package collector

import (
	"math"
	"testing"

	"github.com/shirou/gopsutil/v4/cpu"
)

func TestCPUPercentUsesTheSameIntervalForHostAndCores(t *testing.T) {
	previous := []cpu.TimesStat{
		{CPU: "cpu0", User: 1000, Idle: 5000},
		{CPU: "cpu1", User: 5000, Idle: 1000},
	}
	current := []cpu.TimesStat{
		{CPU: "cpu0", User: 1002, Idle: 5000},
		{CPU: "cpu1", User: 5000, Idle: 1002},
	}
	overall, cores := cpuPercentFromSamples(previous, current, "linux")
	if overall != 50 || len(cores) != 2 || cores[0] != 100 || cores[1] != 0 {
		t.Fatalf("host/cores = %v/%v, want 50/[100 0]", overall, cores)
	}
	// Lifetime CPU usage was very different, and a later idle interval must
	// immediately show zero instead of retaining the prior busy sample.
	idle := []cpu.TimesStat{
		{CPU: "cpu0", User: 1002, Idle: 5003},
		{CPU: "cpu1", User: 5000, Idle: 1005},
	}
	overall, cores = cpuPercentFromSamples(current, idle, "linux")
	if overall != 0 || cores[0] != 0 || cores[1] != 0 {
		t.Fatalf("idle host/cores = %v/%v, want zero", overall, cores)
	}
}

func TestCPUPercentExcludesIOWaitAndAvoidsCountingLinuxGuestTwice(t *testing.T) {
	previous := []cpu.TimesStat{{CPU: "cpu0"}}
	current := []cpu.TimesStat{{CPU: "cpu0", User: 2, Nice: 1, System: 1, Idle: 3, Iowait: 3, Guest: 2, GuestNice: 1}}
	overall, cores := cpuPercentFromSamples(previous, current, "linux")
	if overall != 40 || cores[0] != 40 {
		t.Fatalf("host/cores = %v/%v, want 40/[40]", overall, cores)
	}
}

func TestCPUPercentMatchesCoreNamesAfterReordering(t *testing.T) {
	previous := []cpu.TimesStat{{CPU: "cpu0", User: 100}, {CPU: "cpu1", Idle: 100}}
	current := []cpu.TimesStat{{CPU: "cpu1", Idle: 102}, {CPU: "cpu0", User: 102}}
	overall, cores := cpuPercentFromSamples(previous, current, "linux")
	if overall != 50 || cores[0] != 0 || cores[1] != 100 {
		t.Fatalf("reordered host/cores = %v/%v, want 50/[0 100]", overall, cores)
	}
}

func TestCPUPercentWeightsElapsedTicks(t *testing.T) {
	previous := []cpu.TimesStat{{CPU: "cpu0"}, {CPU: "cpu1"}}
	current := []cpu.TimesStat{{CPU: "cpu0", User: 3}, {CPU: "cpu1", Idle: 1}}
	overall, cores := cpuPercentFromSamples(previous, current, "linux")
	if overall != 75 || cores[0] != 100 || cores[1] != 0 {
		t.Fatalf("weighted host/cores = %v/%v, want 75/[100 0]", overall, cores)
	}
}

func TestCPUPercentResetsInvalidBaselines(t *testing.T) {
	tests := []struct {
		name     string
		previous []cpu.TimesStat
		current  []cpu.TimesStat
	}{
		{"startup", nil, []cpu.TimesStat{{CPU: "cpu0", User: 100, Idle: 100}}},
		{"hotplug", []cpu.TimesStat{{CPU: "cpu0"}}, []cpu.TimesStat{{CPU: "cpu0", User: 1}, {CPU: "cpu1", User: 1}}},
		{"replaced core", []cpu.TimesStat{{CPU: "cpu0"}}, []cpu.TimesStat{{CPU: "cpu1", User: 1}}},
		{"counter reset", []cpu.TimesStat{{CPU: "cpu0", User: 10, Idle: 10}}, []cpu.TimesStat{{CPU: "cpu0", User: 1, Idle: 1}}},
		{"busy reset", []cpu.TimesStat{{CPU: "cpu0", User: 10}}, []cpu.TimesStat{{CPU: "cpu0", User: 1, Idle: 20}}},
		{"unchanged", []cpu.TimesStat{{CPU: "cpu0", User: 10}}, []cpu.TimesStat{{CPU: "cpu0", User: 10}}},
		{"invalid", []cpu.TimesStat{{CPU: "cpu0"}}, []cpu.TimesStat{{CPU: "cpu0", User: math.NaN()}}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			overall, cores := cpuPercentFromSamples(test.previous, test.current, "linux")
			if overall != 0 || len(cores) != len(test.current) {
				t.Fatalf("host/cores = %v/%v, want zero", overall, cores)
			}
			for _, value := range cores {
				if value != 0 {
					t.Fatalf("cores = %v, want zero", cores)
				}
			}
		})
	}
}
