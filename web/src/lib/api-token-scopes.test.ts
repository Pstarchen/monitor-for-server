import { describe, expect, it } from 'vitest'
import { apiTokenScopeLabel, visibleApiTokenScopeGroups, visibleApiTokenScopes } from './api-token-scopes'

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
      'nezha:maintenance:read', 'nezha:maintenance:write', 'nezha:maintenance:delete',
      'nezha:realtime:read',
      'nezha:push:read', 'nezha:push:write', 'nezha:push:delete',
    ]))
  })

  it('only exposes administrator scope to administrators', () => {
    expect(visibleApiTokenScopes(false).some(([value]) => value === 'nezha:admin:*')).toBe(false)
    expect(visibleApiTokenScopes(true).some(([value]) => value === 'nezha:admin:*')).toBe(true)
  })

  it('groups scopes by resource while keeping the least-privilege read scope available first', () => {
    const groups = visibleApiTokenScopeGroups(false)
    expect(groups.map((group) => group.key)).toEqual([
      'inventory', 'server', 'service', 'ddns', 'alertrule', 'alert', 'maintenance', 'realtime', 'push',
    ])
    expect(groups[0].options[0]).toEqual(['nezha:inventory:read', '设备清单读取'])
    expect(apiTokenScopeLabel('nezha:server:exec')).toBe('远程任务执行')
    expect(apiTokenScopeLabel('nezha:push:write')).toBe('Push Kit 登记写入')
  })

  it('falls back to the raw value for a scope introduced by a newer server', () => {
    expect(apiTokenScopeLabel('nezha:future:read')).toBe('nezha:future:read')
  })
})
