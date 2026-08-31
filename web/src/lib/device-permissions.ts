import type { DevicePermission, User } from '@/types'

export type DevicePermissionAction = 'canView' | 'canManage' | 'canAlert' | 'canTask'

export function canUseDevice(
  user: User | null,
  permissions: DevicePermission[],
  deviceId: string,
  action: DevicePermissionAction,
) {
  if (!user || !deviceId) return false
  if (user.role === 'ADMIN') return true
  return Boolean(permissions.find((permission) => permission.deviceId === deviceId)?.[action])
}

export function normalizeDevicePermission(permission: DevicePermission): DevicePermission {
  const canView = permission.canView || permission.canManage || permission.canAlert || permission.canTask
  return { ...permission, canView }
}

export function applyDevicePermissionChange(
  permission: DevicePermission,
  action: DevicePermissionAction,
): DevicePermission {
  if (action === 'canView' && !permission.canView) {
    return { ...permission, canManage: false, canAlert: false, canTask: false }
  }
  return normalizeDevicePermission(permission)
}
