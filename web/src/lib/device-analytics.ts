/**
 * Convert a monotonically increasing counter into a per-second rate.
 * Counters can reset when a container restarts, so a reset is reported as zero
 * instead of producing a misleading negative rate.
 */
export function counterRate(current: number, previous: number, seconds: number): number {
  if (!Number.isFinite(current) || !Number.isFinite(previous) || !Number.isFinite(seconds)) return 0
  if (seconds <= 0 || current < previous) return 0
  return (current - previous) / seconds
}
