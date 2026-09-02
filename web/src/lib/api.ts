import axios from 'axios'
import type { SetupStatus } from '@/types'

export const api = axios.create({
  baseURL: '/api',
  timeout: 15_000,
  withCredentials: true,
  withXSRFToken: false,
})

let csrfHeaderName = 'X-XSRF-TOKEN'
let csrfToken = ''
let setupStatusCache: SetupStatus | null = null
let setupStatusCacheExpiresAt = 0
let setupStatusRequest: Promise<SetupStatus> | null = null

api.interceptors.request.use((config) => {
  const method = config.method?.toLowerCase()
  if (csrfToken && method && !['get', 'head', 'options'].includes(method)) {
    config.headers.set(csrfHeaderName, csrfToken)
  }
  return config
})

export async function refreshCsrf(): Promise<{ headerName: string; token: string }> {
  const response = await api.get<{ headerName: string; token: string }>('/auth/csrf')
  csrfHeaderName = response.data.headerName
  csrfToken = response.data.token
  return response.data
}

export function clearCsrf(): void {
  csrfToken = ''
}

export async function getSetupStatus(force = false): Promise<SetupStatus> {
  if (!force && setupStatusCache && Date.now() < setupStatusCacheExpiresAt) return setupStatusCache
  if (setupStatusRequest) return setupStatusRequest
  setupStatusRequest = api.get<SetupStatus>('/setup/status').then((response) => {
    setupStatusCache = response.data
    setupStatusCacheExpiresAt = Date.now() + 1_000
    return response.data
  }).finally(() => {
    setupStatusRequest = null
  })
  return setupStatusRequest
}

export function invalidateSetupStatusCache(): void {
  setupStatusCache = null
  setupStatusCacheExpiresAt = 0
  setupStatusRequest = null
}

export function errorMessage(error: unknown): string {
  if (axios.isAxiosError(error)) {
    return (error.response?.data as { message?: string } | undefined)?.message ?? '请求失败，请稍后重试'
  }
  return error instanceof Error ? error.message : '请求失败，请稍后重试'
}
