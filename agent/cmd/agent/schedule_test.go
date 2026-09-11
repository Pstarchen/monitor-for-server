package main

import (
	"testing"
	"time"
)

func TestSampleCadenceAccountsForWorkAndSkipsMissedSlots(t *testing.T) {
	start := time.Now()
	for _, tt := range []struct{ work, want time.Duration }{
		{250 * time.Millisecond, 2750 * time.Millisecond},
		{4 * time.Second, 2 * time.Second},
		{6 * time.Second, 3 * time.Second},
	} {
		if got := nextSampleDelay(start, start.Add(tt.work), 3*time.Second); got != tt.want {
			t.Fatalf("work %v: delay %v, want %v", tt.work, got, tt.want)
		}
	}
}
