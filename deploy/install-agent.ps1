[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ServerUrl,
    [Parameter(Mandatory = $true)] [string] $DeviceId,
    [ValidateSet('1s', '3s', '10s', '30s', '60s')] [string] $Interval = '3s',
    [string] $BinaryPath,
    [string] $RepositoryUrl = 'https://github.com/Pstarchen/monitor-for-server.git',
    [string[]] $MonitoredService = @(),
    [string[]] $DiskMountpoint = @(),
    [switch] $AllowInsecureHttp,
    [switch] $SkipProcesses,
    [switch] $SkipConnections
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

function Test-LocalHost([string] $HostName) {
    return $HostName -match '^(localhost|127\.0\.0\.1|\[::1\]|::1)(:\d+)?$'
}

function Test-ServerEndpoint([string] $Candidate) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri ($Candidate.TrimEnd('/') + '/healthz') -Method Get -TimeoutSec 10 -MaximumRedirection 0
        return $response.StatusCode -ge 200 -and $response.StatusCode -lt 300
    }
    catch {
        return $false
    }
}

function Resolve-ServerUrl {
    $raw = $ServerUrl.Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw '请提供监控平台域名或完整 HTTP(S) 地址。'
    }

    $parsed = $null
    if ([Uri]::TryCreate($raw, [UriKind]::Absolute, [ref] $parsed) -and ($parsed.Scheme -eq 'http' -or $parsed.Scheme -eq 'https')) {
        if ($parsed.UserInfo -or $parsed.AbsolutePath -ne '/' -or $parsed.Query -or $parsed.Fragment) {
            throw '监控平台地址不能包含用户信息、路径、查询参数或片段。'
        }
        $isLocal = Test-LocalHost $parsed.Authority
        if ($parsed.Scheme -eq 'http' -and -not $isLocal -and -not $AllowInsecureHttp) {
            throw '公网 Agent 地址必须使用 HTTPS；仅本地地址或显式指定 -AllowInsecureHttp 可使用 HTTP。'
        }
        return [pscustomobject]@{ Url = $raw; AllowInsecure = ($parsed.Scheme -eq 'http' -and -not $isLocal -and $AllowInsecureHttp) }
    }

    if ($raw -match '[\s/?#@]' -or $raw -match '://') {
        throw '监控平台地址必须是域名、域名:端口或完整 HTTP(S) 地址。'
    }
    $isLocal = Test-LocalHost $raw
    $httpsCandidate = "https://$raw"
    if (Test-ServerEndpoint $httpsCandidate) {
        return [pscustomobject]@{ Url = $httpsCandidate; AllowInsecure = $false }
    }
    $httpCandidate = "http://$raw"
    if (($isLocal -or $AllowInsecureHttp) -and (Test-ServerEndpoint $httpCandidate)) {
        return [pscustomobject]@{ Url = $httpCandidate; AllowInsecure = (-not $isLocal -and $AllowInsecureHttp) }
    }
    throw "无法访问 $raw 的 HTTPS 健康检查。请先配置有效证书；临时使用公网 HTTP 时显式指定 -AllowInsecureHttp。"
}

$resolvedServer = Resolve-ServerUrl
$ServerUrl = $resolvedServer.Url
$configAllowInsecureHttp = $resolvedServer.AllowInsecure

$projectRoot = Split-Path -Parent $PSScriptRoot
$temporaryBinary = $null
$temporarySource = $null
try {
    if ([string]::IsNullOrWhiteSpace($BinaryPath)) {
        $sourceRoot = $projectRoot
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'agent/go.mod'))) {
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                throw '未找到 Agent 源码。请安装 git，或通过 -BinaryPath 提供预编译 Agent。'
            }
            $temporarySource = Join-Path ([IO.Path]::GetTempPath()) ("guanlan-agent-source-{0}" -f [Guid]::NewGuid().ToString('N'))
            & git clone --depth 1 --filter=blob:none --sparse $RepositoryUrl $temporarySource
            if ($LASTEXITCODE -ne 0) { throw 'Agent 源码下载失败。' }
            & git -C $temporarySource sparse-checkout set agent
            if ($LASTEXITCODE -ne 0) { throw 'Agent 源码准备失败。' }
            $sourceRoot = $temporarySource
        }
        if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
            throw '未提供 -BinaryPath 时需要 Go 1.24+；也可以指定预编译 Agent。'
        }
        $temporaryBinary = Join-Path ([IO.Path]::GetTempPath()) ("guanlan-agent-{0}.exe" -f [Guid]::NewGuid().ToString('N'))
        Push-Location (Join-Path $sourceRoot 'agent')
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
        allow_insecure_http = $configAllowInsecureHttp
        monitored_services = $MonitoredService
        skip_process_collection = $SkipProcesses.IsPresent
        skip_connection_count = $SkipConnections.IsPresent
        disk_mountpoints = $DiskMountpoint
    }
    # Windows PowerShell 5 writes a BOM for -Encoding UTF8; Go's JSON decoder rejects it.
    $configJson = $config | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($configPath, $configJson, [Text.UTF8Encoding]::new($false))
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
    if ($temporarySource -and (Test-Path -LiteralPath $temporarySource)) {
        Remove-Item -LiteralPath $temporarySource -Recurse -Force
    }
}
