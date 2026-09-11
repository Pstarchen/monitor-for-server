package collector

import (
	"math"
	"testing"
	"time"

	"xingchen-monitor/agent/internal/model"
)

func TestProcessCPUReportsRecentActivityInsteadOfLifetimeAverage(t *testing.T) {
	start := time.Unix(10000, 0)
	previous := processSample{createdAt: 1000, cpuSeconds: 100, at: start}
	busy := processSample{createdAt: 1000, cpuSeconds: 103, at: start.Add(3 * time.Second)}
	if value := processCPUPercent(previous, busy); value != 100 {
		t.Fatalf("busy CPU = %v, want one fully occupied core", value)
	}
	idle := processSample{createdAt: 1000, cpuSeconds: 103, at: start.Add(6 * time.Second)}
	if value := processCPUPercent(busy, idle); value != 0 {
		t.Fatalf("idle CPU = %v, want zero despite lifetime CPU use", value)
	}
	multicore := processSample{createdAt: 1000, cpuSeconds: 112, at: start.Add(9 * time.Second)}
	if value := processCPUPercent(idle, multicore); value != 300 {
		t.Fatalf("multicore CPU = %v, want 300%%", value)
	}
}

func TestProcessCPUSamplingDistinguishesIdleFromMissingBaseline(t *testing.T) {
	previous := processSample{createdAt: 1000, cpuSeconds: 100, at: time.Now()}
	idle := previous
	idle.at = idle.at.Add(3 * time.Second)
	if !processCPUSampled(previous, idle) || processCPUPercent(previous, idle) != 0 {
		t.Fatal("an unchanged counter over a valid interval is a real idle sample")
	}
	if processCPUSampled(processSample{}, idle) {
		t.Fatal("first observation must not claim a measured zero")
	}
	reused := idle
	reused.createdAt++
	if processCPUSampled(previous, reused) {
		t.Fatal("PID reuse must establish a fresh baseline")
	}
}

func TestProcessCPURejectsReusedPIDsAndInvalidSamples(t *testing.T) {
	start := time.Unix(10000, 0)
	previous := processSample{createdAt: 1000, cpuSeconds: 100, at: start}
	tests := []struct {
		name     string
		previous processSample
		current  processSample
	}{
		{"first sample", processSample{}, processSample{createdAt: 1000, cpuSeconds: 200, at: start}},
		{"PID reused", previous, processSample{createdAt: 2000, cpuSeconds: 200, at: start.Add(time.Second)}},
		{"unknown creation", previous, processSample{cpuSeconds: 200, at: start.Add(time.Second)}},
		{"counter reset", previous, processSample{createdAt: 1000, cpuSeconds: 1, at: start.Add(time.Second)}},
		{"no elapsed time", previous, processSample{createdAt: 1000, cpuSeconds: 200, at: start}},
		{"clock reversed", previous, processSample{createdAt: 1000, cpuSeconds: 200, at: start.Add(-time.Second)}},
		{"NaN", previous, processSample{createdAt: 1000, cpuSeconds: math.NaN(), at: start.Add(time.Second)}},
		{"infinity", previous, processSample{createdAt: 1000, cpuSeconds: math.Inf(1), at: start.Add(time.Second)}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if value := processCPUPercent(test.previous, test.current); value != 0 {
				t.Fatalf("CPU = %v, want zero for invalid baseline", value)
			}
		})
	}
}

func TestProcessMemoryUsesResidentBytesOverHostTotal(t *testing.T) {
	if value := processMemoryPercent(128, 1024); value != 12.5 {
		t.Fatalf("RSS percentage = %v, want 12.5", value)
	}
	if value := processMemoryPercent(1, 0); value != 0 {
		t.Fatalf("unknown total percentage = %v, want zero", value)
	}
	if value := processMemoryPercent(2048, 1024); value != 100 {
		t.Fatalf("inconsistent total percentage = %v, want bounded 100", value)
	}
}

func TestProcessSelectionKeepsMonitoredProcessesBelowBusyLimit(t *testing.T) {
	items := []model.ProcessStats{
		{PID: 1, Name: "idle service", CPUPercent: 0, MemoryPercent: 1},
		{PID: 2, Name: "worker", CPUPercent: 200, MemoryPercent: 2},
		{PID: 3, Name: "other", CPUPercent: 50, MemoryPercent: 3},
	}
	selected := selectReportedProcesses(items, 1, []string{"idle service"})
	if len(selected) != 2 || selected[0].PID != 2 || selected[1].PID != 1 {
		t.Fatalf("selected processes = %#v, want busy worker and monitored idle service", selected)
	}
}
