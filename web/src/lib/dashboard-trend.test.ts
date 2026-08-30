import { describe, expect, it } from 'vitest'
import { trendWindow } from './dashboard-trend'

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
})
