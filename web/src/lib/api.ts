import axios from 'axios'

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

export function errorMessage(error: unknown): string {
  if (axios.isAxiosError(error)) {
    return (error.response?.data as { message?: string } | undefined)?.message ?? '请求失败，请稍后重试'
  }
  return error instanceof Error ? error.message : '请求失败，请稍后重试'
}
