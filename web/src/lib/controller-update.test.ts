import { describe, expect, it } from 'vitest'
import { shortRevision, shouldPollUpdate, updateStateText } from './controller-update'

describe('controller update helpers', () => {
  it('formats revisions without exposing unwieldy image identifiers', () => {
    expect(shortRevision('1234567890abcdef')).toBe('1234567890ab')
    expect(shortRevision('abc123')).toBe('abc123')
    expect(shortRevision()).toBe('暂不可用')
  })

  it('polls only while a task is active', () => {
    expect(shouldPollUpdate('CHECKING')).toBe(true)
    expect(shouldPollUpdate('UPDATING')).toBe(true)
    expect(shouldPollUpdate('IDLE')).toBe(false)
    expect(updateStateText('IDLE', true)).toBe('发现可用更新')
  })
})
