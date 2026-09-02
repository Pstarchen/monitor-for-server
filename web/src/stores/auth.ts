import { defineStore } from 'pinia'
import { ref } from 'vue'
import { api, clearCsrf, refreshCsrf } from '@/lib/api'
import { canUseDevice } from '@/lib/device-permissions'
import type { DevicePermission, User } from '@/types'

export const useAuthStore = defineStore('auth', () => {
  const user = ref<User | null>(null)
  const devicePermissions = ref<DevicePermission[]>([])
  const initialized = ref(false)

  async function initialize() {
    if (initialized.value) return
    try {
      const [, userResponse] = await Promise.all([
        refreshCsrf(),
        api.get<User>('/auth/me'),
      ])
      user.value = userResponse.data
      await loadDevicePermissions()
    } catch {
      user.value = null
      devicePermissions.value = []
    } finally {
      initialized.value = true
    }
  }

  async function login(username: string, password: string, returnTo: string) {
    const csrf = await refreshCsrf()
    const response = await api.post<{ user: User | null; returnTo: string; requiresTwoFactor: boolean }>('/auth/login', { username, password, returnTo }, {
      headers: { [csrf.headerName]: csrf.token },
    })
    if (response.data.requiresTwoFactor) {
      user.value = null
      devicePermissions.value = []
      initialized.value = false
    } else {
      user.value = response.data.user
      initialized.value = true
      await Promise.all([loadDevicePermissions(), refreshCsrf()])
    }
    if (response.data.requiresTwoFactor) await refreshCsrf()
    return { returnTo: response.data.returnTo, requiresTwoFactor: response.data.requiresTwoFactor }
  }

  async function verifyTwoFactor(code: string, returnTo: string) {
    const response = await api.post<{ user: User; returnTo: string; requiresTwoFactor: false }>('/auth/2fa/verify', { code, returnTo })
    user.value = response.data.user
    initialized.value = true
    await Promise.all([loadDevicePermissions(), refreshCsrf()])
    return response.data.returnTo
  }

  async function reload() {
    try {
      user.value = (await api.get<User>('/auth/me')).data
      await loadDevicePermissions()
    } catch {
      user.value = null
      devicePermissions.value = []
    }
    initialized.value = true
    return user.value
  }

  async function logout() {
    await api.post('/auth/logout')
    user.value = null
    devicePermissions.value = []
    clearCsrf()
  }

  async function updateProfile(displayName: string, currentPassword: string, newPassword: string) {
    const response = await api.put<User>('/auth/profile', {
      displayName,
      currentPassword: currentPassword || null,
      newPassword: newPassword || null,
    })
    user.value = response.data
    await refreshCsrf()
    return response.data
  }

  async function loadDevicePermissions() {
    if (!user.value) {
      devicePermissions.value = []
      return
    }
    if (user.value.role === 'ADMIN') {
      devicePermissions.value = []
      return
    }
    try {
      devicePermissions.value = (await api.get<DevicePermission[]>('/device-access/me')).data
    } catch {
      devicePermissions.value = []
    }
  }

  const canViewDevice = (deviceId: string) => canUseDevice(user.value, devicePermissions.value, deviceId, 'canView')
  const canManageDevice = (deviceId: string) => canUseDevice(user.value, devicePermissions.value, deviceId, 'canManage')
  const canManageAlerts = (deviceId: string) => canUseDevice(user.value, devicePermissions.value, deviceId, 'canAlert')
  const canRunTasks = (deviceId: string) => canUseDevice(user.value, devicePermissions.value, deviceId, 'canTask')

  return { user, devicePermissions, initialized, initialize, login, verifyTwoFactor, reload, logout, updateProfile, loadDevicePermissions, canViewDevice, canManageDevice, canManageAlerts, canRunTasks }
})
