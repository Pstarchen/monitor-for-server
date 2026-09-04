import type { AgentRollout, AgentRolloutMemberStatus, AgentRolloutStatus } from '@/types'

export type AgentRolloutAction = 'start' | 'pause' | 'resume' | 'cancel' | 'rollback'

export const rolloutStatusLabels: Record<AgentRolloutStatus, string> = {
  DRAFT: '草稿',
  RUNNING: '发布中',
  PAUSED: '已暂停',
  CANCELED: '已取消',
  SUCCEEDED: '已完成',
  FAILED: '发布失败',
  ROLLING_BACK: '回滚中',
  ROLLED_BACK: '已回滚',
}

export const rolloutMemberStatusLabels: Record<AgentRolloutMemberStatus, string> = {
  PENDING: '等待进入批次',
  QUEUED: '等待 Agent 领取',
  ACCEPTED: '等待版本确认',
  CONFIRMED: '版本已确认',
  FAILED: '更新失败',
  CANCELED: '已取消',
  ROLLBACK_PENDING: '等待回滚批次',
  ROLLBACK_QUEUED: '等待领取回滚',
  ROLLBACK_ACCEPTED: '等待回滚确认',
  ROLLBACK_CONFIRMED: '回滚已确认',
  ROLLBACK_FAILED: '回滚失败',
}

export function availableRolloutActions(rollout: Pick<AgentRollout, 'status' | 'rollbackStartedAt' | 'members'>): AgentRolloutAction[] {
  const canRollback = !rollout.rollbackStartedAt
    && rollout.members.some((member) => member.status === 'CONFIRMED')
  switch (rollout.status) {
    case 'DRAFT':
      return ['start', 'cancel']
    case 'RUNNING':
      return canRollback ? ['pause', 'cancel', 'rollback'] : ['pause', 'cancel']
    case 'PAUSED':
      return canRollback ? ['resume', 'cancel', 'rollback'] : ['resume', 'cancel']
    case 'ROLLING_BACK':
      return ['pause', 'cancel']
    case 'CANCELED':
    case 'SUCCEEDED':
    case 'FAILED':
      return canRollback ? ['rollback'] : []
    default:
      return []
  }
}

export function rolloutProgress(rollout: Pick<AgentRollout, 'members' | 'rollbackStartedAt' | 'rollbackTotal'>) {
  const rollback = Boolean(rollout.rollbackStartedAt)
  const confirmedStatus: AgentRolloutMemberStatus = rollback ? 'ROLLBACK_CONFIRMED' : 'CONFIRMED'
  const failedStatus: AgentRolloutMemberStatus = rollback ? 'ROLLBACK_FAILED' : 'FAILED'
  const activeStatuses = rollback
    ? new Set<AgentRolloutMemberStatus>(['ROLLBACK_QUEUED', 'ROLLBACK_ACCEPTED'])
    : new Set<AgentRolloutMemberStatus>(['QUEUED', 'ACCEPTED'])
  const participants = rollback
    ? rollout.members.filter((member) => member.status.startsWith('ROLLBACK_'))
    : rollout.members
  const total = rollback ? rollout.rollbackTotal ?? participants.length : participants.length
  const confirmed = participants.filter((member) => member.status === confirmedStatus).length
  const failed = participants.filter((member) => member.status === failedStatus).length
  const active = participants.filter((member) => activeStatuses.has(member.status)).length
  const percent = total === 0 ? 0 : Math.round(((confirmed + failed) / total) * 100)
  return { total, confirmed, failed, active, percent, rollback }
}

export function isStableAgentVersion(value: string): boolean {
  return /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(value.trim())
}
