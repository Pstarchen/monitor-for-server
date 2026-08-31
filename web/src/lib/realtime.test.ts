import { describe, expect, it } from 'vitest'
import { matchesRealtimeEvent, realtimeEvent } from './realtime'

describe('realtime events', () => {
  it('parses a typed device event', () => {
    const event = new CustomEvent('guanlan:realtime', { detail: { type: 'metric.updated', payload: { deviceId: 'server-a' } } })
    expect(realtimeEvent(event)).toEqual({ type: 'metric.updated', payload: { deviceId: 'server-a' } })
  })

  it('filters by event type and device', () => {
    const event = new CustomEvent('guanlan:realtime', { detail: { type: 'alert.opened', payload: { deviceId: 'server-a' } } })
    expect(matchesRealtimeEvent(event, ['alert.opened'], 'server-a')).toBe(true)
    expect(matchesRealtimeEvent(event, ['metric.updated'], 'server-a')).toBe(false)
    expect(matchesRealtimeEvent(event, ['alert.opened'], 'server-b')).toBe(false)
  })

  it('ignores malformed payloads', () => {
    expect(realtimeEvent(new CustomEvent('guanlan:realtime', { detail: { type: 'metric.updated' } }))).toBeNull()
    expect(realtimeEvent(new CustomEvent('guanlan:realtime', { detail: 'invalid' }))).toBeNull()
  })
})
