[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ServerUrl,
    [Parameter(Mandatory = $true)] [string] $DeviceId,
    [ValidateSet('1s', '3s', '10s')] [string] $Interval = '3s',
    [string] $BinaryPath,
    [string[]] $MonitoredService = @()
)

$ErrorActionPreference = 'Stop'
$serviceName = 'GuanlanAgent'
$installDir = Join-Path $env:ProgramFiles 'GuanlanMonitor'
$dataDir = Join-Path $env:ProgramData 'GuanlanMonitor'
$configPath = Join-Path $dataDir 'agent.json'
$agentKey = $env:GUANLAN_AGENT_KEY

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '请以管理员身份运行此安装脚本。'
}
if ([string]::IsNullOrWhiteSpace($agentKey)) {
    throw '请通过 GUANLAN_AGENT_KEY 环境变量提供一次性 Agent 密钥。'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$temporaryBinary = $null
try {
    if ([string]::IsNullOrWhiteSpace($BinaryPath)) {
        if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
            throw '未提供 -BinaryPath 时需要安装 Go。'
        }
        $temporaryBinary = Join-Path ([IO.Path]::GetTempPath()) ("guanlan-agent-{0}.exe" -f [Guid]::NewGuid().ToString('N'))
        Push-Location (Join-Path $projectRoot 'agent')
        try {
            $env:CGO_ENABLED = '0'
            & go build -trimpath -ldflags '-s -w' -o $temporaryBinary ./cmd/agent
            if ($LASTEXITCODE -ne 0) { throw 'Agent 编译失败。' }
        }
        finally {
            Pop-Location
            Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue
        }
        $BinaryPath = $temporaryBinary
    }

    $resolvedBinary = (Resolve-Path -LiteralPath $BinaryPath).Path
    New-Item -ItemType Directory -Force -Path $installDir, $dataDir, (Join-Path $dataDir 'spool') | Out-Null
    $targetBinary = Join-Path $installDir 'guanlan-agent.exe'

    $existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($existing -and $existing.Status -ne 'Stopped') {
        Stop-Service -Name $serviceName -Force
        $existing.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
    }
    Copy-Item -LiteralPath $resolvedBinary -Destination $targetBinary -Force

    $config = [ordered]@{
        server_url = $ServerUrl.TrimEnd('/')
        device_id = $DeviceId
        agent_key = $agentKey
        interval = $Interval
        request_timeout = '10s'
        spool_dir = (Join-Path $dataDir 'spool')
        max_buffered_reports = 10000
        allow_insecure_http = $false
        monitored_services = $MonitoredService
    }
    $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8
    & icacls.exe $configPath /inheritance:r /grant:r 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '无法收紧 Agent 配置文件权限。' }

    $command = ('"{0}" -config "{1}"' -f $targetBinary, $configPath)
    if ($existing) {
        & sc.exe config $serviceName binPath= $command start= auto | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '无法更新 Windows 服务。' }
    }
    else {
        New-Service -Name $serviceName -DisplayName 'Guanlan Server Monitoring Agent' -BinaryPathName $command -StartupType Automatic -Description 'Collects server metrics for Guanlan Monitor.' | Out-Null
    }
    Start-Service -Name $serviceName
    Write-Host 'Guanlan Agent 已安装并启动。可运行 Get-Service GuanlanAgent 查看状态。'
}
finally {
    Remove-Item Env:GUANLAN_AGENT_KEY -ErrorAction SilentlyContinue
    if ($temporaryBinary -and (Test-Path -LiteralPath $temporaryBinary)) {
        Remove-Item -LiteralPath $temporaryBinary -Force
    }
}
