export interface RealtimeEvent {
  type: string
  payload: { deviceId: string }
}

export function realtimeEvent(event: Event): RealtimeEvent | null {
  const detail = (event as CustomEvent<unknown>).detail
  if (!detail || typeof detail !== 'object') return null
  const candidate = detail as { type?: unknown; payload?: unknown }
  if (typeof candidate.type !== 'string' || !candidate.payload || typeof candidate.payload !== 'object') return null
  const deviceId = (candidate.payload as { deviceId?: unknown }).deviceId
  if (typeof deviceId !== 'string' || !deviceId) return null
  return { type: candidate.type, payload: { deviceId } }
}

export function matchesRealtimeEvent(event: Event, types: readonly string[], deviceId?: string) {
  const detail = realtimeEvent(event)
  return Boolean(detail && types.includes(detail.type) && (!deviceId || detail.payload.deviceId === deviceId))
}
