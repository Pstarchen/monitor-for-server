export function percent(value: number | null | undefined): string {
  return `${Number(value ?? 0).toFixed(1)}%`
}

export function bytes(value: number | null | undefined): string {
  const size = Math.max(0, Number(value ?? 0))
  if (size < 1024) return `${size.toFixed(0)} B`
  const units = ['KB', 'MB', 'GB', 'TB', 'PB']
  let current = size / 1024
  let index = 0
  while (current >= 1024 && index < units.length - 1) {
    current /= 1024
    index += 1
  }
  return `${current.toFixed(current >= 100 ? 0 : 1)} ${units[index]}`
}

export function rate(value: number | null | undefined): string {
  return `${bytes(value)}/s`
}

export function uptime(value: number | null | undefined): string {
  const seconds = Math.max(0, Math.floor(Number(value ?? 0)))
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor((seconds % 86400) / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)
  if (days > 0) return `${days} 天 ${hours} 小时`
  if (hours > 0) return `${hours} 小时 ${minutes} 分钟`
  return `${minutes} 分钟`
}

export function dateTime(value: string | null | undefined): string {
  if (!value) return '--'
  return new Intl.DateTimeFormat('zh-CN', { dateStyle: 'short', timeStyle: 'medium' }).format(new Date(value))
}

export function relativeTime(value: string | null | undefined): string {
  if (!value) return '尚未连接'
  const seconds = Math.max(0, Math.floor((Date.now() - new Date(value).getTime()) / 1000))
  if (seconds < 60) return `${seconds} 秒前`
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟前`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} 小时前`
  return `${Math.floor(seconds / 86400)} 天前`
}

export function safeLocalPath(value: unknown): string {
  if (typeof value !== 'string' || !value.startsWith('/') || value.startsWith('//') || value.includes('://')) return '/dashboard'
  return value
}
