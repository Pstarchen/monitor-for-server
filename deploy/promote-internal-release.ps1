<#
.SYNOPSIS
Promotes a digest-locked Xingchen release into an internal registry and artifact directory.

.DESCRIPTION
ImageLockFile must use schemaVersion 1, match Version, and contain
images.setup/server/web/agent/postgres/redis, each with a registry-qualified source repository
(without tag) and a sha256:<64 lowercase hex> digest.
TargetRegistry is an internal registry plus namespace, for example registry.internal.example/xingchen.
OutputDir is the filesystem directory that will be published at ArtifactBaseUrl/Version/.
The caller must authenticate with docker login or a credential store before apply mode. This script
does not accept credentials and never invokes docker login. Check and DryRun do not access a registry
or write OutputDir.

.EXAMPLE
./deploy/promote-internal-release.ps1 -Version v1.20.16 `
  -TargetRegistry registry.internal.example/xingchen `
  -ArtifactDir ./dist/agent -ArtifactBaseUrl https://releases.internal.example/xingchen `
  -ImageLockFile ./dist/source-images.lock.json -OutputDir ./dist/internal/v1.20.16 -Check
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Version,
    [Parameter(Mandatory = $true)]
    [string] $TargetRegistry,
    [Parameter(Mandatory = $true)]
    [string] $ArtifactDir,
    [Parameter(Mandatory = $true)]
    [string] $ArtifactBaseUrl,
    [Parameter(Mandatory = $true)]
    [string] $ImageLockFile,
    [Parameter(Mandatory = $true)]
    [string] $OutputDir,
    [string] $MinimumControllerVersion = 'v1.20.0',
    [string] $PublishedAt = '',
    [string] $DockerCommand = 'docker',
    [switch] $Check,
    [switch] $DryRun,
    [switch] $WriteEnvExample
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$components = @('setup', 'server', 'web', 'agent', 'postgres', 'redis')
$stableVersionPattern = '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
$digestPattern = '^sha256:[a-f0-9]{64}$'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Assert-StableVersion([string] $Value, [string] $Name) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -cnotmatch $stableVersionPattern) {
        throw "$Name 必须是带 v 前缀的稳定语义版本，例如 v1.20.14。"
    }
}

function Test-PublicHost([string] $HostName) {
    $hostLower = $HostName.ToLowerInvariant().TrimEnd('.')
    $blockedHosts = @(
        'docker.io',
        'docker.com',
        'index.docker.io',
        'registry-1.docker.io',
        'ghcr.io',
        'github.com',
        'githubusercontent.com',
        'githubassets.com',
        'gitee.com'
    )
    foreach ($blocked in $blockedHosts) {
        if ($hostLower -eq $blocked -or $hostLower.EndsWith(".$blocked", [System.StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

function Get-ValidatedRepository([string] $Value, [string] $Name, [bool] $RejectPublicHost) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -cne $Value.Trim()) {
        throw "$Name 必须是非空的规范 OCI 仓库名称。"
    }
    if ($Value -cne $Value.ToLowerInvariant() -or $Value -match '[\s\\@?#]' -or $Value.Contains('://')) {
        throw "$Name 必须是小写、不含协议、凭据、tag 或 digest 的 OCI 仓库名称。"
    }
    if ($Value -notmatch '^(?<host>[^/]+)/(?<path>.+)$') {
        throw "$Name 必须显式包含 registry host 和 namespace，拒绝 hostless 引用。"
    }

    $hostAndPort = $Matches['host']
    $repositoryPath = $Matches['path']
    if ($hostAndPort -notmatch '^(?<host>[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?|localhost)(?::(?<port>[0-9]{1,5}))?$') {
        throw "$Name 的 registry host 格式无效。"
    }
    $hostName = $Matches['host']
    $port = $Matches['port']
    if ($hostName -ne 'localhost' -and -not $hostName.Contains('.') -and -not $port) {
        throw "$Name 必须显式包含可识别的 registry host，拒绝 hostless 引用。"
    }
    foreach ($label in $hostName.Split('.')) {
        if ($label -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$' -and $label -notmatch '^[a-z0-9]$') {
            throw "$Name 的 registry host 格式无效。"
        }
    }
    if ($port) {
        $portNumber = [int] $port
        if ($portNumber -lt 1 -or $portNumber -gt 65535) {
            throw "$Name 的 registry 端口无效。"
        }
    }
    if ($RejectPublicHost -and (Test-PublicHost $hostName)) {
        throw "$Name 必须指向内部 Registry，拒绝公共 Docker/GitHub 域名：$hostName"
    }

    foreach ($segment in $repositoryPath.Split('/')) {
        if ($segment -notmatch '^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*$') {
            throw "$Name 的 namespace/repository 格式无效。"
        }
    }
    return $Value
}

function Get-NormalizedArtifactBaseUrl([string] $Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -cne $Value.Trim() -or $Value -match '[\s\\?#]') {
        throw 'ArtifactBaseUrl 必须是规范的内部 HTTPS URL。'
    }
    if ($Value -match '(?i)%(?:00|2e|2f|5c)') {
        throw 'ArtifactBaseUrl 包含不安全的编码路径字符。'
    }
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri) -or $uri.Scheme -cne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw 'ArtifactBaseUrl 必须是规范的内部 HTTPS URL。'
    }
    if ($uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'ArtifactBaseUrl 不得包含凭据、query 或 fragment。'
    }
    if (Test-PublicHost $uri.DnsSafeHost) {
        throw "ArtifactBaseUrl 不得指向 GitHub/Docker 公共域名：$($uri.DnsSafeHost)"
    }
    try {
        $decodedPath = [Uri]::UnescapeDataString($uri.AbsolutePath)
    } catch {
        throw 'ArtifactBaseUrl 包含无效的 URL 编码。'
    }
    foreach ($segment in $decodedPath.Split('/')) {
        if ($segment -eq '.' -or $segment -eq '..') {
            throw 'ArtifactBaseUrl 不得包含路径跳转。'
        }
    }
    if ($decodedPath.Contains('//')) {
        throw 'ArtifactBaseUrl 路径必须是规范单分隔符形式。'
    }
    if ($decodedPath.IndexOf([char] 0) -ge 0) {
        throw 'ArtifactBaseUrl 包含不安全字符。'
    }
    return $Value.TrimEnd('/')
}

function Get-RequiredProperty($Object, [string] $PropertyName, [string] $Context) {
    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -ccontains $PropertyName)) {
        throw "$Context 缺少 $PropertyName。"
    }
    return $Object.PSObject.Properties[$PropertyName].Value
}

function Read-ImageLock([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "ImageLockFile 不存在：$Path"
    }
    $lockItem = Get-Item -LiteralPath $Path
    if ($lockItem.Length -le 0 -or $lockItem.Length -gt 1MB) {
        throw 'ImageLockFile 必须是 1 MiB 以内的非空 JSON 文件。'
    }
    try {
        $document = [System.IO.File]::ReadAllText($lockItem.FullName) | ConvertFrom-Json
    } catch {
        throw 'ImageLockFile 不是有效 JSON。'
    }
    $schemaVersion = Get-RequiredProperty $document 'schemaVersion' 'ImageLockFile'
    if ([int] $schemaVersion -ne 1) {
        throw 'ImageLockFile schemaVersion 必须为 1。'
    }
    $lockVersion = [string] (Get-RequiredProperty $document 'version' 'ImageLockFile')
    if ($lockVersion -cne $Version) {
        throw "ImageLockFile 版本 $lockVersion 与 -Version $Version 不一致。"
    }
    $images = Get-RequiredProperty $document 'images' 'ImageLockFile'
    $result = [ordered] @{}
    foreach ($component in $components) {
        $entry = Get-RequiredProperty $images $component 'ImageLockFile.images'
        $source = [string] (Get-RequiredProperty $entry 'source' "ImageLockFile.images.$component")
        $digest = [string] (Get-RequiredProperty $entry 'digest' "ImageLockFile.images.$component")
        $source = Get-ValidatedRepository $source "ImageLockFile.images.$component.source" $false
        if ($digest -cnotmatch $digestPattern) {
            throw "ImageLockFile.images.$component.digest 必须是小写 sha256:<64 hex>。"
        }
        $result[$component] = [pscustomobject] @{
            Source = $source
            Digest = $digest
        }
    }
    return $result
}

function Get-ValidatedAgentAssets([string] $Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "ArtifactDir 不存在：$Directory"
    }
    $artifactRoot = (Get-Item -LiteralPath $Directory).FullName
    $checksumPath = Join-Path $artifactRoot 'checksums.txt'
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        throw 'ArtifactDir 缺少 checksums.txt。'
    }
    $checksumItem = Get-Item -LiteralPath $checksumPath
    if ($checksumItem.Length -le 0 -or $checksumItem.Length -gt 1MB) {
        throw 'checksums.txt 必须是 1 MiB 以内的非空文件。'
    }

    $expectedNames = @(
        "xingchen-agent_$($Version.Substring(1))_linux_amd64.tar.gz",
        "xingchen-agent_$($Version.Substring(1))_linux_arm64.tar.gz",
        "xingchen-agent_$($Version.Substring(1))_windows_amd64.zip",
        "xingchen-agent_$($Version.Substring(1))_windows_arm64.zip"
    )
    $checksums = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
    foreach ($line in [System.IO.File]::ReadAllLines($checksumPath)) {
        if ($line -cnotmatch '^([a-f0-9]{64})[ \t]+\*?([A-Za-z0-9][A-Za-z0-9._-]*)[ \t]*$') {
            throw "checksums.txt 包含无效行：$line"
        }
        $digest = $Matches[1]
        $fileName = $Matches[2]
        if (-not ($expectedNames -ccontains $fileName)) {
            throw "checksums.txt 包含非预期文件：$fileName"
        }
        if ($checksums.ContainsKey($fileName)) {
            throw "checksums.txt 包含重复文件：$fileName"
        }
        $checksums.Add($fileName, $digest)
    }

    $assets = @()
    foreach ($name in $expectedNames) {
        if (-not $checksums.ContainsKey($name)) {
            throw "checksums.txt 缺少 Agent 制品：$name"
        }
        $path = Join-Path $artifactRoot $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "缺少 Agent 制品：$name"
        }
        $item = Get-Item -LiteralPath $path
        if ($item.Length -le 0) {
            throw "Agent 制品为空：$name"
        }
        $actual = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $checksums[$name]) {
            throw "Agent 制品 SHA256 校验失败：$name"
        }
        if ($name -match '_((?:linux|windows))_((?:amd64|arm64))\.(?:tar\.gz|zip)$') {
            $assetOS = $Matches[1]
            $assetArch = $Matches[2]
        } else {
            throw "Agent 制品名称无效：$name"
        }
        $assets += [pscustomobject] @{
            OS = $assetOS
            Arch = $assetArch
            File = $name
            Path = $item.FullName
            SHA256 = $actual
            Size = [int64] $item.Length
        }
    }
    return $assets
}

function Get-Rfc3339Timestamp([string] $Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$') {
        throw 'PublishedAt 必须是 RFC3339 时间。'
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref] $parsed)) {
        throw 'PublishedAt 必须是 RFC3339 时间。'
    }
    return $parsed.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Invoke-DockerCapture([string[]] $Arguments, [bool] $AllowFailure) {
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $DockerCommand @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "docker $($Arguments -join ' ') 失败（退出码 $exitCode）。"
    }
    return [pscustomobject] @{
        ExitCode = $exitCode
        Output = $output
    }
}

function Get-RemoteDigest([string] $Reference, [bool] $AllowMissing) {
    $result = Invoke-DockerCapture @('buildx', 'imagetools', 'inspect', $Reference) $AllowMissing
    if ($result.ExitCode -ne 0) {
        $failureText = [string]::Join("`n", [string[]] $result.Output)
        if ($AllowMissing -and $failureText -match '(?i)manifest unknown|not found|no such manifest|name unknown') {
            return $null
        }
        throw "docker buildx imagetools inspect 失败（退出码 $($result.ExitCode)）：$Reference"
    }
    $text = [string]::Join("`n", [string[]] $result.Output)
    $match = [regex]::Match($text, '(?im)^\s*Digest:\s*(sha256:[a-f0-9]{64})\s*$')
    if (-not $match.Success) {
        throw "docker imagetools inspect 未返回可验证的 digest：$Reference"
    }
    return $match.Groups[1].Value
}

function Write-AtomicText([string] $Path, [string] $Content) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = Join-Path $parent ('.' + [System.IO.Path]::GetFileName($Path) + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($temporary, $Content, $utf8NoBom)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Copy-AtomicFile([string] $Source, [string] $Destination, [string] $ExpectedDigest) {
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = Join-Path $parent ('.' + [System.IO.Path]::GetFileName($Destination) + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        $actual = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $ExpectedDigest) {
            throw "复制后制品 SHA256 校验失败：$([System.IO.Path]::GetFileName($Source))"
        }
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-TextSha256([string] $Content) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $utf8NoBom.GetBytes($Content)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

if ($Check -and $DryRun) {
    throw '-Check 与 -DryRun 不能同时使用。'
}
Assert-StableVersion $Version 'Version'
Assert-StableVersion $MinimumControllerVersion 'MinimumControllerVersion'
$targetPrefix = Get-ValidatedRepository $TargetRegistry 'TargetRegistry' $true
$artifactBase = Get-NormalizedArtifactBaseUrl $ArtifactBaseUrl
$publishedTimestamp = Get-Rfc3339Timestamp $PublishedAt
$artifactRoot = [System.IO.Path]::GetFullPath($ArtifactDir)
$lockPath = [System.IO.Path]::GetFullPath($ImageLockFile)
$outputRoot = [System.IO.Path]::GetFullPath($OutputDir)
if ($artifactRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) -eq $outputRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) {
    throw 'OutputDir 必须与 ArtifactDir 分离，避免覆盖已验证的输入。'
}
if (Test-Path -LiteralPath $outputRoot -PathType Leaf) {
    throw 'OutputDir 不得是文件。'
}

$images = Read-ImageLock $lockPath
$assets = @(Get-ValidatedAgentAssets $artifactRoot)
$plan = [ordered] @{}
foreach ($component in $components) {
    $targetRepository = "$targetPrefix/$component"
    $target = "$targetRepository`:$Version"
    $plan[$component] = [pscustomobject] @{
        SourceReference = "$($images[$component].Source)@$($images[$component].Digest)"
        SourceDigest = $images[$component].Digest
        TargetTag = $target
        TargetReference = "$targetRepository@$($images[$component].Digest)"
    }
}

$manifestAssets = @()
foreach ($asset in $assets) {
    $manifestAssets += [ordered] @{
        os = $asset.OS
        arch = $asset.Arch
        file = $asset.File
        url = "$artifactBase/$Version/$($asset.File)"
        sha256 = $asset.SHA256
        size = $asset.Size
    }
}
$manifestObject = [ordered] @{
    schemaVersion = 1
    version = $Version
    publishedAt = $publishedTimestamp
    minimumCompatibleControllerVersion = $MinimumControllerVersion
    assets = $manifestAssets
}
$manifestContent = ($manifestObject | ConvertTo-Json -Depth 6) + "`n"
$manifestDigest = Get-TextSha256 $manifestContent
$checksumContent = (($assets | ForEach-Object { "$($_.SHA256)  $($_.File)" }) -join "`n") + "`n"

$outputImages = [ordered] @{}
foreach ($component in $components) {
    $outputImages[$component] = $plan[$component].TargetReference
}
$outputLockObject = [ordered] @{
    schemaVersion = 1
    version = $Version
    images = $outputImages
}
$outputLockContent = ($outputLockObject | ConvertTo-Json -Depth 4) + "`n"

if ($Check) {
    Write-Host "本地校验通过：$Version；未访问 Registry，未写入 OutputDir。"
    exit 0
}

if ($DryRun) {
    foreach ($component in $components) {
        Write-Host "docker buildx imagetools create --tag $($plan[$component].TargetTag) $($plan[$component].SourceReference)"
    }
    Write-Host "DryRun 完成；未访问 Registry，未写入 OutputDir。"
    exit 0
}

if ($null -eq (Get-Command -Name $DockerCommand -ErrorAction SilentlyContinue)) {
    throw "找不到 Docker CLI：$DockerCommand"
}

# 先校验全部源 digest 和目标冲突，避免已知错误造成部分晋级。
foreach ($component in $components) {
    $sourceDigest = Get-RemoteDigest $plan[$component].SourceReference $false
    if ($sourceDigest -cne $plan[$component].SourceDigest) {
        throw "$component 源镜像 digest 与 ImageLockFile 不一致。"
    }
    $existingDigest = Get-RemoteDigest $plan[$component].TargetTag $true
    if ($null -ne $existingDigest -and $existingDigest -cne $plan[$component].SourceDigest) {
        throw "$component 目标版本 tag 已存在且 digest 不同，拒绝覆盖：$($plan[$component].TargetTag)"
    }
    $plan[$component] | Add-Member -NotePropertyName ExistingDigest -NotePropertyValue $existingDigest
}

foreach ($component in $components) {
    if ($null -eq $plan[$component].ExistingDigest) {
        Invoke-DockerCapture @('buildx', 'imagetools', 'create', '--tag', $plan[$component].TargetTag, $plan[$component].SourceReference) $false | Out-Null
    }
    $targetDigest = Get-RemoteDigest $plan[$component].TargetTag $false
    if ($targetDigest -cne $plan[$component].SourceDigest) {
        throw "$component 目标镜像 digest 复核失败：$($plan[$component].TargetTag)"
    }
}

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
foreach ($asset in $assets) {
    Copy-AtomicFile $asset.Path (Join-Path $outputRoot $asset.File) $asset.SHA256
}
Write-AtomicText (Join-Path $outputRoot 'checksums.txt') $checksumContent
Write-AtomicText (Join-Path $outputRoot 'manifest.json') $manifestContent
Write-AtomicText (Join-Path $outputRoot 'manifest.json.sha256') "$manifestDigest  manifest.json`n"
Write-AtomicText (Join-Path $outputRoot 'controller-images.lock.json') $outputLockContent
if ($WriteEnvExample) {
    $envLines = @(
        "XINGCHEN_SETUP_IMAGE=$($plan['setup'].TargetReference)",
        "XINGCHEN_SERVER_IMAGE=$($plan['server'].TargetReference)",
        "XINGCHEN_WEB_IMAGE=$($plan['web'].TargetReference)",
        "XINGCHEN_AGENT_IMAGE=$($plan['agent'].TargetReference)",
        "XINGCHEN_POSTGRES_IMAGE=$($plan['postgres'].TargetReference)",
        "XINGCHEN_REDIS_IMAGE=$($plan['redis'].TargetReference)"
    )
    Write-AtomicText (Join-Path $outputRoot 'controller-images.env.example') (($envLines -join "`n") + "`n")
}

Write-Host "内部制品晋级完成：$Version"
Write-Host "输出目录：$outputRoot"
