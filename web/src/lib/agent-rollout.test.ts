import { describe, expect, it } from 'vitest'
import { availableRolloutActions, isStableAgentVersion, rolloutProgress } from '@/lib/agent-rollout'
import type { AgentRollout, AgentRolloutMemberStatus, AgentRolloutStatus } from '@/types'

function rollout(
  status: AgentRolloutStatus,
  memberStatuses: AgentRolloutMemberStatus[] = [],
  rollbackStartedAt: string | null = null,
  rollbackTotal: number | null = null,
): AgentRollout {
  return {
    id: 1,
    targetVersion: 'v1.20.14',
    maintenanceWindowId: null,
    canaryPercent: 10,
    ringCount: 3,
    currentRing: 0,
    maxConcurrent: 5,
    jitterSeconds: 30,
    failureThreshold: 20,
    verificationTimeoutSeconds: 600,
    status,
    statusReason: null,
    createdBy: 'admin',
    createdAt: '2026-09-04T00:00:00Z',
    updatedAt: '2026-09-04T00:00:00Z',
    startedAt: null,
    completedAt: null,
    rollbackStartedAt,
    rollbackTotal,
    members: memberStatuses.map((memberStatus, index) => ({
      id: index + 1,
      deviceId: `device-${index + 1}`,
      deviceName: `device-${index + 1}`,
      previousVersion: 'v1.20.13',
      ring: 0,
      order: index,
      eligibleAt: null,
      taskId: null,
      status: memberStatus,
      attempt: 0,
      queuedAt: null,
      error: null,
      confirmedAt: null,
    })),
  }
}

describe('Agent rollout helpers', () => {
  it('exposes only actions allowed by the rollout state', () => {
    expect(availableRolloutActions(rollout('DRAFT'))).toEqual(['start', 'cancel'])
    expect(availableRolloutActions(rollout('RUNNING'))).toEqual(['pause', 'cancel'])
    expect(availableRolloutActions(rollout('RUNNING', ['CONFIRMED']))).toEqual(['pause', 'cancel', 'rollback'])
    expect(availableRolloutActions(rollout('PAUSED', [], '2026-09-04T00:00:00Z'))).toEqual(['resume', 'cancel'])
    expect(availableRolloutActions(rollout('CANCELED'))).toEqual([])
    expect(availableRolloutActions(rollout('CANCELED', ['CONFIRMED']))).toEqual(['rollback'])
    expect(availableRolloutActions(rollout('ROLLED_BACK', [], '2026-09-04T00:00:00Z'))).toEqual([])
  })

  it('measures update and rollback confirmation independently', () => {
    expect(rolloutProgress(rollout('RUNNING', ['CONFIRMED', 'FAILED', 'ACCEPTED', 'PENDING']))).toEqual({
      total: 4, confirmed: 1, failed: 1, active: 1, percent: 50, rollback: false,
    })
    expect(rolloutProgress(rollout('ROLLING_BACK', ['ROLLBACK_CONFIRMED', 'ROLLBACK_FAILED', 'ROLLBACK_QUEUED'], '2026-09-04T00:00:00Z'))).toEqual({
      total: 3, confirmed: 1, failed: 1, active: 1, percent: 67, rollback: true,
    })
    expect(rolloutProgress(rollout('ROLLED_BACK', ['ROLLBACK_CONFIRMED', 'CANCELED', 'FAILED'], '2026-09-04T00:00:00Z'))).toEqual({
      total: 1, confirmed: 1, failed: 0, active: 0, percent: 100, rollback: true,
    })
    expect(rolloutProgress(rollout('CANCELED', ['ROLLBACK_CONFIRMED', 'CANCELED', 'CANCELED'], '2026-09-04T00:00:00Z', 3))).toEqual({
      total: 3, confirmed: 1, failed: 0, active: 0, percent: 33, rollback: true,
    })
  })

  it('accepts stable v-prefixed semantic versions only', () => {
    expect(isStableAgentVersion('v1.20.14')).toBe(true)
    expect(isStableAgentVersion(' v2.0.0 ')).toBe(true)
    expect(isStableAgentVersion('1.20.14')).toBe(false)
    expect(isStableAgentVersion('v1.20.14-rc.1')).toBe(false)
    expect(isStableAgentVersion('v01.20.14')).toBe(false)
  })
})
