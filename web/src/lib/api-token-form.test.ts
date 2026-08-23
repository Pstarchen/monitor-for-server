import { describe, expect, it } from 'vitest'
import { createDefaultApiTokenForm, parseServerIds } from './api-token-form'

describe('api token form helpers', () => {
  it('starts with a read-only inventory scope and finite expiry', () => {
    expect(createDefaultApiTokenForm()).toEqual({
      name: '', scopes: ['nezha:inventory:read'], serverIds: '', expiresInDays: 90,
    })
  })

  it('normalizes comma, full-width comma, and newline separated server IDs', () => {
    expect(parseServerIds(' node-a, node-b，node-a\nnode-c ')).toEqual(['node-a', 'node-b', 'node-c'])
    expect(parseServerIds('   ')).toEqual([])
  })
})
