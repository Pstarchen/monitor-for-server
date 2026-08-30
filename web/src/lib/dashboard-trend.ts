export type TrendRangeHours = 1 | 6 | 24

export function trendWindow(rangeHours: TrendRangeHours, now = new Date()): { from: Date; to: Date } {
  const to = new Date(now)
  const from = new Date(to.getTime() - rangeHours * 3600_000)
  return { from, to }
}
