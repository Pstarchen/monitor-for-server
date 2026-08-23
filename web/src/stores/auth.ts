import { defineStore } from 'pinia'
import { ref } from 'vue'
import { api, clearCsrf, refreshCsrf } from '@/lib/api'
import type { User } from '@/types'

export const useAuthStore = defineStore('auth', () => {
  const user = ref<User | null>(null)
  const initialized = ref(false)

  async function initialize() {
    if (initialized.value) return
    try {
      await refreshCsrf()
      user.value = (await api.get<User>('/auth/me')).data
    } catch {
      user.value = null
    } finally {
      initialized.value = true
    }
  }

  async function login(username: string, password: string, returnTo: string) {
    const csrf = await refreshCsrf()
    const response = await api.post<{ user: User; returnTo: string }>('/auth/login', { username, password, returnTo }, {
      headers: { [csrf.headerName]: csrf.token },
    })
    user.value = response.data.user
    initialized.value = true
    await refreshCsrf()
    return response.data.returnTo
  }

  async function logout() {
    await api.post('/auth/logout')
    user.value = null
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

  return { user, initialized, initialize, login, logout, updateProfile }
})
