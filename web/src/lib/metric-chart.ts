export type TimeChartPoint = [number, number | null]

export function timeChartPoints(
  timestamps: string[],
  values: Array<number | null>,
  gapBefore?: boolean[],
): TimeChartPoint[] {
  const times = timestamps.map((value) => new Date(value).getTime())
  const intervals = times.slice(1).map((value, index) => value - times[index])
    .filter((value) => Number.isFinite(value) && value > 0).sort((a, b) => a - b)
  const threshold = intervals.length ? Math.max(1000, intervals[Math.floor((intervals.length - 1) / 2)] * 3) : Infinity
  const points: TimeChartPoint[] = []
  times.forEach((time, index) => {
    if (!Number.isFinite(time)) return
    const previous = points[points.length - 1]?.[0]
    const gap = gapBefore ? gapBefore[index] : previous !== undefined && time - previous > threshold
    if (gap && previous !== undefined && time > previous) points.push([previous + (time - previous) / 2, null])
    const value = values[index]
    points.push([time, value != null && Number.isFinite(value) ? value : null])
  })
  return points
}
