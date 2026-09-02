import { describe, expect, it } from 'vitest'
import { alignTrendValues, trendRangeValue, trendWindow } from './dashboard-trend'

describe('trendWindow', () => {
  it('returns a UTC-safe range with the requested duration', () => {
    const now = new Date('2026-08-30T12:34:56.000Z')
    const window = trendWindow(6, now)

    expect(window.to.toISOString()).toBe(now.toISOString())
    expect(window.from.toISOString()).toBe('2026-08-30T06:34:56.000Z')
  })

  it('does not mutate the supplied date', () => {
    const now = new Date('2026-08-30T12:34:56.000Z')
    trendWindow(24, now)

    expect(now.toISOString()).toBe('2026-08-30T12:34:56.000Z')
  })

  it('maps dashboard ranges to the compact history API values', () => {
    expect(trendRangeValue(1)).toBe('1H')
    expect(trendRangeValue(6)).toBe('6H')
    expect(trendRangeValue(24)).toBe('24H')
  })

  it('aligns comparison points in linear time while respecting the tolerance', () => {
    const reference = [
      { collectedAt: '2026-08-30T12:00:00.000Z' },
      { collectedAt: '2026-08-30T12:05:00.000Z' },
      { collectedAt: '2026-08-30T12:20:00.000Z' },
    ]
    const source = [
      { collectedAt: '2026-08-30T11:59:30.000Z', value: 10 },
      { collectedAt: '2026-08-30T12:05:20.000Z', value: 20 },
    ]

    expect(alignTrendValues(reference, source, (point) => point.value)).toEqual([10, 20, null])
  })
})
