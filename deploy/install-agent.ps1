[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ServerUrl,
    [Parameter(Mandatory = $true)] [string] $DeviceId,
    [ValidateSet('1s', '3s', '10s', '30s', '60s')] [string] $Interval = '3s',
    [string] $BinaryPath,
    [string[]] $RepositoryUrl = @(
        'https://gitee.com/starchen520/monitor-for-server.git',
        'https://github.com/Pstarchen/monitor-for-server.git'
    ),
    [string] $SourceRef = 'main',
    [string[]] $MonitoredService = @(),
    [string[]] $MonitoredProcess = @(),
    [string[]] $DiskMountpoint = @(),
    [string[]] $LogPath = @(),
    [string[]] $IntegrityPath = @(),
    [switch] $AllowInsecureHttp,
    [switch] $AllowCommandExecution,
    [switch] $AllowFileOperations,
    [switch] $NoAutoUpdate,
    [switch] $SkipProcesses,
    [switch] $CollectAllProcesses,
    [ValidateRange(1, 256)] [int] $ProcessCollectionLimit = 256,
    [switch] $SkipConnections,
    [switch] $SkipPorts,
    [ValidateRange(1, 512)] [int] $PortCollectionLimit = 512,
    [switch] $SkipContainers,
    [ValidateRange(1, 100)] [int] $ContainerCollectionLimit = 100
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
if ($RepositoryUrl.Count -eq 0 -or @($RepositoryUrl | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw 'Agent 源码仓库地址不能为空。'
}
if ($SourceRef -notmatch '^[a-zA-Z0-9._/-]+$' -or $SourceRef.StartsWith('-') -or $SourceRef.Contains('..')) {
    throw 'Agent 源码 Git ref 无效。'
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
        if ($parsed.Scheme -eq 'http' -and -not $isLocal) {
            Write-Warning "Agent 将通过未加密的 HTTP 连接 $raw。生产环境建议配置 HTTPS。"
        }
        return [pscustomobject]@{ Url = $raw; AllowInsecure = ($parsed.Scheme -eq 'http' -and -not $isLocal) }
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
    if (Test-ServerEndpoint $httpCandidate) {
        if (-not $isLocal) {
            Write-Warning "未检测到可用 HTTPS，已回退到未加密 HTTP：$httpCandidate"
        }
        return [pscustomobject]@{ Url = $httpCandidate; AllowInsecure = (-not $isLocal) }
    }
    throw "无法访问 $raw 的 HTTPS 或 HTTP 健康检查。请检查 DNS、端口和服务状态。"
}

function Install-AgentUpdater {
    if ($NoAutoUpdate) { return }
    $updaterPath = Join-Path $dataDir 'update-agent.ps1'
    $taskName = 'GuanlanAgentUpdate'
    $repositoryList = ($RepositoryUrl | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', '
    $script = @"
`$ErrorActionPreference = 'SilentlyContinue'
if (-not (Get-Command git -ErrorAction SilentlyContinue) -or -not (Get-Command go -ErrorAction SilentlyContinue)) { exit 0 }
`$repositories = @($repositoryList)
`$temp = Join-Path ([IO.Path]::GetTempPath()) ('guanlan-agent-update-' + [Guid]::NewGuid().ToString('N'))
try {
    `$cloned = `$false
    foreach (`$repository in `$repositories) {
        if (Test-Path -LiteralPath `$temp) { Remove-Item -LiteralPath `$temp -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host "正在尝试 Agent 源码仓库：`$repository ($SourceRef)"
        & git clone --branch '$SourceRef' --depth 1 --filter=blob:none --sparse `$repository `$temp | Out-Null
        if (`$LASTEXITCODE -eq 0) {
            & git -C `$temp sparse-checkout set agent | Out-Null
            if (`$LASTEXITCODE -eq 0) { `$cloned = `$true; break }
        }
    }
    if (-not `$cloned) { Write-Error 'GitHub 与 Gitee Agent 源码均不可用。'; exit 1 }
    `$built = Join-Path `$temp 'guanlan-agent.exe'
    Push-Location (Join-Path `$temp 'agent')
    try { `$env:CGO_ENABLED = '0'; & go build -trimpath -ldflags '-s -w' -o `$built ./cmd/agent } finally { Pop-Location; Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue }
    if (`$LASTEXITCODE -ne 0) { exit 0 }
    Stop-Service -Name '$serviceName' -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath `$built -Destination '$targetBinary' -Force
    Start-Service -Name '$serviceName'
} finally { if (Test-Path -LiteralPath `$temp) { Remove-Item -LiteralPath `$temp -Recurse -Force -ErrorAction SilentlyContinue } }
"@
    [IO.File]::WriteAllText($updaterPath, $script, [Text.UTF8Encoding]::new($false))
    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updaterPath`""
    $trigger = New-ScheduledTaskTrigger -Daily -At 4:15am
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -RunLevel Highest -Force | Out-Null
}

function Get-AgentSource([string] $Destination) {
    foreach ($repository in $RepositoryUrl) {
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
        Write-Host "正在尝试 Agent 源码仓库：$repository ($SourceRef)"
        & git clone --branch $SourceRef --depth 1 --filter=blob:none --sparse $repository $Destination
        if ($LASTEXITCODE -eq 0) {
            & git -C $Destination sparse-checkout set agent
            if ($LASTEXITCODE -eq 0) { return $true }
        }
    }
    return $false
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
            if (-not (Get-AgentSource $temporarySource)) { throw 'GitHub 与 Gitee Agent 源码均不可用。' }
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
        allow_command_execution = $AllowCommandExecution.IsPresent
        allow_file_operations = $AllowFileOperations.IsPresent
        monitored_services = $MonitoredService
        monitored_processes = $MonitoredProcess
        skip_process_collection = $SkipProcesses.IsPresent
        collect_all_processes = $CollectAllProcesses.IsPresent
        process_collection_limit = $ProcessCollectionLimit
        skip_connection_count = $SkipConnections.IsPresent
        skip_port_collection = $SkipPorts.IsPresent
        port_collection_limit = $PortCollectionLimit
        skip_container_collection = $SkipContainers.IsPresent
        container_collection_limit = $ContainerCollectionLimit
        disk_mountpoints = $DiskMountpoint
        log_paths = $LogPath
        integrity_paths = $IntegrityPath
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
        New-Service -Name $serviceName -DisplayName 'Xingchen Server Monitoring Agent' -BinaryPathName $command -StartupType Automatic -Description 'Collects server metrics for Xingchen Monitor.' | Out-Null
    }
    Start-Service -Name $serviceName
    Install-AgentUpdater
    Write-Host '星辰监控 Agent 已安装并启动。可运行 Get-Service GuanlanAgent 查看状态。'
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
