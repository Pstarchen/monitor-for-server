import type { ControllerUpdatePhase } from '@/types'

export function shortRevision(revision?: string): string {
  const value = revision?.trim()
  if (!value) return '暂不可用'
  return value.length > 12 ? value.slice(0, 12) : value
}

export function shouldPollUpdate(state?: ControllerUpdatePhase): boolean {
  return state === 'CHECKING' || state === 'UPDATING'
}

export function updateStateText(state: ControllerUpdatePhase, updateAvailable: boolean): string {
  if (state === 'CHECKING') return '正在检查更新'
  if (state === 'UPDATING') return '正在更新并重启'
  if (state === 'ERROR') return '更新任务异常'
  return updateAvailable ? '发现可用更新' : '当前已是最新版本'
}

export function releaseSourceText(source?: string, cached = false): string {
  const value = source?.trim()
  if (!value) return cached ? '最后已知可用缓存' : '尚未确认'
  const label = value === 'local' ? '本地离线清单' : value === 'cache' ? '总控制品缓存' : value
  return cached ? `${label}（缓存）` : label
}

export function verificationText(value?: string): string {
  if (value === 'sha256') return 'SHA256 完整性校验'
  if (value === 'manifest-sha256') return '预置信任清单 + SHA256'
  if (value === 'github-api') return '发布平台元数据'
  return '尚未校验'
}

export function updatePhaseText(value?: string): string {
  return ({
    BACKUP: '更新前备份',
    BACKUP_FAILED: '备份失败',
    INCOMPATIBLE_VERSION: '主版本需人工评估',
    APPLYING: '镜像暂存与切换',
    FAILED: '更新失败',
    COMPLETE: '更新完成',
  } as Record<string, string>)[value ?? ''] ?? (value || '空闲')
}

export function rollbackStateText(value?: string): string {
  return ({ SUCCEEDED: '旧镜像已恢复', FAILED: '自动恢复失败', NOT_REQUIRED: '未触发' } as Record<string, string>)[value ?? ''] ?? '未触发'
}

export function databaseCompatibilityText(value?: string): string {
  return ({
    CURRENT: '当前版本已验证',
    NOT_EVALUATED: '尚未评估',
    MANUAL_REVIEW_REQUIRED: '需人工确认迁移兼容性',
  } as Record<string, string>)[value ?? ''] ?? '尚未评估'
}

export function updateTriggerText(value?: string): string {
  if (value === 'automatic') return '自动更新'
  if (value === 'manual') return '管理员手动执行'
  return '尚无更新任务'
}
