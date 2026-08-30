import { describe, expect, it } from 'vitest'
import { counterRate } from './device-analytics'

describe('counterRate', () => {
  it('normalizes counter growth using the actual sample interval', () => {
    expect(counterRate(2_500, 1_000, 30)).toBe(50)
  })

  it('returns zero when a container restart resets the counter', () => {
    expect(counterRate(120, 9_000, 3)).toBe(0)
  })

  it('rejects invalid or non-positive intervals', () => {
    expect(counterRate(100, 0, 0)).toBe(0)
    expect(counterRate(Number.NaN, 0, 1)).toBe(0)
  })
})
