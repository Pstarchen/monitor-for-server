import { describe, expect, it } from 'vitest'
import { applyDevicePermissionChange, canUseDevice, normalizeDevicePermission } from './device-permissions'
import type { DevicePermission, User } from '@/types'

const viewer: User = {
  id: 2,
  username: 'viewer',
  displayName: 'Viewer',
  role: 'VIEWER',
  enabled: true,
  twoFactorEnabled: false,
  createdAt: '2026-01-01T00:00:00Z',
}
const assigned: DevicePermission[] = [{
  deviceId: 'server-a',
  deviceName: 'Server A',
  canView: true,
  canManage: false,
  canAlert: true,
  canTask: false,
}]

describe('device permissions', () => {
  it('checks each action independently for non-admin users', () => {
    expect(canUseDevice(viewer, assigned, 'server-a', 'canView')).toBe(true)
    expect(canUseDevice(viewer, assigned, 'server-a', 'canAlert')).toBe(true)
    expect(canUseDevice(viewer, assigned, 'server-a', 'canManage')).toBe(false)
    expect(canUseDevice(viewer, assigned, 'server-b', 'canView')).toBe(false)
  })

  it('keeps administrators unrestricted', () => {
    expect(canUseDevice({ ...viewer, role: 'ADMIN' }, [], 'server-b', 'canTask')).toBe(true)
  })

  it('makes action permissions imply visibility', () => {
    expect(normalizeDevicePermission({ ...assigned[0], canView: false }).canView).toBe(true)
  })

  it('keeps the permission matrix dependencies consistent', () => {
    expect(applyDevicePermissionChange({ ...assigned[0], canView: false }, 'canView')).toMatchObject({
      canView: false,
      canManage: false,
      canAlert: false,
      canTask: false,
    })
    expect(applyDevicePermissionChange({ ...assigned[0], canView: false, canTask: true }, 'canTask').canView).toBe(true)
  })
})
