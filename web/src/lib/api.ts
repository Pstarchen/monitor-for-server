import axios from 'axios'
import type { SetupRequest, SetupStatus } from '@/types'

export const api = axios.create({
  baseURL: '/api',
  timeout: 15_000,
  withCredentials: true,
  withXSRFToken: false,
})

let csrfHeaderName = 'X-XSRF-TOKEN'
let csrfToken = ''

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

export async function getSetupStatus(): Promise<SetupStatus> {
  return (await api.get<SetupStatus>('/setup/status')).data
}

export async function testSetupDatabase(input: Pick<SetupRequest, 'mysqlAdminHost' | 'mysqlAdminPort' | 'databaseName' | 'mysqlAdminUsername' | 'mysqlAdminPassword'>): Promise<void> {
  await api.post('/setup/test-database', {
    host: input.mysqlAdminHost,
    port: input.mysqlAdminPort,
    databaseName: input.databaseName,
    username: input.mysqlAdminUsername,
    password: input.mysqlAdminPassword,
  })
}

export function errorMessage(error: unknown): string {
  if (axios.isAxiosError(error)) {
    return (error.response?.data as { message?: string } | undefined)?.message ?? '请求失败，请稍后重试'
  }
  return error instanceof Error ? error.message : '请求失败，请稍后重试'
}
