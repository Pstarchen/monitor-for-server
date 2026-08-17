import { describe, expect, it } from 'vitest'
import { safeLocalPath } from './format'

describe('safeLocalPath', () => {
  it('keeps local routes and rejects external redirects', () => {
    expect(safeLocalPath('/devices/one')).toBe('/devices/one')
    expect(safeLocalPath('//outside.example')).toBe('/dashboard')
    expect(safeLocalPath('https://outside.example')).toBe('/dashboard')
  })
})

