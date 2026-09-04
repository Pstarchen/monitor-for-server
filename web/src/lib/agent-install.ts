export type AgentInstallPlatform = 'linux' | 'windows'

export interface AgentInstallCommandOptions {
  platform: AgentInstallPlatform
  serverUrl: string
  deviceId: string
  collectionSeconds: number
  diskMountpoints: string[]
  lightweight: boolean
  collectAllProcesses: boolean
  processCollectionLimit: number
}

const controllerBootstrapPath = '/api/setup/agent-bootstrap'
const deviceIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const diskValuePattern = /^[A-Za-z0-9_ ./\\:()+,@-]+$/
const collectionIntervals = new Set([1, 3, 10, 30, 60])

function shellQuote(value: string): string {
  return `'${value.split("'").join("'\"'\"'")}'`
}

function powerShellQuote(value: string): string {
  return `'${value.split("'").join("''")}'`
}

function validatedOrigin(value: string): URL {
  const parsed = new URL(value)
  if (!['http:', 'https:'].includes(parsed.protocol)
    || parsed.username || parsed.password || parsed.pathname !== '/' || parsed.search || parsed.hash) {
    throw new Error('Controller 地址必须是 HTTP 或 HTTPS origin')
  }
  return parsed
}

function validDiskMountpoint(platform: AgentInstallPlatform, value: string): boolean {
  if (!value || value.length > 256 || value.trim() !== value || !diskValuePattern.test(value)) return false
  if (platform === 'linux') {
    return value.startsWith('/') && !value.includes('\\') && !value.split('/').some((part) => part === '.' || part === '..')
  }
  const absoluteDrivePath = /^[A-Za-z]:\\/.test(value)
  const uncPath = /^\\\\[^\\]+\\[^\\]+/.test(value)
  return (absoluteDrivePath || uncPath) && !value.split('\\').some((part) => part === '..')
}

function validateOptions(options: AgentInstallCommandOptions): void {
  if (!deviceIdPattern.test(options.deviceId)) throw new Error('Agent 设备 ID 格式无效')
  if (!collectionIntervals.has(options.collectionSeconds)) throw new Error('Agent 采集周期无效')
  if (options.diskMountpoints.length > 16 || options.diskMountpoints.some((value) => !validDiskMountpoint(options.platform, value))) {
    throw new Error('Agent 磁盘白名单格式无效')
  }
  if (options.lightweight && options.collectAllProcesses) throw new Error('轻量采集不能同时启用完整进程采集')
  if (options.collectAllProcesses
    && (!Number.isInteger(options.processCollectionLimit) || options.processCollectionLimit < 1 || options.processCollectionLimit > 256)) {
    throw new Error('Agent 进程上限必须是 1 到 256 的整数')
  }
}

function bootstrapUrl(options: AgentInstallCommandOptions): URL {
  const origin = validatedOrigin(options.serverUrl)
  validateOptions(options)
  const result = new URL(controllerBootstrapPath, origin)
  result.searchParams.set('platform', options.platform)
  result.searchParams.set('deviceId', options.deviceId)
  result.searchParams.set('interval', `${options.collectionSeconds}s`)
  for (const mountpoint of options.diskMountpoints) result.searchParams.append('disk', mountpoint)
  if (options.lightweight) result.searchParams.set('lightweight', 'true')
  if (options.collectAllProcesses) {
    result.searchParams.set('collectAllProcesses', 'true')
    result.searchParams.set('processLimit', String(options.processCollectionLimit))
  }
  return result
}

export function buildAgentInstallCommand(options: AgentInstallCommandOptions): string {
  const url = bootstrapUrl(options)
  if (options.platform === 'linux') {
    const protocol = url.protocol === 'https:' ? '=https' : '=http'
    return `curl -fsSL --max-redirs 0 --proto ${shellQuote(protocol)} --proto-redir ${shellQuote(protocol)} ${shellQuote(url.toString())} | bash`
  }
  return `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-RestMethod -TimeoutSec 60 -MaximumRedirection 0 -Uri ${powerShellQuote(url.toString())} | Invoke-Expression"`
}
