import { describe, expect, it } from 'vitest'
import { canTestPushKit, canValidatePushKit, pushKitForm, pushKitState } from './push-kit-settings'
import type { PushKitInstallation, PushKitSettings } from '@/types'

const configured: PushKitSettings = {
  enabled: true,
  configured: true,
  source: 'DATABASE',
  projectId: '123456789',
  keyId: 'key-id',
  subAccount: 'sub-account',
  privateKeyConfigured: true,
  category: 'MARKETING',
  ttlSeconds: 86400,
  batchSize: 50,
  maxAttempts: 5,
}

const installation: PushKitInstallation = {
  id: 'installation-1',
  platform: 'HARMONYOS',
  tokenSuffix: '12345678',
  appVersion: '1.0.0',
  deviceModel: 'Phone',
  enabled: true,
  lastRegisteredAt: '2026-09-01T00:00:00Z',
  lastTestAt: null,
  createdAt: '2026-09-01T00:00:00Z',
  updatedAt: '2026-09-01T00:00:00Z',
}

describe('Push Kit settings helpers', () => {
  it('maps public settings without inventing a private key value', () => {
    expect(pushKitForm(configured)).toMatchObject({
      enabled: true,
      privateKey: '',
      clearPrivateKey: false,
      ttlSeconds: 86400,
    })
  })

  it('reflects disabled, incomplete, and ready states', () => {
    expect(pushKitState({ ...configured, enabled: false })).toBe('OFFLINE')
    expect(pushKitState({ ...configured, configured: false })).toBe('PENDING')
    expect(pushKitState(configured)).toBe('ONLINE')
  })

  it('blocks validation and device tests while settings are unsaved', () => {
    expect(canValidatePushKit(configured, true)).toBe(false)
    expect(canTestPushKit(configured, installation, true)).toBe(false)
    expect(canValidatePushKit(configured, false)).toBe(true)
    expect(canTestPushKit(configured, installation, false)).toBe(true)
  })

  it('blocks tests for an unavailable installation', () => {
    expect(canTestPushKit(configured, { ...installation, enabled: false }, false)).toBe(false)
    expect(canTestPushKit(configured, { ...installation, tokenSuffix: null }, false)).toBe(false)
  })
})
