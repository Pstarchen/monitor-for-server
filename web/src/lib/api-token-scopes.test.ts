import { describe, expect, it } from 'vitest'
import { visibleApiTokenScopes } from './api-token-scopes'

describe('api token scopes', () => {
  it('exposes every supported resource scope', () => {
    const values = visibleApiTokenScopes(false).map(([value]) => value)
    expect(values).toEqual(expect.arrayContaining([
      'nezha:inventory:read', 'nezha:inventory:delete',
      'nezha:server:read', 'nezha:server:write', 'nezha:server:delete', 'nezha:server:exec',
      'nezha:service:read', 'nezha:service:write', 'nezha:service:delete',
      'nezha:ddns:read', 'nezha:ddns:write', 'nezha:ddns:delete',
      'nezha:alertrule:read', 'nezha:alertrule:write', 'nezha:alertrule:delete',
      'nezha:alert:read', 'nezha:alert:write',
    ]))
  })

  it('only exposes administrator scope to administrators', () => {
    expect(visibleApiTokenScopes(false).some(([value]) => value === 'nezha:admin:*')).toBe(false)
    expect(visibleApiTokenScopes(true).some(([value]) => value === 'nezha:admin:*')).toBe(true)
  })
})
