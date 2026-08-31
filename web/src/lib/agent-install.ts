export type AgentInstallPlatform = 'linux' | 'windows'
export type AgentInstallSource = 'controller' | 'gitee'

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
  return `${options.serverUrl}${controllerInstallerPath}?platform=${options.platform}`
}

function linuxCommand(options: AgentInstallCommandOptions): string {
  const diskArgs = options.diskMountpoints.map((value) => ` --disk ${shellQuote(value)}`).join('')
  const lightArgs = options.lightweight ? ' --skip-processes --skip-connections' : ''
  const processArgs = !options.lightweight && options.collectAllProcesses
    ? ` --all-processes --process-limit ${options.processCollectionLimit}`
    : ''
  const installArgs = `--server-url ${shellQuote(options.serverUrl)} --device-id ${shellQuote(options.deviceId)} --interval ${options.collectionSeconds}s${diskArgs}${lightArgs}${processArgs}`
  const key = shellQuote(options.agentKey)

  return [
    `curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 ${shellQuote(installerUrl(options))} -o xingchen-agent.sh &&`,
    'chmod +x xingchen-agent.sh &&',
    'if [ "$(id -u)" -eq 0 ]; then',
    `  env GUANLAN_AGENT_KEY=${key} ./xingchen-agent.sh ${installArgs}`,
    'elif command -v sudo >/dev/null 2>&1; then',
    `  sudo env GUANLAN_AGENT_KEY=${key} ./xingchen-agent.sh ${installArgs}`,
    'else',
    "  echo '请以 root 身份运行，或安装 sudo 后重试。' >&2; exit 1",
    'fi',
  ].join('\n')
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
    '$previousAgentKey = $env:GUANLAN_AGENT_KEY',
    'try {',
    `  $env:GUANLAN_AGENT_KEY = '${powerShellQuote(options.agentKey)}'`,
    `  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer ${installArgs}`,
    "  if ($LASTEXITCODE -ne 0) { throw 'Agent 安装器执行失败' }",
    '} finally {',
    '  if ($null -eq $previousAgentKey) { Remove-Item Env:GUANLAN_AGENT_KEY -ErrorAction SilentlyContinue } else { $env:GUANLAN_AGENT_KEY = $previousAgentKey }',
    '  Remove-Item $installer -Force -ErrorAction SilentlyContinue',
    '}',
  ].join('\n')
}

export function buildAgentInstallCommand(options: AgentInstallCommandOptions): string {
  return options.platform === 'linux' ? linuxCommand(options) : windowsCommand(options)
}
