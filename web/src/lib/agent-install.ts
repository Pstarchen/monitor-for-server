export type AgentInstallPlatform = 'linux' | 'windows'
export type AgentInstallSource = 'controller' | 'gitee' | 'github'

export interface AgentInstallCommandOptions {
  platform: AgentInstallPlatform
  source: AgentInstallSource
  serverUrl: string
  deviceId: string
  agentKey: string
  collectionSeconds: number
  diskMountpoints: string[]
  lightweight: boolean
  collectAllProcesses: boolean
  processCollectionLimit: number
}

const controllerInstallerPath = '/api/setup/agent-installer'
const giteeInstallerRoot = 'https://gitee.com/starchen520/monitor-for-server/raw/main/deploy/install-agent'
const githubInstallerRoot = 'https://raw.githubusercontent.com/Pstarchen/monitor-for-server/main/deploy/install-agent'

function shellQuote(value: string): string {
  return `'${value.split("'").join("'\"'\"'")}'`
}

function powerShellQuote(value: string): string {
  return value.split("'").join("''")
}

function installerUrl(options: AgentInstallCommandOptions): string {
  if (options.source === 'gitee') {
    return `${giteeInstallerRoot}.${options.platform === 'linux' ? 'sh' : 'ps1'}`
  }
  if (options.source === 'github') {
    return `${githubInstallerRoot}.${options.platform === 'linux' ? 'sh' : 'ps1'}`
  }
  return `${options.serverUrl}${controllerInstallerPath}?platform=${options.platform}`
}

function linuxCommand(options: AgentInstallCommandOptions): string {
  const diskArgs = options.diskMountpoints.map((value) => ` --disk ${shellQuote(value)}`).join('')
  const lightArgs = options.lightweight ? ' --skip-processes --skip-connections' : ''
  const processArgs = !options.lightweight && options.collectAllProcesses
    ? ` --all-processes --process-limit ${options.processCollectionLimit}`
    : ''
  const installArgs = `--interval ${options.collectionSeconds}s${diskArgs}${lightArgs}${processArgs}`
  const key = shellQuote(options.agentKey)

  return [
    `curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 ${shellQuote(installerUrl(options))} -o xingchen-agent.sh`,
    'chmod +x xingchen-agent.sh',
    `env XINGCHEN_SERVER=${shellQuote(options.serverUrl)} XINGCHEN_DEVICE_ID=${shellQuote(options.deviceId)} XINGCHEN_AGENT_KEY=${key} ./xingchen-agent.sh ${installArgs}`,
  ].join(' && ')
}

function windowsCommand(options: AgentInstallCommandOptions): string {
  const diskArgs = options.diskMountpoints.map((value) => ` -DiskMountpoint '${powerShellQuote(value)}'`).join('')
  const lightArgs = options.lightweight ? ' -SkipProcesses -SkipConnections' : ''
  const processArgs = !options.lightweight && options.collectAllProcesses
    ? ` -CollectAllProcesses -ProcessCollectionLimit ${options.processCollectionLimit}`
    : ''
  const installArgs = `-ServerUrl '${powerShellQuote(options.serverUrl)}' -DeviceId '${powerShellQuote(options.deviceId)}' -Interval '${options.collectionSeconds}s'${diskArgs}${lightArgs}${processArgs}`

  return [
    "$installer = Join-Path $env:TEMP 'xingchen-agent.ps1'",
    `Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 '${powerShellQuote(installerUrl(options))}' -OutFile $installer`,
    '$previousAgentKey = $env:XINGCHEN_AGENT_KEY',
    'try {',
    `  $env:XINGCHEN_AGENT_KEY = '${powerShellQuote(options.agentKey)}'`,
    `  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer ${installArgs}`,
    "  if ($LASTEXITCODE -ne 0) { throw 'Agent 安装器执行失败' }",
    '} finally {',
    '  if ($null -eq $previousAgentKey) { Remove-Item Env:XINGCHEN_AGENT_KEY -ErrorAction SilentlyContinue } else { $env:XINGCHEN_AGENT_KEY = $previousAgentKey }',
    '  Remove-Item $installer -Force -ErrorAction SilentlyContinue',
    '}',
  ].join('\n')
}

export function buildAgentInstallCommand(options: AgentInstallCommandOptions): string {
  return options.platform === 'linux' ? linuxCommand(options) : windowsCommand(options)
}
