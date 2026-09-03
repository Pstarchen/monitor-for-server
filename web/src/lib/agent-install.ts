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

const controllerInstallerPath = '/api/setup/agent-installer'

function shellQuote(value: string): string {
  return `'${value.split("'").join("'\"'\"'")}'`
}

function powerShellQuote(value: string): string {
  return value.split("'").join("''")
}

function installerUrl(options: AgentInstallCommandOptions, checksum = false): string {
  return `${options.serverUrl}${controllerInstallerPath}?platform=${options.platform}${checksum ? '&format=sha256' : ''}`
}

function linuxCommand(options: AgentInstallCommandOptions): string {
  const diskArgs = options.diskMountpoints.map((value) => ` --disk ${shellQuote(value)}`).join('')
  const lightArgs = options.lightweight ? ' --skip-processes --skip-connections' : ''
  const processArgs = !options.lightweight && options.collectAllProcesses
    ? ` --all-processes --process-limit ${options.processCollectionLimit}`
    : ''
  const installArgs = `--interval ${options.collectionSeconds}s${diskArgs}${lightArgs}${processArgs}`
  const protocol = options.serverUrl.startsWith('https://') ? '=https' : '=http'
  const verifiedInstall = [
    'trap \'rm -f "$installer"\' EXIT',
    `curl -fL --max-redirs 0 --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 --proto ${shellQuote(protocol)} --proto-redir ${shellQuote(protocol)} ${shellQuote(installerUrl(options))} -o "$installer"`,
    `expected_sha=$(curl -fsSL --max-redirs 0 --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 --proto ${shellQuote(protocol)} --proto-redir ${shellQuote(protocol)} ${shellQuote(installerUrl(options, true))})`,
    `actual_sha=$(sha256sum "$installer" | awk '{print $1}')`,
    'test "$actual_sha" = "$expected_sha"',
    'chmod 700 "$installer"',
    `env XINGCHEN_SERVER=${shellQuote(options.serverUrl)} XINGCHEN_DEVICE_ID=${shellQuote(options.deviceId)} "$installer" ${installArgs}`,
  ].join(' && ')
  return `installer=$(mktemp "\${TMPDIR:-/tmp}/xingchen-agent.XXXXXX.sh") && (${verifiedInstall})`
}

function windowsCommand(options: AgentInstallCommandOptions): string {
  const diskArgs = options.diskMountpoints.map((value) => ` -DiskMountpoint '${powerShellQuote(value)}'`).join('')
  const lightArgs = options.lightweight ? ' -SkipProcesses -SkipConnections' : ''
  const processArgs = !options.lightweight && options.collectAllProcesses
    ? ` -CollectAllProcesses -ProcessCollectionLimit ${options.processCollectionLimit}`
    : ''
  const installArgs = `-ServerUrl '${powerShellQuote(options.serverUrl)}' -DeviceId '${powerShellQuote(options.deviceId)}' -Interval '${options.collectionSeconds}s'${diskArgs}${lightArgs}${processArgs}`

  return [
    "$installer = Join-Path $env:TEMP ('xingchen-agent-' + [Guid]::NewGuid().ToString('N') + '.ps1')",
    `Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 0 '${powerShellQuote(installerUrl(options))}' -OutFile $installer`,
    'try {',
    `  $expectedHash = [string](Invoke-RestMethod -TimeoutSec 60 -MaximumRedirection 0 '${powerShellQuote(installerUrl(options, true))}')`,
    '  $expectedHash = $expectedHash.Trim().ToLowerInvariant()',
    '  $actualHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()',
    "  if ($expectedHash -notmatch '^[a-f0-9]{64}$' -or $actualHash -ne $expectedHash) { throw 'Agent 安装器 SHA256 校验失败' }",
    `  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer ${installArgs}`,
    "  if ($LASTEXITCODE -ne 0) { throw 'Agent 安装器执行失败' }",
    '} finally {',
    '  Remove-Item $installer -Force -ErrorAction SilentlyContinue',
    '}',
  ].join('\n')
}

export function buildAgentInstallCommand(options: AgentInstallCommandOptions): string {
  return options.platform === 'linux' ? linuxCommand(options) : windowsCommand(options)
}
