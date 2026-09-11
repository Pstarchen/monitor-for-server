import { describe, expect, it } from 'vitest'
import { timeChartPoints } from './metric-chart'

describe('metric chart time coordinates', () => {
  const times = [0, 5, 10, 100].map((seconds) => new Date(seconds * 1000).toISOString())

  it('keeps the actual time spacing and breaks a missing interval', () => {
    expect(timeChartPoints(times, [1, 2, 3, 4])).toEqual([
      [0, 1], [5000, 2], [10000, 3], [55000, null], [100000, 4],
    ])
  })

  it('uses server gap evidence for extrema samples instead of treating thinning as downtime', () => {
    expect(timeChartPoints(times, [1, 2, 3, 4], [false, false, false, false])).toHaveLength(4)
    const points = timeChartPoints(times, [1, 2, 3, 4], [false, false, true, false])
    expect(points).toContainEqual([7500, null])
    expect(points).not.toContainEqual([55000, null])
  })

  it('keeps missing and nonfinite measurements unknown instead of converting them to zero', () => {
    expect(timeChartPoints(times, [0, null, Number.NaN, 4], [false, false, false, false]))
      .toEqual([[0, 0], [5000, null], [10000, null], [100000, 4]])
  })
})
