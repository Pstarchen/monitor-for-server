import { describe, expect, it } from 'vitest'
import { rate, rateScale, safeLocalPath, uptime } from './format'

describe('safeLocalPath', () => {
  it('keeps local routes and rejects external redirects', () => {
    expect(safeLocalPath('/devices/one')).toBe('/devices/one')
    expect(safeLocalPath('//outside.example')).toBe('/dashboard')
    expect(safeLocalPath('https://outside.example')).toBe('/dashboard')
  })

  it('formats monitoring rates and uptime without unstable precision', () => {
    expect(rate(1536)).toBe('1.5 KB/s')
    expect(uptime(90061)).toBe('1 天 1 小时')
    expect(uptime(3599)).toBe('59 分钟')
  })

  it('chooses a readable shared unit for chart throughput', () => {
    expect(rateScale(0)).toEqual({ divisor: 1, unit: 'B/s' })
    expect(rateScale(1024)).toEqual({ divisor: 1024, unit: 'KB/s' })
    expect(rateScale(1024 ** 2 * 3)).toEqual({ divisor: 1024 ** 2, unit: 'MB/s' })
    expect(rateScale(Number.MAX_SAFE_INTEGER)).toEqual({ divisor: 1024 ** 4, unit: 'TB/s' })
  })
})
