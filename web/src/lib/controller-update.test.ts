import { describe, expect, it } from 'vitest'
import { databaseCompatibilityText, releaseSourceText, rollbackStateText, shortRevision, shouldPollUpdate, updatePhaseText, updateStateText, updateTriggerText, verificationText } from './controller-update'

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

  it('formats operational update metadata without assuming GitHub', () => {
    expect(releaseSourceText('registry.internal.example', true)).toBe('registry.internal.example（缓存）')
    expect(releaseSourceText('local')).toBe('本地离线清单')
    expect(verificationText('sha256')).toBe('SHA256 完整性校验')
    expect(verificationText('manifest-sha256')).toBe('预置信任清单 + SHA256')
    expect(updatePhaseText('BACKUP')).toBe('更新前备份')
    expect(updatePhaseText('INCOMPATIBLE_VERSION')).toBe('主版本需人工评估')
    expect(rollbackStateText('FAILED')).toBe('自动恢复失败')
    expect(databaseCompatibilityText('MANUAL_REVIEW_REQUIRED')).toBe('需人工确认迁移兼容性')
    expect(updateTriggerText('automatic')).toBe('自动更新')
    expect(updateTriggerText('manual')).toBe('管理员手动执行')
  })
})
