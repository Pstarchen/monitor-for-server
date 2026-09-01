import type { PushKitInstallation, PushKitSettings } from '@/types'

export interface PushKitForm {
  enabled: boolean
  projectId: string
  keyId: string
  subAccount: string
  privateKey: string
  clearPrivateKey: boolean
  category: string
  ttlSeconds: number
  batchSize: number
  maxAttempts: number
}

export function pushKitForm(settings: PushKitSettings): PushKitForm {
  return {
    enabled: settings.enabled,
    projectId: settings.projectId,
    keyId: settings.keyId,
    subAccount: settings.subAccount,
    privateKey: '',
    clearPrivateKey: false,
    category: settings.category,
    ttlSeconds: settings.ttlSeconds,
    batchSize: settings.batchSize,
    maxAttempts: settings.maxAttempts,
  }
}

export function pushKitState(settings: PushKitSettings) {
  if (!settings.enabled) return 'OFFLINE'
  return settings.configured ? 'ONLINE' : 'PENDING'
}

export function canValidatePushKit(settings: PushKitSettings, hasChanges: boolean) {
  return !hasChanges && settings.configured
}

export function canTestPushKit(settings: PushKitSettings, installation: PushKitInstallation, hasChanges: boolean) {
  return !hasChanges && settings.enabled && settings.configured
    && installation.enabled && Boolean(installation.tokenSuffix)
}
