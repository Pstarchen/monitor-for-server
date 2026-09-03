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
$agentKey = $env:XINGCHEN_AGENT_KEY

if ($Action -ne 'install' -and -not (Test-Path -LiteralPath $configPath)) {
    throw "Agent 尚未安装：$configPath"
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '请以管理员身份运行此安装脚本。'
}
if ($Action -eq 'install' -and [string]::IsNullOrWhiteSpace($agentKey) -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    $secureAgentKey = Read-Host '请输入 Agent 密钥（输入不会回显）' -AsSecureString
    $agentKeyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureAgentKey)
    try { $agentKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($agentKeyPointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($agentKeyPointer) }
}
if ($Action -eq 'install' -and ([string]::IsNullOrWhiteSpace($ServerUrl) -or [string]::IsNullOrWhiteSpace($DeviceId) -or [string]::IsNullOrWhiteSpace($agentKey))) {
    throw '安装 Agent 需要 ServerUrl、DeviceId 和 Agent 密钥；非交互安装请通过 XINGCHEN_AGENT_KEY 环境变量提供。'
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

function Normalize-ReleaseVersion([string] $Value) {
    $normalized = $Value.Trim().TrimStart('v')
    if ($normalized -notmatch '^\d+\.\d+\.\d+$') { throw "版本号必须是稳定语义版本，例如 v1.20.6。" }
    return "v$normalized"
}

function Test-TrustedHttpsSource([string] $Value, [switch] $AllowQuery) {
    $parsed = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $parsed) -or $parsed.Scheme -ne 'https' -or $parsed.UserInfo -or $parsed.Fragment) { return $false }
    return $AllowQuery -or [string]::IsNullOrWhiteSpace($parsed.Query)
}

function Get-ControllerReleaseMetadata([string] $Arch) {
    if ([string]::IsNullOrWhiteSpace($ServerUrl)) { return $null }
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
    if ($AllowGitHubApi) {
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
    if ($NoAutoUpdate) { return }
    $updaterPath = Join-Path $dataDir 'update-agent.ps1'
    $taskName = if ($usingLegacyInstallation) { 'GuanlanAgentUpdate' } else { 'XingchenAgentUpdate' }
    $releaseBaseList = ($ReleaseBaseUrl | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', '
    $releaseManifestList = ($ReleaseManifestUrl | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', '
    $controllerUrlLiteral = $ServerUrl.TrimEnd('/').Replace("'", "''")
    $updateStateDirLiteral = $dataDir.Replace("'", "''")
    $allowGitHubApiLiteral = if ($AllowGitHubApi) { '$true' } else { '$false' }
    $script = @"
param([string] `$Command = 'update', [string] `$RequestedVersion, [switch] `$Automatic)
`$ErrorActionPreference = 'Stop'
`$releaseRepo = '$ReleaseRepo'
`$releaseBases = @($releaseBaseList)
`$releaseManifests = @($releaseManifestList)
`$controllerUrl = '$controllerUrlLiteral'
`$allowGitHubApi = $allowGitHubApiLiteral
`$updateStateDir = '$updateStateDirLiteral'
`$failureFile = Join-Path `$updateStateDir 'update-failures'
`$pauseFile = Join-Path `$updateStateDir 'update-paused-until'
`$failureThreshold = 5
`$pauseSeconds = 86400
`$pausedUntil = 0L
if (`$Automatic -and (Test-Path -LiteralPath `$pauseFile) -and [long]::TryParse(([string](Get-Content -Raw -LiteralPath `$pauseFile)).Trim(), [ref] `$pausedUntil) -and `$pausedUntil -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
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
    `$normalized = `$Value.Trim().TrimStart('v')
    if (`$normalized -notmatch '^\d+\.\d+\.\d+$') { throw '无效的 Agent Release 版本。' }
    return "v`$normalized"
}
function Compare-Version([string] `$Left, [string] `$Right) {
    return ([Version]`$Left.TrimStart('v')).CompareTo([Version]`$Right.TrimStart('v'))
}
function Test-SameMajor([string] `$Left, [string] `$Right) {
    return ([Version]`$Left.TrimStart('v')).Major -eq ([Version]`$Right.TrimStart('v')).Major
}
function Trusted-Https([string] `$Value, [switch] `$AllowQuery) {
    `$parsed = `$null
    if (-not [Uri]::TryCreate(`$Value, [UriKind]::Absolute, [ref] `$parsed) -or `$parsed.Scheme -ne 'https' -or `$parsed.UserInfo -or `$parsed.Fragment) { return `$false }
    return `$AllowQuery -or [string]::IsNullOrWhiteSpace(`$parsed.Query)
}
function Controller-Metadata([string] `$Arch) {
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
    if ([string]::IsNullOrWhiteSpace(`$requested) -and `$allowGitHubApi) { `$release = Invoke-RestMethod -Uri "https://api.github.com/repos/`$releaseRepo/releases/latest" -Headers @{ 'User-Agent' = 'xingchen-agent-updater' } -TimeoutSec 30 -MaximumRedirection 0; `$requested = [string]`$release.tag_name }
    if ([string]::IsNullOrWhiteSpace(`$requested)) { throw '无法从总控或配置的 manifest 获取 Agent 版本。' }
    `$version = Normalize-Version `$requested
    `$currentOutput = try { [string](& '$targetBinary' --version 2>`$null | Select-Object -First 1) } catch { '' }
    `$currentVersion = if (`$currentOutput -match 'v\d+\.\d+\.\d+') { Normalize-Version `$Matches[0] } else { '' }
    if (`$currentVersion -eq `$version) { `$updateSucceeded = `$true; Write-Host "Agent 已是 `$version。"; exit 0 }
    if (`$Automatic -and `$command -ne 'rollback' -and `$currentVersion -and -not (Test-SameMajor `$currentVersion `$version)) { `$updateSucceeded = `$true; Write-Host "Agent 自动更新不会跨主版本：当前 `$currentVersion，目标 `$version；请人工评估后手动更新。"; exit 0 }
    if (`$command -ne 'rollback' -and `$currentVersion -and (Compare-Version `$version `$currentVersion) -lt 0) { throw "拒绝从 `$currentVersion 降级到 `$version；请显式使用 rollback。" }
    New-Item -ItemType Directory -Force -Path `$temp | Out-Null
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
    Stop-Service -Name '$serviceName' -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath '$targetBinary') { Copy-Item -LiteralPath '$targetBinary' -Destination `$backup -Force }
    try { Copy-Item -LiteralPath `$newBinary -Destination `$staged -Force; Move-Item -LiteralPath `$staged -Destination '$targetBinary' -Force; Start-Service -Name '$serviceName'; (Get-Service -Name '$serviceName').WaitForStatus('Running', [TimeSpan]::FromSeconds(20)); Remove-Item -LiteralPath `$backup -Force -ErrorAction SilentlyContinue }
    catch {
        Remove-Item -LiteralPath `$staged -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath `$backup) { Copy-Item -LiteralPath `$backup -Destination '$targetBinary' -Force }
        Start-Service -Name '$serviceName' -ErrorAction SilentlyContinue
        try { (Get-Service -Name '$serviceName').WaitForStatus('Running', [TimeSpan]::FromSeconds(20)) } catch { throw 'Agent 更新失败，且旧版本恢复后仍未存活。' }
        throw 'Agent 更新失败，已恢复旧版本。'
    }
    `$updateSucceeded = `$true
} finally {
    try {
        if (`$updateSucceeded) {
            Remove-Item -LiteralPath `$failureFile, `$pauseFile -Force -ErrorAction SilentlyContinue
        }
        elseif (`$Automatic) {
            `$failureCount = 0
            if (Test-Path -LiteralPath `$failureFile) { [void] [int]::TryParse(([string](Get-Content -Raw -LiteralPath `$failureFile)).Trim(), [ref] `$failureCount) }
            `$failureCount++
            Write-UpdateState `$failureFile ([string] `$failureCount)
            if (`$failureCount -ge `$failureThreshold) {
                `$newPause = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + `$pauseSeconds
                Write-UpdateState `$pauseFile ([string] `$newPause)
                Write-Warning "Agent 自动更新连续失败 `$failureCount 次，已暂停 24 小时。"
            }
        }
    } catch { Write-Warning "Agent 更新状态写入失败：`$(`$_.Exception.Message)" }
    `$mutex.ReleaseMutex()
    `$mutex.Dispose()
    if (Test-Path -LiteralPath `$temp) { Remove-Item -LiteralPath `$temp -Recurse -Force -ErrorAction SilentlyContinue }
}
"@
    [IO.File]::WriteAllText($updaterPath, $script, [Text.UTF8Encoding]::new($false))
    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updaterPath`" -Automatic"
    $trigger = New-ScheduledTaskTrigger -Daily -At 4:15am -RandomDelay (New-TimeSpan -Minutes 30)
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
            if ($AllowGitHubApi) {
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
            Push-Location (Join-Path $sourceRoot 'agent')
            try {
                $env:CGO_ENABLED = '0'
                & go build -trimpath -ldflags '-s -w' -o $temporaryBinary ./cmd/agent
                if ($LASTEXITCODE -ne 0) { throw 'Agent 编译失败。' }
            } finally {
                Pop-Location
                Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue
            }
        }
        $BinaryPath = $temporaryBinary
    }

    $resolvedBinary = (Resolve-Path -LiteralPath $BinaryPath).Path
    New-Item -ItemType Directory -Force -Path $installDir, $dataDir, (Join-Path $dataDir 'spool') | Out-Null
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
    Write-Host "星辰监控 Agent 已安装并启动。可运行 Get-Service $serviceName 查看状态。"
}
finally {
    Remove-Item Env:XINGCHEN_AGENT_KEY -ErrorAction SilentlyContinue
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
