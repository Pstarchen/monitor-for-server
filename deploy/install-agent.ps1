[CmdletBinding()]
param(
    [ValidateSet('install', 'update', 'rollback', 'list-versions', 'status', 'uninstall')] [string] $Action = 'install',
    [string] $ServerUrl,
    [string] $DeviceId,
    [ValidateSet('1s', '3s', '10s', '30s', '60s')] [string] $Interval = '3s',
    [string] $BinaryPath,
    [string[]] $RepositoryUrl = @(),
    [string] $SourceRef = 'main',
    [string] $Version,
    [ValidatePattern('^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$')] [string] $ReleaseRepo = 'Pstarchen/monitor-for-server',
    [string[]] $ReleaseBaseUrl = @(),
    [string[]] $ReleaseManifestUrl = @(),
    [switch] $AllowGitHubApi,
    [ValidateSet('public', 'internal', 'offline')] [string] $NetworkMode = $(if ($env:XINGCHEN_NETWORK_MODE) { $env:XINGCHEN_NETWORK_MODE } else { 'public' }),
    [switch] $AllowGitee,
    [switch] $Offline,
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
    [ValidateRange(1, 100)] [int] $ContainerCollectionLimit = 100,
    [switch] $Purge
)

$ErrorActionPreference = 'Stop'
$serviceName = 'XingchenAgent'
$installDir = Join-Path $env:ProgramFiles 'XingchenMonitor'
$dataDir = Join-Path $env:ProgramData 'XingchenMonitor'
$configPath = Join-Path $dataDir 'agent.json'
$binaryName = 'xingchen-agent.exe'
$legacyServiceName = 'GuanlanAgent'
$legacyInstallDir = Join-Path $env:ProgramFiles 'GuanlanMonitor'
$legacyDataDir = Join-Path $env:ProgramData 'GuanlanMonitor'
$legacyConfigPath = Join-Path $legacyDataDir 'agent.json'
$usingLegacyInstallation = $false
if ((Get-Service -Name $serviceName -ErrorAction SilentlyContinue) -eq $null -and ((Get-Service -Name $legacyServiceName -ErrorAction SilentlyContinue) -ne $null -or (Test-Path -LiteralPath $legacyConfigPath))) {
    $usingLegacyInstallation = $true
    $serviceName = $legacyServiceName
    $installDir = $legacyInstallDir
    $dataDir = $legacyDataDir
    $configPath = $legacyConfigPath
    $binaryName = 'guanlan-agent.exe'
}
$updateStatusPath = Join-Path $dataDir 'update-status.json'
$updateRequestDir = Join-Path $dataDir 'update-requests'
$updateRequestPath = Join-Path $updateRequestDir 'update-request'
$updateLauncherPath = Join-Path $dataDir 'invoke-update-request.ps1'
if (-not $PSBoundParameters.ContainsKey('ReleaseBaseUrl') -and -not [string]::IsNullOrWhiteSpace($env:XINGCHEN_AGENT_RELEASE_BASE_URLS)) {
    $ReleaseBaseUrl = @($env:XINGCHEN_AGENT_RELEASE_BASE_URLS.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if (-not $PSBoundParameters.ContainsKey('RepositoryUrl')) {
    if (-not [string]::IsNullOrWhiteSpace($env:XINGCHEN_REPOSITORY_URL)) {
        $RepositoryUrl = @($env:XINGCHEN_REPOSITORY_URL)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:XINGCHEN_REPOSITORY_URLS)) {
        $RepositoryUrl = @($env:XINGCHEN_REPOSITORY_URLS.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
}
if (-not $PSBoundParameters.ContainsKey('ReleaseManifestUrl') -and -not [string]::IsNullOrWhiteSpace($env:XINGCHEN_RELEASE_MANIFEST_URLS)) {
    $ReleaseManifestUrl = @($env:XINGCHEN_RELEASE_MANIFEST_URLS.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if (-not $PSBoundParameters.ContainsKey('AllowGitHubApi') -and $env:XINGCHEN_AGENT_ALLOW_GITHUB_API -eq 'true') {
    $AllowGitHubApi = $true
}
if (-not $PSBoundParameters.ContainsKey('AllowGitee') -and $env:XINGCHEN_ALLOW_GITEE -eq 'true') {
    $AllowGitee = $true
}
if ($Offline) { $NetworkMode = 'offline' }
if ($NetworkMode -ne 'public' -and $AllowGitHubApi) {
    throw "$NetworkMode 网络模式禁止 GitHub API；请移除 -AllowGitHubApi/XINGCHEN_AGENT_ALLOW_GITHUB_API。"
}
if ($NetworkMode -eq 'offline') { $NoAutoUpdate = $true }
$agentKey = $env:XINGCHEN_AGENT_KEY
$enrollmentToken = $env:XINGCHEN_ENROLLMENT_TOKEN
Remove-Item Env:XINGCHEN_AGENT_KEY -ErrorAction SilentlyContinue
Remove-Item Env:XINGCHEN_ENROLLMENT_TOKEN -ErrorAction SilentlyContinue

if ($Action -ne 'install' -and -not (Test-Path -LiteralPath $configPath)) {
    throw "Agent 尚未安装：$configPath"
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '请以管理员身份运行此安装脚本。'
}
if ($Action -eq 'install' -and [string]::IsNullOrWhiteSpace($agentKey) -and [string]::IsNullOrWhiteSpace($enrollmentToken) -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    $secureEnrollmentToken = Read-Host '请输入一次性 Agent 接入令牌（输入不会回显）' -AsSecureString
    $enrollmentTokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureEnrollmentToken)
    try { $enrollmentToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($enrollmentTokenPointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($enrollmentTokenPointer) }
}
if ($Action -eq 'install' -and ([string]::IsNullOrWhiteSpace($ServerUrl) -or [string]::IsNullOrWhiteSpace($DeviceId) -or ([string]::IsNullOrWhiteSpace($agentKey) -and [string]::IsNullOrWhiteSpace($enrollmentToken)))) {
    throw '安装 Agent 需要 ServerUrl、DeviceId 和一次性接入令牌；旧自动化仍可通过 XINGCHEN_AGENT_KEY 提供长期密钥。'
}
if (@($RepositoryUrl | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw 'Agent 源码仓库地址不能为空。'
}
if ($SourceRef -notmatch '^[a-zA-Z0-9._/-]+$' -or $SourceRef.StartsWith('-') -or $SourceRef.Contains('..')) {
    throw 'Agent 源码 Git ref 无效。'
}

function Test-LocalHost([string] $HostName) {
    return $HostName -match '^(localhost|127\.0\.0\.1|\[::1\]|::1)(:\d+)?$'
}

function Test-NetworkHostMatches([string] $HostName, [string] $Suffix) {
    $hostValue = $HostName.Trim().TrimEnd('.').ToLowerInvariant()
    $suffixValue = $Suffix.Trim().TrimEnd('.').ToLowerInvariant()
    return $hostValue -eq $suffixValue -or $hostValue.EndsWith(".$suffixValue", [StringComparison]::Ordinal)
}

function Test-ForbiddenPublicHost([string] $HostName) {
    foreach ($suffix in @('github.com', 'githubusercontent.com', 'githubassets.com', 'ghcr.io', 'docker.io', 'docker.com')) {
        if (Test-NetworkHostMatches $HostName $suffix) { return $true }
    }
    return $false
}

function Test-NetworkSourceAllowed([string] $Value) {
    if ($NetworkMode -eq 'offline') { return $false }
    $parsed = $null
    $isAbsolute = [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $parsed)
    $sourceHost = if ($isAbsolute -and -not [string]::IsNullOrWhiteSpace($parsed.Host)) {
        $parsed.Host
    }
    elseif ($Value -match '^[^@\s]+@([^:/\s]+):') {
        $Matches[1]
    }
    else { '' }
    if ($sourceHost -and (Test-NetworkHostMatches $sourceHost 'gitee.com') -and -not $AllowGitee) { return $false }
    if ($NetworkMode -eq 'public') { return $true }
    if (-not $isAbsolute -or $parsed.Scheme -ne 'https' -or $parsed.UserInfo -or $parsed.Fragment) { return $false }
    if (Test-ForbiddenPublicHost $parsed.Host) { return $false }
    return $true
}

function Assert-NetworkSourcePolicy([string] $Value, [string] $Label) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    if ($NetworkMode -eq 'offline') { throw "offline 网络模式拒绝远程${Label}：$Value" }
    if (-not (Test-NetworkSourceAllowed $Value)) {
        if ($NetworkMode -eq 'public') { throw "Gitee ${Label}仅在 XINGCHEN_ALLOW_GITEE=true 时允许：$Value" }
        throw "internal 网络模式拒绝非 HTTPS、GitHub/GHCR 或未经授权的 Gitee ${Label}：$Value"
    }
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
            if (-not $AllowInsecureHttp) { throw '远程 HTTP 连接未获授权；请配置 HTTPS，或确认风险后显式传入 -AllowInsecureHttp。' }
            Write-Warning "Agent 将通过未加密的 HTTP 连接 $raw。生产环境建议配置 HTTPS。"
        }
        return [pscustomobject]@{ Url = $raw; AllowInsecure = ($parsed.Scheme -eq 'http' -and -not $isLocal) }
    }

    if ($NetworkMode -eq 'offline') {
        throw 'offline 网络模式不会探测 DNS/协议；请通过 -ServerUrl 提供完整 HTTP(S) URL。'
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
    if (-not $isLocal -and -not $AllowInsecureHttp) {
        throw '未检测到可用 HTTPS；不会自动尝试远程 HTTP。确认风险后可传入 -AllowInsecureHttp。'
    }
    if (Test-ServerEndpoint $httpCandidate) {
        if (-not $isLocal) {
            Write-Warning "未检测到可用 HTTPS，已回退到未加密 HTTP：$httpCandidate"
        }
        return [pscustomobject]@{ Url = $httpCandidate; AllowInsecure = (-not $isLocal) }
    }
    throw "无法访问 $raw 的 HTTPS 或 HTTP 健康检查。请检查 DNS、端口和服务状态。"
}
if ($Action -eq 'install' -and $NetworkMode -eq 'offline' -and [string]::IsNullOrWhiteSpace($agentKey)) {
    throw 'offline 网络模式不能交换一次性接入令牌；请仅通过 XINGCHEN_AGENT_KEY 环境变量提供已签发长期密钥。'
}

function Get-AgentEnrollmentCredential {
    if (-not [string]::IsNullOrWhiteSpace($agentKey)) { return }
    if ($NetworkMode -eq 'offline') { throw 'offline 网络模式不能交换一次性接入令牌。' }
    $body = @{ deviceId = $DeviceId; token = $enrollmentToken } | ConvertTo-Json -Compress
    try {
        $credential = Invoke-RestMethod -Uri ($ServerUrl.TrimEnd('/') + '/api/agent/v1/enroll') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 30 -MaximumRedirection 0
    }
    catch {
        throw 'Agent 接入令牌交换失败；请确认令牌未过期或重新签发。'
    }
    $receivedKey = [string] $credential.agentKey
    if ($receivedKey -notmatch '^[A-Za-z0-9_-]{32,128}$') {
        throw '总控返回的 Agent 长期凭据格式无效。'
    }
    $script:agentKey = $receivedKey
    $script:enrollmentToken = $null
    Remove-Item Env:XINGCHEN_ENROLLMENT_TOKEN -ErrorAction SilentlyContinue
}

function Normalize-ReleaseVersion([string] $Value) {
    if ($Value.Trim() -notmatch '^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw "版本号必须是稳定语义版本，例如 v1.20.6。" }
    return "v$($Matches[1]).$($Matches[2]).$($Matches[3])"
}

function Test-TrustedHttpsSource([string] $Value, [switch] $AllowQuery) {
    $parsed = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $parsed) -or $parsed.Scheme -ne 'https' -or $parsed.UserInfo -or $parsed.Fragment) { return $false }
    if (-not (Test-NetworkSourceAllowed $Value)) { return $false }
    return $AllowQuery -or [string]::IsNullOrWhiteSpace($parsed.Query)
}

foreach ($source in $ReleaseManifestUrl) { Assert-NetworkSourcePolicy $source 'manifest 源' }
foreach ($source in $ReleaseBaseUrl) { Assert-NetworkSourcePolicy $source '制品源' }
foreach ($source in $RepositoryUrl) { Assert-NetworkSourcePolicy $source '源码源' }

function Get-ControllerReleaseMetadata([string] $Arch) {
    if ($NetworkMode -eq 'offline' -or [string]::IsNullOrWhiteSpace($ServerUrl)) { return $null }
    if ($NetworkMode -eq 'internal' -and -not (Test-NetworkSourceAllowed $ServerUrl)) { return $null }
    try {
        $metadata = Invoke-RestMethod -Uri ($ServerUrl.TrimEnd('/') + "/api/setup/agent-release?os=windows&arch=$Arch") -TimeoutSec 30 -MaximumRedirection 0
        $metadata.version = Normalize-ReleaseVersion ([string] $metadata.version)
        if ([string] $metadata.file -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.zip$' -or [string] $metadata.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [long] $metadata.size -le 0 -or [long] $metadata.size -gt 536870912) {
            throw '总控返回的 Agent 制品元数据无效。'
        }
        return $metadata
    }
    catch { return $null }
}

function Expand-SafeZip([string] $Archive, [string] $Destination, [string[]] $ExpectedNames) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -ne 1) { throw 'Agent ZIP 必须只包含一个二进制文件。' }
        $entry = $zip.Entries[0]
        if ($entry.FullName -ne $entry.Name -or $ExpectedNames -notcontains $entry.Name) { throw 'Agent ZIP 包含非预期条目。' }
        $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
        if (($entry.ExternalAttributes -band 0x10) -ne 0 -or ($unixType -ne 0 -and $unixType -ne 0x8000)) { throw 'Agent ZIP 条目不是普通文件。' }
        $entryPath = [IO.Path]::GetFullPath((Join-Path $Destination $entry.Name))
        if (-not $entryPath.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Agent ZIP 包含不安全路径。' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $entryPath, $true)
    }
    finally { $zip.Dispose() }
}

function Get-ReleaseVersion([string] $Requested) {
    if (-not [string]::IsNullOrWhiteSpace($Requested)) { return Normalize-ReleaseVersion $Requested }
    foreach ($manifestUrl in $ReleaseManifestUrl) {
        if (-not (Test-TrustedHttpsSource $manifestUrl -AllowQuery)) { continue }
        try {
            $manifest = Invoke-RestMethod -Uri $manifestUrl -Headers @{ 'User-Agent' = 'xingchen-agent-installer' } -TimeoutSec 30 -MaximumRedirection 0
            return Normalize-ReleaseVersion ([string] $manifest.version)
        }
        catch { }
    }
    if ($NetworkMode -eq 'public' -and $AllowGitHubApi) {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$ReleaseRepo/releases/latest" -Headers @{ 'User-Agent' = 'xingchen-agent-installer' } -TimeoutSec 30 -MaximumRedirection 0
        return Normalize-ReleaseVersion ([string] $release.tag_name)
    }
    throw '无法从总控或配置的 manifest 获取 Agent 版本；GitHub API 默认未启用。'
}

function Get-ReleaseBinary([string] $Requested, [string] $Destination) {
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
        'X64' { 'amd64' }
        'Arm64' { 'arm64' }
        default { throw '当前 Windows CPU 架构不支持预编译 Agent。' }
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $controllerMetadata = Get-ControllerReleaseMetadata $arch
    if ($null -ne $controllerMetadata -and ([string]::IsNullOrWhiteSpace($Requested) -or (Normalize-ReleaseVersion $Requested) -eq $controllerMetadata.version)) {
        $archive = Join-Path $Destination ([string] $controllerMetadata.file)
        try {
            $artifactUrl = $ServerUrl.TrimEnd('/') + "/api/setup/agent-artifact?os=windows&arch=$arch&version=$($controllerMetadata.version)"
            Invoke-WebRequest -UseBasicParsing -Uri $artifactUrl -OutFile $archive -TimeoutSec 300 -MaximumRedirection 0
            if ((Get-Item -LiteralPath $archive).Length -ne [long] $controllerMetadata.size) { throw '总控返回的 Agent 制品大小不符。' }
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
            if ($actual -ne ([string] $controllerMetadata.sha256).ToLowerInvariant()) { throw '总控返回的 Agent 制品 SHA256 校验失败。' }
            Expand-SafeZip $archive $Destination @('xingchen-agent.exe', 'guanlan-agent.exe')
            $binary = @((Join-Path $Destination 'xingchen-agent.exe'), (Join-Path $Destination 'guanlan-agent.exe')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if ([string]::IsNullOrWhiteSpace($binary)) { throw 'Agent 压缩包中未找到可执行文件。' }
            return [pscustomobject]@{ Path = $binary; Version = $controllerMetadata.version; Source = 'controller'; Verification = 'sha256' }
        }
        catch { Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue }
    }
    $version = Get-ReleaseVersion $Requested
    foreach ($base in $ReleaseBaseUrl) {
        if (-not (Test-TrustedHttpsSource $base)) { continue }
        foreach ($prefix in @('xingchen-agent', 'guanlan-agent')) {
            $asset = "${prefix}_$($version.TrimStart('v'))_windows_$arch.zip"
            $archive = Join-Path $Destination $asset
            $checksums = Join-Path $Destination 'checksums.txt'
            try {
                Invoke-WebRequest -UseBasicParsing -Uri "$base/$version/$asset" -OutFile $archive -TimeoutSec 300 -MaximumRedirection 0
                Invoke-WebRequest -UseBasicParsing -Uri "$base/$version/checksums.txt" -OutFile $checksums -TimeoutSec 60 -MaximumRedirection 0
                $expected = (Get-Content -LiteralPath $checksums | ForEach-Object { $parts = $_ -split '\s+'; if ($parts.Count -ge 2 -and ($parts[1] -eq $asset -or $parts[1].TrimStart('*') -eq $asset)) { $parts[0]; break } })
                $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($expected) -or $expected.ToLowerInvariant() -ne $actual) { throw 'Agent Release SHA256 校验失败。' }
                Expand-SafeZip $archive $Destination @("$prefix.exe")
                $binary = Join-Path $Destination $binaryName
                if (-not (Test-Path -LiteralPath $binary)) {
                    $binary = Join-Path $Destination ($(if ($prefix -eq 'xingchen-agent') { 'xingchen-agent.exe' } else { 'guanlan-agent.exe' }))
                }
                if (-not (Test-Path -LiteralPath $binary)) { throw 'Agent 压缩包中未找到可执行文件。' }
                return [pscustomobject]@{ Path = $binary; Version = $version; Source = ([Uri] $base).Host; Verification = 'sha256' }
            }
            catch {
                Remove-Item -LiteralPath $archive, $checksums -Force -ErrorAction SilentlyContinue
            }
        }
    }
    throw "Agent $version 下载或校验失败。"
}

function Install-AgentUpdater {
    $updaterPath = Join-Path $dataDir 'update-agent.ps1'
    $taskName = if ($usingLegacyInstallation) { 'GuanlanAgentUpdate' } else { 'XingchenAgentUpdate' }
    $releaseBaseList = ($ReleaseBaseUrl | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', '
    $releaseManifestList = ($ReleaseManifestUrl | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', '
    $controllerUrlLiteral = $ServerUrl.TrimEnd('/').Replace("'", "''")
    $updateStateDirLiteral = $dataDir.Replace("'", "''")
    $updateStatusPathLiteral = $updateStatusPath.Replace("'", "''")
    $updateRequestPathLiteral = $updateRequestPath.Replace("'", "''")
    $updaterPathLiteral = $updaterPath.Replace("'", "''")
    $allowGitHubApiLiteral = if ($AllowGitHubApi) { '$true' } else { '$false' }
    $allowGiteeLiteral = if ($AllowGitee) { '$true' } else { '$false' }
    $networkModeLiteral = $NetworkMode.Replace("'", "''")
    $script = @"
param([string] `$Command = 'update', [string] `$RequestedVersion, [switch] `$Automatic)
`$ErrorActionPreference = 'Stop'
`$releaseRepo = '$ReleaseRepo'
`$releaseBases = @($releaseBaseList)
`$releaseManifests = @($releaseManifestList)
`$controllerUrl = '$controllerUrlLiteral'
`$allowGitHubApi = $allowGitHubApiLiteral
`$allowGitee = $allowGiteeLiteral
`$networkMode = '$networkModeLiteral'
`$updateStateDir = '$updateStateDirLiteral'
`$updateStatusPath = '$updateStatusPathLiteral'
`$failureFile = Join-Path `$updateStateDir 'update-failures'
`$pauseFile = Join-Path `$updateStateDir 'update-paused-until'
`$failureThreshold = 5
`$pauseSeconds = 86400
function Write-AgentUpdateStatus([string] `$Status, [string] `$LastError = '') {
    if (`$LastError.Length -gt 500) { `$LastError = `$LastError.Substring(0, 500) }
    `$payload = [ordered]@{ status = `$Status; lastError = `$LastError; changedAt = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') } | ConvertTo-Json -Compress
    `$temporary = "`$updateStatusPath.`$PID.tmp"
    try {
        [IO.File]::WriteAllText(`$temporary, `$payload, [Text.UTF8Encoding]::new(`$false))
        Move-Item -LiteralPath `$temporary -Destination `$updateStatusPath -Force
    }
    finally { Remove-Item -LiteralPath `$temporary -Force -ErrorAction SilentlyContinue }
}
`$pausedUntil = 0L
if (`$Automatic -and (Test-Path -LiteralPath `$pauseFile) -and [long]::TryParse(([string](Get-Content -Raw -LiteralPath `$pauseFile)).Trim(), [ref] `$pausedUntil) -and `$pausedUntil -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
    try { Write-AgentUpdateStatus 'PAUSED' 'Automatic updates paused after repeated failures.' } catch { }
    Write-Host "Agent 自动更新已暂停到 Unix 时间 `$pausedUntil；可手动执行 update 重试。"
    exit 0
}
`$temp = Join-Path ([IO.Path]::GetTempPath()) ('xingchen-agent-update-' + [Guid]::NewGuid().ToString('N'))
`$mutex = [Threading.Mutex]::new(`$false, 'Global\XingchenAgentUpdate')
if (-not `$mutex.WaitOne(0)) { throw 'Agent 更新任务正在执行。' }
function Write-UpdateState([string] `$Path, [string] `$Value) {
    `$temporary = "`$Path.`$PID.tmp"
    [IO.File]::WriteAllText(`$temporary, `$Value + [Environment]::NewLine, [Text.UTF8Encoding]::new(`$false))
    Move-Item -LiteralPath `$temporary -Destination `$Path -Force
}
function Normalize-Version([string] `$Value) {
    if (`$Value.Trim() -notmatch '^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw '无效的 Agent Release 版本。' }
    return "v`$(`$Matches[1]).`$(`$Matches[2]).`$(`$Matches[3])"
}
function Compare-Version([string] `$Left, [string] `$Right) {
    return ([Version]`$Left.TrimStart('v')).CompareTo([Version]`$Right.TrimStart('v'))
}
function Test-SameMajor([string] `$Left, [string] `$Right) {
    return ([Version]`$Left.TrimStart('v')).Major -eq ([Version]`$Right.TrimStart('v')).Major
}
function Host-Matches([string] `$HostName, [string] `$Suffix) {
    `$hostValue = `$HostName.Trim().TrimEnd('.').ToLowerInvariant()
    `$suffixValue = `$Suffix.Trim().TrimEnd('.').ToLowerInvariant()
    return `$hostValue -eq `$suffixValue -or `$hostValue.EndsWith(".`$suffixValue", [StringComparison]::Ordinal)
}
function Trusted-Https([string] `$Value, [switch] `$AllowQuery) {
    if (`$networkMode -eq 'offline') { return `$false }
    `$parsed = `$null
    if (-not [Uri]::TryCreate(`$Value, [UriKind]::Absolute, [ref] `$parsed) -or `$parsed.Scheme -ne 'https' -or `$parsed.UserInfo -or `$parsed.Fragment) { return `$false }
    if ((Host-Matches `$parsed.Host 'gitee.com') -and -not `$allowGitee) { return `$false }
    if (`$networkMode -eq 'internal') {
        foreach (`$suffix in @('github.com', 'githubusercontent.com', 'githubassets.com', 'ghcr.io', 'docker.io', 'docker.com')) { if (Host-Matches `$parsed.Host `$suffix) { return `$false } }
    }
    return `$AllowQuery -or [string]::IsNullOrWhiteSpace(`$parsed.Query)
}
function Controller-Metadata([string] `$Arch) {
    if (`$networkMode -eq 'offline' -or (`$networkMode -eq 'internal' -and -not (Trusted-Https `$controllerUrl -AllowQuery))) { return `$null }
    try {
        `$metadata = Invoke-RestMethod -Uri "`$controllerUrl/api/setup/agent-release?os=windows&arch=`$Arch" -TimeoutSec 30 -MaximumRedirection 0
        `$metadata.version = Normalize-Version ([string] `$metadata.version)
        if ([string] `$metadata.file -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.zip$' -or [string] `$metadata.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [long] `$metadata.size -le 0 -or [long] `$metadata.size -gt 536870912) { throw '总控返回的 Agent 制品元数据无效。' }
        return `$metadata
    } catch { return `$null }
}
function Expand-Safe([string] `$Archive, [string] `$Destination, [string[]] `$ExpectedNames) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    `$root = [IO.Path]::GetFullPath(`$Destination).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    `$zip = [IO.Compression.ZipFile]::OpenRead(`$Archive)
    try {
        if (`$zip.Entries.Count -ne 1) { throw 'Agent ZIP 必须只包含一个二进制文件。' }
        `$entry = `$zip.Entries[0]
        if (`$entry.FullName -ne `$entry.Name -or `$ExpectedNames -notcontains `$entry.Name) { throw 'Agent ZIP 包含非预期条目。' }
        `$unixType = ((`$entry.ExternalAttributes -shr 16) -band 0xF000)
        if ((`$entry.ExternalAttributes -band 0x10) -ne 0 -or (`$unixType -ne 0 -and `$unixType -ne 0x8000)) { throw 'Agent ZIP 条目不是普通文件。' }
        `$path = [IO.Path]::GetFullPath((Join-Path `$Destination `$entry.Name))
        if (-not `$path.StartsWith(`$root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Agent ZIP 包含不安全路径。' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile(`$entry, `$path, `$true)
    }
    finally { `$zip.Dispose() }
}
`$updateSucceeded = `$false
try {
    try { Write-AgentUpdateStatus 'CHECKING' } catch { }
    if (`$networkMode -eq 'offline') { throw 'offline 网络模式不会联网更新；请使用已校验离线制品重新运行安装器。' }
    `$command = `$Command
    `$requested = `$RequestedVersion
    `$arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -eq 'Arm64') { 'arm64' } else { 'amd64' }
    `$metadata = Controller-Metadata `$arch
    if ([string]::IsNullOrWhiteSpace(`$requested) -and `$null -ne `$metadata) { `$requested = [string] `$metadata.version }
    if ([string]::IsNullOrWhiteSpace(`$requested)) {
        foreach (`$manifestUrl in `$releaseManifests) {
            if (-not (Trusted-Https `$manifestUrl -AllowQuery)) { continue }
            try { `$manifest = Invoke-RestMethod -Uri `$manifestUrl -Headers @{ 'User-Agent' = 'xingchen-agent-updater' } -TimeoutSec 30 -MaximumRedirection 0; `$requested = [string] `$manifest.version; break } catch { }
        }
    }
    if ([string]::IsNullOrWhiteSpace(`$requested) -and `$networkMode -eq 'public' -and `$allowGitHubApi) { `$release = Invoke-RestMethod -Uri "https://api.github.com/repos/`$releaseRepo/releases/latest" -Headers @{ 'User-Agent' = 'xingchen-agent-updater' } -TimeoutSec 30 -MaximumRedirection 0; `$requested = [string]`$release.tag_name }
    if ([string]::IsNullOrWhiteSpace(`$requested)) { throw '无法从总控或配置的 manifest 获取 Agent 版本。' }
    `$version = Normalize-Version `$requested
    `$currentOutput = try { [string](& '$targetBinary' --version 2>`$null | Select-Object -First 1) } catch { '' }
    `$currentVersion = if (`$currentOutput -match 'v\d+\.\d+\.\d+') { Normalize-Version `$Matches[0] } else { '' }
    if (`$currentVersion -eq `$version) { `$updateSucceeded = `$true; Write-Host "Agent 已是 `$version。"; exit 0 }
    if (`$Automatic -and `$command -ne 'rollback' -and `$currentVersion -and -not (Test-SameMajor `$currentVersion `$version)) { `$updateSucceeded = `$true; Write-Host "Agent 自动更新不会跨主版本：当前 `$currentVersion，目标 `$version；请人工评估后手动更新。"; exit 0 }
    if (`$command -ne 'rollback' -and `$currentVersion -and (Compare-Version `$version `$currentVersion) -lt 0) { throw "拒绝从 `$currentVersion 降级到 `$version；请显式使用 rollback。" }
    New-Item -ItemType Directory -Force -Path `$temp | Out-Null
    try { Write-AgentUpdateStatus 'DOWNLOADING' } catch { }
    `$downloaded = `$false
    if (`$null -ne `$metadata -and `$metadata.version -eq `$version) {
        try {
            `$archive = Join-Path `$temp ([string] `$metadata.file)
            Invoke-WebRequest -UseBasicParsing -Uri "`$controllerUrl/api/setup/agent-artifact?os=windows&arch=`$arch&version=`$version" -OutFile `$archive -TimeoutSec 300 -MaximumRedirection 0
            if ((Get-Item -LiteralPath `$archive).Length -ne [long] `$metadata.size) { throw '总控返回的 Agent 制品大小不符。' }
            `$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath `$archive).Hash.ToLowerInvariant()
            if (`$actual -ne ([string] `$metadata.sha256).ToLowerInvariant()) { throw '总控返回的 Agent 制品 SHA256 校验失败。' }
            Expand-Safe `$archive `$temp @('xingchen-agent.exe', 'guanlan-agent.exe')
            `$downloaded = `$true
        } catch { `$downloaded = `$false }
    }
    foreach (`$base in `$releaseBases) {
        if (`$downloaded) { break }
        if (-not (Trusted-Https `$base)) { continue }
        foreach (`$prefix in @('xingchen-agent', 'guanlan-agent')) {
            try {
                `$asset = "`${prefix}_`$(`$version.TrimStart('v'))_windows_`$arch.zip"
                `$archive = Join-Path `$temp `$asset; `$checksums = Join-Path `$temp 'checksums.txt'
                Invoke-WebRequest -UseBasicParsing -Uri "`$base/`$version/`$asset" -OutFile `$archive -TimeoutSec 300 -MaximumRedirection 0
                Invoke-WebRequest -UseBasicParsing -Uri "`$base/`$version/checksums.txt" -OutFile `$checksums -TimeoutSec 60 -MaximumRedirection 0
                `$expected = (Get-Content `$checksums | ForEach-Object { `$parts = `$_ -split '\s+'; if (`$parts.Count -ge 2 -and (`$parts[1] -eq `$asset -or `$parts[1].TrimStart('*') -eq `$asset)) { `$parts[0]; break } })
                `$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath `$archive).Hash.ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace(`$expected) -or `$expected.ToLowerInvariant() -ne `$actual) { throw 'Agent Release SHA256 校验失败。' }
                Expand-Safe `$archive `$temp @("`$prefix.exe")
                `$downloaded = `$true; break
            } catch { }
        }
        if (`$downloaded) { break }
    }
    if (-not `$downloaded) { throw 'Agent Release 下载或校验失败。' }
    `$newBinary = if (Test-Path -LiteralPath (Join-Path `$temp 'xingchen-agent.exe')) { Join-Path `$temp 'xingchen-agent.exe' } else { Join-Path `$temp 'guanlan-agent.exe' }
    `$backup = '$targetBinary.backup'
    `$staged = '$targetBinary.new'
    try { Write-AgentUpdateStatus 'APPLYING' } catch { }
    Stop-Service -Name '$serviceName' -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath '$targetBinary') { Copy-Item -LiteralPath '$targetBinary' -Destination `$backup -Force }
    try { Copy-Item -LiteralPath `$newBinary -Destination `$staged -Force; Move-Item -LiteralPath `$staged -Destination '$targetBinary' -Force; Start-Service -Name '$serviceName'; (Get-Service -Name '$serviceName').WaitForStatus('Running', [TimeSpan]::FromSeconds(20)); Remove-Item -LiteralPath `$backup -Force -ErrorAction SilentlyContinue }
    catch {
        try { Write-AgentUpdateStatus 'ROLLING_BACK' 'Agent health check failed; restoring previous binary.' } catch { }
        Remove-Item -LiteralPath `$staged -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath `$backup) { Copy-Item -LiteralPath `$backup -Destination '$targetBinary' -Force }
        Start-Service -Name '$serviceName' -ErrorAction SilentlyContinue
        try { (Get-Service -Name '$serviceName').WaitForStatus('Running', [TimeSpan]::FromSeconds(20)) } catch { throw 'Agent 更新失败，且旧版本恢复后仍未存活。' }
        throw 'Agent 更新失败，已恢复旧版本。'
    }
    `$updateSucceeded = `$true
}
catch {
    try { Write-AgentUpdateStatus 'FAILED' 'Agent update failed.' } catch { }
    throw 'Agent 更新失败；请检查总控或内部制品源。'
}
finally {
    try {
        if (`$updateSucceeded) {
            Remove-Item -LiteralPath `$failureFile, `$pauseFile -Force -ErrorAction SilentlyContinue
            Write-AgentUpdateStatus 'SUCCEEDED'
        }
        elseif (`$Automatic) {
            `$failureCount = 0
            if (Test-Path -LiteralPath `$failureFile) { [void] [int]::TryParse(([string](Get-Content -Raw -LiteralPath `$failureFile)).Trim(), [ref] `$failureCount) }
            `$failureCount++
            Write-UpdateState `$failureFile ([string] `$failureCount)
            if (`$failureCount -ge `$failureThreshold) {
                `$newPause = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + `$pauseSeconds
                Write-UpdateState `$pauseFile ([string] `$newPause)
                Write-AgentUpdateStatus 'PAUSED' 'Automatic updates paused after repeated failures.'
                Write-Warning "Agent 自动更新连续失败 `$failureCount 次，已暂停 24 小时。"
            }
        }
    } catch { Write-Warning 'Agent 更新状态写入失败。' }
    `$mutex.ReleaseMutex()
    `$mutex.Dispose()
    if (Test-Path -LiteralPath `$temp) { Remove-Item -LiteralPath `$temp -Recurse -Force -ErrorAction SilentlyContinue }
}
"@
    [IO.File]::WriteAllText($updaterPath, $script, [Text.UTF8Encoding]::new($false))
    $launcherScript = @"
`$ErrorActionPreference = 'Stop'
`$requestPath = '$updateRequestPathLiteral'
`$updaterPath = '$updaterPathLiteral'
`$updateStatusPath = '$updateStatusPathLiteral'
`$processingPath = "`$requestPath.processing.`$PID"
`$mutex = [Threading.Mutex]::new(`$false, 'Global\XingchenAgentUpdateRequest')
if (-not `$mutex.WaitOne([TimeSpan]::FromMinutes(20))) { exit 75 }
function Write-RejectedUpdateStatus {
    `$payload = [ordered]@{ status = 'FAILED'; lastError = 'Agent update request rejected.'; changedAt = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') } | ConvertTo-Json -Compress
    `$temporary = "`$updateStatusPath.`$PID.tmp"
    try {
        [IO.File]::WriteAllText(`$temporary, `$payload, [Text.UTF8Encoding]::new(`$false))
        Move-Item -LiteralPath `$temporary -Destination `$updateStatusPath -Force
    }
    finally { Remove-Item -LiteralPath `$temporary -Force -ErrorAction SilentlyContinue }
}
`$invoked = `$false
try {
    if (-not (Test-Path -LiteralPath `$requestPath -PathType Leaf)) { exit 0 }
    Move-Item -LiteralPath `$requestPath -Destination `$processingPath
    `$item = Get-Item -LiteralPath `$processingPath
    if ((`$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or `$item.Length -lt 1 -or `$item.Length -gt 512) { throw 'invalid request file' }
    `$utf8 = [Text.UTF8Encoding]::new(`$false, `$true)
    `$lines = @([IO.File]::ReadAllLines(`$processingPath, `$utf8))
    if (`$lines.Count -ne 4 -or `$lines[0] -notmatch '^action=(update|rollback)$') { throw 'invalid action' }
    `$action = `$Matches[1]
    if (`$lines[1] -notmatch '^version=(v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$' -or `$Matches[1].Length -gt 64) { throw 'invalid version' }
    `$version = `$Matches[1]
    if (`$lines[2] -notmatch '^rollout_id=([1-9][0-9]*)?$') { throw 'invalid rollout id' }
    `$rolloutId = `$Matches[1]
    if (`$lines[3] -notmatch '^member_id=([1-9][0-9]*)?$') { throw 'invalid member id' }
    `$memberId = `$Matches[1]
    if ([string]::IsNullOrEmpty(`$rolloutId) -ne [string]::IsNullOrEmpty(`$memberId)) { throw 'unpaired rollout identifiers' }
    Start-Sleep -Seconds 10
    `$invoked = `$true
    `$powerShell = Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & `$powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `$updaterPath `$action `$version
    if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
}
catch {
    if (-not `$invoked) { try { Write-RejectedUpdateStatus } catch { } }
    throw 'Agent update request rejected.'
}
finally {
    Remove-Item -LiteralPath `$processingPath -Force -ErrorAction SilentlyContinue
    `$mutex.ReleaseMutex()
    `$mutex.Dispose()
}
"@
    [IO.File]::WriteAllText($updateLauncherPath, $launcherScript, [Text.UTF8Encoding]::new($false))
    foreach ($protectedPath in @($updaterPath, $updateLauncherPath)) {
        & icacls.exe $protectedPath /inheritance:r /grant:r 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "无法收紧 Agent 更新组件权限：$protectedPath" }
    }
    if ($NoAutoUpdate -or $NetworkMode -eq 'offline') {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        return
    }
    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updaterPath`" -Automatic"
    $trigger = New-ScheduledTaskTrigger -Daily -At 4:15am -RandomDelay (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -RunLevel Highest -Force | Out-Null
}

function Get-AgentSource([string] $Destination) {
    if ($NetworkMode -ne 'public') { return $false }
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

if ($Action -ne 'install') {
    switch ($Action) {
        'status' { Get-Service -Name $serviceName -ErrorAction SilentlyContinue | Format-Table -AutoSize; exit 0 }
        'list-versions' {
            if ([string]::IsNullOrWhiteSpace($ServerUrl)) {
                try { $ServerUrl = [string] ((Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json).server_url) } catch { }
            }
            $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -eq 'Arm64') { 'arm64' } else { 'amd64' }
            $seen = @{}
            $metadata = Get-ControllerReleaseMetadata $arch
            if ($null -ne $metadata) { $seen[[string] $metadata.version] = $true; [string] $metadata.version }
            foreach ($manifestUrl in $ReleaseManifestUrl) {
                if (-not (Test-TrustedHttpsSource $manifestUrl -AllowQuery)) { continue }
                try {
                    $manifestVersion = Normalize-ReleaseVersion ([string] (Invoke-RestMethod -Uri $manifestUrl -TimeoutSec 30 -MaximumRedirection 0).version)
                    if (-not $seen.ContainsKey($manifestVersion)) { $seen[$manifestVersion] = $true; $manifestVersion }
                } catch { }
            }
            if ($NetworkMode -eq 'public' -and $AllowGitHubApi) {
                $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$ReleaseRepo/releases?per_page=20" -Headers @{ 'User-Agent' = 'xingchen-agent-installer' } -TimeoutSec 30 -MaximumRedirection 0
                $release | ForEach-Object { $_.tag_name } | Where-Object { -not $seen.ContainsKey($_) }
            }
            if ($seen.Count -eq 0 -and -not $AllowGitHubApi) { throw '无法从总控或配置的 manifest 获取 Agent 版本。' }
            exit 0
        }
        'update' { $requestedVersion = $Version }
        'rollback' { if ([string]::IsNullOrWhiteSpace($Version)) { throw '回退需要 -Version v1.20.4。' }; $requestedVersion = $Version }
        'uninstall' {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            & sc.exe delete $serviceName | Out-Null
            $updateTaskName = if ($usingLegacyInstallation) { 'GuanlanAgentUpdate' } else { 'XingchenAgentUpdate' }
            if (Get-ScheduledTask -TaskName $updateTaskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $updateTaskName -Confirm:$false
            }
            Remove-Item -LiteralPath $updateLauncherPath, (Join-Path $dataDir 'update-agent.ps1') -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $updateRequestDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
            if ($Purge) { Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue }
            Write-Host '星辰监控 Agent 已卸载。'
            exit 0
        }
    }
    if ($Action -in @('update', 'rollback')) {
        $updaterPath = Join-Path $dataDir 'update-agent.ps1'
        if (-not (Test-Path -LiteralPath $updaterPath)) { throw '当前安装缺少更新器，请重新运行安装命令。' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updaterPath $Action $requestedVersion
        exit $LASTEXITCODE
    }
}

$resolvedServer = Resolve-ServerUrl
$ServerUrl = $resolvedServer.Url
$configAllowInsecureHttp = $resolvedServer.AllowInsecure
if ($NetworkMode -eq 'internal') { Assert-NetworkSourcePolicy $ServerUrl 'Controller 地址' }
if ($NetworkMode -eq 'offline' -and [string]::IsNullOrWhiteSpace($BinaryPath)) {
    throw 'offline 网络模式安装 Windows Agent 必须通过 -BinaryPath 提供已校验的本地二进制。'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$temporaryBinary = $null
$temporarySource = $null
$temporaryRelease = $null
try {
    if ([string]::IsNullOrWhiteSpace($BinaryPath)) {
        $temporaryBinary = Join-Path ([IO.Path]::GetTempPath()) ("xingchen-agent-{0}.exe" -f [Guid]::NewGuid().ToString('N'))
        try {
            $temporaryRelease = Join-Path ([IO.Path]::GetTempPath()) ("xingchen-agent-release-{0}" -f [Guid]::NewGuid().ToString('N'))
            $release = Get-ReleaseBinary $Version $temporaryRelease
            Copy-Item -LiteralPath $release.Path -Destination $temporaryBinary -Force
            $Version = $release.Version
        }
        catch {
            if ($NetworkMode -eq 'internal') {
                throw 'internal 网络模式下预编译 Agent Release 不可用，拒绝源码构建回退；请修复内部制品源或通过 -BinaryPath 提供已校验程序。'
            }
            Write-Warning '预编译 Agent Release 不可用，回退到源码构建。'
            $sourceRoot = $projectRoot
            if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'agent/go.mod'))) {
                if ($RepositoryUrl.Count -eq 0) { throw '总控制品不可用，且未配置外部 Agent 源码仓库；请恢复总控、配置 -RepositoryUrl，或通过 -BinaryPath 提供已校验程序。' }
                if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw '未找到 Agent 源码。请安装 git，或通过 -BinaryPath 提供预编译 Agent。' }
                $temporarySource = Join-Path ([IO.Path]::GetTempPath()) ("xingchen-agent-source-{0}" -f [Guid]::NewGuid().ToString('N'))
                if (-not (Get-AgentSource $temporarySource)) { throw '配置的 Agent 源码仓库均不可用。' }
                $sourceRoot = $temporarySource
            }
            if (-not (Get-Command go -ErrorAction SilentlyContinue)) { throw '未提供 -BinaryPath 时需要 Go 1.24+；也可以指定预编译 Agent。' }
            $sourceBuildVersion = 'dev'
            foreach ($candidate in @($Version, $SourceRef)) {
                if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
                try {
                    $sourceBuildVersion = Normalize-ReleaseVersion $candidate
                    break
                }
                catch { }
            }
            Push-Location (Join-Path $sourceRoot 'agent')
            try {
                $env:CGO_ENABLED = '0'
                & go build -trimpath -ldflags "-s -w -X main.version=$sourceBuildVersion" -o $temporaryBinary ./cmd/agent
                if ($LASTEXITCODE -ne 0) { throw 'Agent 编译失败。' }
            } finally {
                Pop-Location
                Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue
            }
        }
        $BinaryPath = $temporaryBinary
    }

    $resolvedBinary = (Resolve-Path -LiteralPath $BinaryPath).Path
    Get-AgentEnrollmentCredential
    New-Item -ItemType Directory -Force -Path $installDir, $dataDir, (Join-Path $dataDir 'spool'), $updateRequestDir | Out-Null
    & icacls.exe $updateRequestDir /inheritance:r /grant:r 'SYSTEM:(OI)(CI)(F)' 'Administrators:(OI)(CI)(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '无法收紧 Agent 更新请求目录权限。' }
    if (-not (Test-Path -LiteralPath $updateStatusPath)) {
        $initialUpdateStatus = [ordered]@{
            status = 'IDLE'
            lastError = ''
            changedAt = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        } | ConvertTo-Json -Compress
        $initialUpdateStatusTemporary = "$updateStatusPath.$PID.tmp"
        [IO.File]::WriteAllText($initialUpdateStatusTemporary, $initialUpdateStatus, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $initialUpdateStatusTemporary -Destination $updateStatusPath -Force
    }
    $targetBinary = Join-Path $installDir $binaryName

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
        update_status_path = $updateStatusPath
        update_request_path = $updateRequestPath
        update_launcher_path = $updateLauncherPath
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
    Install-AgentUpdater
    Start-Service -Name $serviceName
    Write-Host "星辰监控 Agent 已安装并启动。可运行 Get-Service $serviceName 查看状态。"
}
finally {
    Remove-Item Env:XINGCHEN_AGENT_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:XINGCHEN_ENROLLMENT_TOKEN -ErrorAction SilentlyContinue
    $agentKey = $null
    $enrollmentToken = $null
    if ($temporaryBinary -and (Test-Path -LiteralPath $temporaryBinary)) {
        Remove-Item -LiteralPath $temporaryBinary -Force
    }
    if ($temporarySource -and (Test-Path -LiteralPath $temporarySource)) {
        Remove-Item -LiteralPath $temporarySource -Recurse -Force
    }
    if ($temporaryRelease -and (Test-Path -LiteralPath $temporaryRelease)) {
        Remove-Item -LiteralPath $temporaryRelease -Recurse -Force
    }
}
