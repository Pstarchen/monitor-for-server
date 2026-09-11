package main

import "time"

// Keep start-to-start cadence. Slow collection/delivery skips missed slots
// instead of accumulating drift or immediately replaying a burst of samples.
func nextSampleDelay(start, now time.Time, interval time.Duration) time.Duration {
	if interval <= 0 {
		interval = 3 * time.Second
	}
	elapsed := now.Sub(start)
	if elapsed < 0 {
		return interval
	}
	return interval - elapsed%interval
}
