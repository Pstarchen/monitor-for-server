export type TrendRangeHours = 1 | 6 | 24
export type TimestampedTrendPoint = { collectedAt: string }

export function trendWindow(rangeHours: TrendRangeHours, now = new Date()): { from: Date; to: Date } {
  const to = new Date(now)
  const from = new Date(to.getTime() - rangeHours * 3600_000)
  return { from, to }
}

export function trendRangeValue(rangeHours: TrendRangeHours): `${TrendRangeHours}H` {
  return `${rangeHours}H`
}

export function alignTrendValues<T extends TimestampedTrendPoint>(
  reference: TimestampedTrendPoint[],
  source: T[],
  read: (point: T) => number,
  toleranceMs = 5 * 60_000,
): Array<number | null> {
  if (!source.length) return reference.map(() => null)
  const sourceTimes = source.map((point) => new Date(point.collectedAt).getTime())
  let cursor = 0
  return reference.map((point) => {
    const target = new Date(point.collectedAt).getTime()
    while (cursor + 1 < source.length && sourceTimes[cursor + 1] <= target) cursor += 1
    const next = cursor + 1 < source.length ? cursor + 1 : cursor
    const nearest = Math.abs(sourceTimes[next] - target) < Math.abs(sourceTimes[cursor] - target) ? next : cursor
    return Math.abs(sourceTimes[nearest] - target) <= toleranceMs ? read(source[nearest]) : null
  })
}
