import { describe, expect, it } from 'vitest'
import { createMobileBindingPayload, resolveMobileBindingBaseUrl } from './mobile-binding'

describe('mobile binding payload', () => {
  it('contains the server origin, one-time token and read scopes', () => {
    const payload = JSON.parse(createMobileBindingPayload(
      'https://monitor.example.com',
      'nzp_test-secret',
      ['nezha:inventory:read', 'nezha:server:read'],
    ))

    expect(payload).toEqual({
      type: 'xingchenyunxun-bind',
      baseUrl: 'https://monitor.example.com',
      token: 'nzp_test-secret',
      scopes: ['nezha:inventory:read', 'nezha:server:read'],
    })
  })

  it('prefers the saved public entry point and falls back to the current origin', () => {
    expect(resolveMobileBindingBaseUrl(' https://monitor.example.com/ ', 'http://internal.local')).toBe('https://monitor.example.com/')
    expect(resolveMobileBindingBaseUrl('', 'http://internal.local')).toBe('http://internal.local')
  })

  it('does not claim that manually selected scopes are read-only', () => {
    const payload = JSON.parse(createMobileBindingPayload(
      'https://monitor.example.com',
      'nzp_test-secret',
      ['nezha:server:read', 'nezha:server:write'],
    ))

    expect(payload.scopes).toEqual(['nezha:server:read', 'nezha:server:write'])
  })
})
