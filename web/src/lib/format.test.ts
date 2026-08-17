import { describe, expect, it } from 'vitest'
import { rate, safeLocalPath, uptime } from './format'

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
})
