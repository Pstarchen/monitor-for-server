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
