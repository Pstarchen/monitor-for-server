import type { SetupStatus } from '@/types'

export type SetupRouteDestination = 'setup' | 'login' | null

export function setupRouteRedirect(status: SetupStatus, targetName: unknown, allowPublicStatus = false): SetupRouteDestination {
  if (allowPublicStatus && targetName === 'public-status') return null
  if (!status.configured) return targetName === 'setup' ? null : 'setup'
  if (status.state === 'error') return targetName === 'setup' ? null : 'setup'
  if (targetName === 'setup') return 'login'
  if (status.state !== 'configured' && targetName !== 'login') return 'login'
  return null
}

export function setupIsReady(status: SetupStatus): boolean {
  return status.configured && status.state === 'configured'
}
