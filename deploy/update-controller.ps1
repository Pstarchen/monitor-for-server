[CmdletBinding()]
param(
    [switch] $Check,
    [switch] $Apply,
    [switch] $Auto,
    [switch] $Build,
    [switch] $SourceBuild,
    [switch] $Offline,
    [switch] $NoMirror,
    [switch] $NoSourceFallback,
    [string] $ProjectRoot,
    [string] $OfflineBundle
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRootWasProvided = $PSBoundParameters.ContainsKey('ProjectRoot')
$offlineBundleWasProvided = $PSBoundParameters.ContainsKey('OfflineBundle')
$modeCount = @($Check, $Apply, $Auto).Where({ $_ }).Count
if ($modeCount -gt 1) { throw '-Check、-Apply 与 -Auto 只能选择一个。' }
if ($modeCount -eq 0) { $Check = $true }
if ($Build -and $SourceBuild) { throw '-Build 与 -SourceBuild 不能同时使用。' }
if ($offlineBundleWasProvided) {
    if ([string]::IsNullOrWhiteSpace($OfflineBundle)) { throw '-OfflineBundle 需要绝对路径。' }
    if (-not $projectRootWasProvided) { throw '-OfflineBundle 必须与 -ProjectRoot 一起使用。' }
    $Offline = $true
    $NoSourceFallback = $true
}
if ($Offline -and ($Build -or $SourceBuild -or $Auto)) { throw '-Offline 不能与 -Build、-SourceBuild 或 -Auto 同时使用。' }

function Resolve-AbsoluteDirectory([string] $Path, [string] $Label) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path)) {
        throw "$Label 必须是已存在的绝对目录。"
    }
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "$Label 必须是已存在的绝对目录。"
    }
    return [System.IO.Path]::GetFullPath($resolved).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

$runnerMode = [string]::Equals($env:CONTROLLER_UPDATE_RUNNER, 'true', [System.StringComparison]::OrdinalIgnoreCase)
if ($runnerMode) {
    if ($projectRootWasProvided -or $offlineBundleWasProvided) {
        throw '更新 Runner 不接受外部项目根或离线 bundle 参数。'
    }
    $ProjectRoot = Resolve-AbsoluteDirectory $env:SETUP_WORKSPACE '更新 Runner 的 SETUP_WORKSPACE'
}
elseif ($projectRootWasProvided) {
    $ProjectRoot = Resolve-AbsoluteDirectory $ProjectRoot '-ProjectRoot'
}
else {
    $ProjectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

$projectRootVolume = [System.IO.Path]::GetPathRoot($ProjectRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
if ($ProjectRoot -eq $projectRootVolume -or
    -not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'docker-compose.yml') -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $ProjectRoot '.env') -PathType Leaf)) {
    throw '项目根必须指向包含 docker-compose.yml 和 .env 的既有部署，且不能是卷根目录。'
}
if ($offlineBundleWasProvided) {
    $OfflineBundle = Resolve-AbsoluteDirectory $OfflineBundle '-OfflineBundle'
    if ([string]::Equals($OfflineBundle, $ProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '离线 bundle 目录不能与既有部署目录相同。'
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw '需要安装 Docker Engine。' }
& docker compose version | Out-Null
if ($LASTEXITCODE -ne 0) { throw '需要 Docker Compose v2。' }

function Assert-NoReparsePoint([string] $Path, [string] $Label) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label 不能是符号链接或重解析点：$Path"
    }
}

function Get-SafeBundleFile([string] $Root, [string] $Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or
        [System.IO.Path]::IsPathRooted($Relative) -or
        $Relative.Contains('\') -or
        $Relative.Contains(':') -or
        $Relative -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') {
        throw "离线校验路径不安全：$Relative"
    }
    $segments = $Relative.Split('/')
    if ($segments.Where({ [string]::IsNullOrWhiteSpace($_) -or $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
        throw "离线校验路径不安全：$Relative"
    }
    $rootPrefix = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $path = [System.IO.Path]::GetFullPath((Join-Path $Root ($segments -join [System.IO.Path]::DirectorySeparatorChar)))
    if (-not $path.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "离线校验路径越界：$Relative"
    }
    $current = $Root
    foreach ($segment in $segments) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { throw "离线文件缺失：$Relative" }
        Assert-NoReparsePoint $current '离线 bundle 条目'
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "离线文件不是普通文件：$Relative" }
    return $path
}

function ConvertFrom-TarOctal([byte[]] $Header, [int] $Offset, [int] $Length, [string] $Label) {
    $text = [System.Text.Encoding]::ASCII.GetString($Header, $Offset, $Length).Trim([char[]]@([char]0, [char]32))
    if ([string]::IsNullOrEmpty($text)) { return [long]0 }
    if ($text -notmatch '^[0-7]+$') { throw "Docker 镜像归档的 $Label 不是有效八进制数。" }
    try { return [Convert]::ToInt64($text, 8) }
    catch { throw "Docker 镜像归档的 $Label 超出范围。" }
}

function Test-SafeTarReference([string] $Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value.StartsWith('/') -or
        $Value.Contains('\') -or
        $Value.Contains(':') -or
        $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') {
        return $false
    }
    foreach ($segment in $Value.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') { return $false }
    }
    return $true
}

function Read-DockerArchive([string] $Path) {
    $entries = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::Ordinal)
    $manifestBytes = $null
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $reader = [System.IO.BinaryReader]::new($stream, [System.Text.Encoding]::ASCII, $true)
    try {
        while ($stream.Position -lt $stream.Length) {
            $header = $reader.ReadBytes(512)
            if ($header.Length -eq 0) { break }
            if ($header.Length -ne 512) { throw 'controller-images.tar 的 tar header 被截断。' }
            $allZero = $true
            foreach ($value in $header) {
                if ($value -ne 0) { $allZero = $false; break }
            }
            if ($allZero) { break }

            $storedChecksum = ConvertFrom-TarOctal $header 148 8 'header checksum'
            $actualChecksum = [long]0
            for ($index = 0; $index -lt 512; $index++) {
                if ($index -ge 148 -and $index -lt 156) { $actualChecksum += 32 }
                else { $actualChecksum += $header[$index] }
            }
            if ($storedChecksum -ne $actualChecksum) { throw 'controller-images.tar 的 tar header checksum 无效。' }

            $name = [System.Text.Encoding]::ASCII.GetString($header, 0, 100).TrimEnd([char]0)
            $prefix = [System.Text.Encoding]::ASCII.GetString($header, 345, 155).TrimEnd([char]0)
            if (-not [string]::IsNullOrEmpty($prefix)) { $name = "$prefix/$name" }
            $typeFlag = $header[156]
            $regularFile = $typeFlag -eq 0 -or $typeFlag -eq 48
            $validationName = if ($typeFlag -eq 53) { $name.TrimEnd('/') } else { $name }
            if (-not (Test-SafeTarReference $validationName)) { throw "controller-images.tar 包含不安全路径：$name" }
            if ($entries.ContainsKey($name)) { throw "controller-images.tar 包含重复条目：$name" }
            $entries.Add($name, $regularFile)
            $size = ConvertFrom-TarOctal $header 124 12 'entry size'
            $padding = (512 - ($size % 512)) % 512
            if ($size -gt ($stream.Length - $stream.Position) -or $padding -gt ($stream.Length - $stream.Position - $size)) {
                throw "controller-images.tar 条目被截断：$name"
            }
            if ($name -eq 'manifest.json') {
                if (-not $regularFile -or $null -ne $manifestBytes -or $size -le 0 -or $size -gt 1048576) {
                    throw 'controller-images.tar 的 manifest.json 缺失、重复或大小无效。'
                }
                $manifestBytes = $reader.ReadBytes([int]$size)
                if ($manifestBytes.Length -ne $size) { throw 'controller-images.tar 的 manifest.json 被截断。' }
            }
            else {
                [void]$stream.Seek($size, [System.IO.SeekOrigin]::Current)
            }
            if ($padding -gt 0) { [void]$stream.Seek($padding, [System.IO.SeekOrigin]::Current) }
        }
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
    if ($null -eq $manifestBytes) { throw 'controller-images.tar 缺少顶层 manifest.json。' }
    try {
        $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $manifestText = $utf8.GetString($manifestBytes)
        if (-not $manifestText.TrimStart().StartsWith('[') -or -not $manifestText.TrimEnd().EndsWith(']')) {
            throw 'not an array'
        }
        $parsedManifest = $manifestText | ConvertFrom-Json
        $manifest = @($parsedManifest)
    }
    catch { throw 'controller-images.tar 的 manifest.json 不是有效 JSON 数组。' }
    if ($manifest.Count -eq 0) { throw 'controller-images.tar 的 manifest.json 不包含镜像。' }
    return [pscustomobject]@{ Entries = $entries; Manifest = $manifest }
}

function Test-ControllerImageArchive([string] $Path, [string] $Version) {
    $archive = Read-DockerArchive $Path
    $tags = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
    $configCount = 0
    $layerCount = 0
    foreach ($entry in @($archive.Manifest)) {
        $configProperty = $entry.PSObject.Properties['Config']
        $repoTagsProperty = $entry.PSObject.Properties['RepoTags']
        $layersProperty = $entry.PSObject.Properties['Layers']
        if ($null -eq $configProperty -or $null -eq $repoTagsProperty -or $null -eq $layersProperty) {
            throw 'controller-images.tar 的 manifest.json 缺少 Config、RepoTags 或 Layers。'
        }
        $config = [string]$configProperty.Value
        if (-not (Test-SafeTarReference $config) -or -not $archive.Entries.ContainsKey($config) -or -not $archive.Entries[$config]) {
            throw "controller-images.tar 缺少有效 config：$config"
        }
        $configCount++
        foreach ($layer in @($layersProperty.Value)) {
            $layerPath = [string]$layer
            if (-not (Test-SafeTarReference $layerPath) -or -not $archive.Entries.ContainsKey($layerPath) -or -not $archive.Entries[$layerPath]) {
                throw "controller-images.tar 缺少有效 layer：$layerPath"
            }
            $layerCount++
        }
        foreach ($tagValue in @($repoTagsProperty.Value)) {
            $tag = [string]$tagValue
            if ([string]::IsNullOrWhiteSpace($tag) -or $tag -notmatch '^[a-z0-9][a-z0-9._/@:-]+$') {
                throw "controller-images.tar 包含无效镜像标签：$tag"
            }
            if ($tags.ContainsKey($tag)) { $tags[$tag]++ } else { $tags.Add($tag, 1) }
        }
    }
    $expectedImages = @(
        "ghcr.io/pstarchen/monitor-for-server-setup:$Version",
        "ghcr.io/pstarchen/monitor-for-server-server:$Version",
        "ghcr.io/pstarchen/monitor-for-server-web:$Version",
        "ghcr.io/pstarchen/monitor-for-server-agent:$Version",
        'postgres:16-alpine',
        'redis:7.4-alpine'
    )
    foreach ($image in $expectedImages) {
        if (-not $tags.ContainsKey($image) -or $tags[$image] -ne 1) {
            throw "controller-images.tar 缺少或重复预期镜像：$image"
        }
    }
    if ($configCount -ne 6 -or $tags.Count -ne 6 -or $layerCount -lt 1) {
        throw 'controller-images.tar 必须且只能包含六个完整镜像记录。'
    }
}

function Get-RequiredJsonProperty($Value, [string] $Name, [string] $Context) {
    if ($null -eq $Value) { throw "$Context 不能为空。" }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Context 缺少字段：$Name" }
    return $property.Value
}

function Test-AgentReleaseAssets([string] $Root, [string] $Version, $Verified) {
    $manifestPath = Join-Path $Root 'release/manifest.json'
    if ((Get-Item -LiteralPath $manifestPath).Length -gt 1048576) { throw 'Agent manifest 超过大小限制。' }
    try { $manifest = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json }
    catch { throw '离线 bundle 的 Agent manifest 不是有效 JSON。' }
    $schemaVersion = Get-RequiredJsonProperty $manifest 'schemaVersion' 'Agent manifest'
    $manifestVersion = [string](Get-RequiredJsonProperty $manifest 'version' 'Agent manifest')
    $publishedAtValue = Get-RequiredJsonProperty $manifest 'publishedAt' 'Agent manifest'
    $minimumController = [string](Get-RequiredJsonProperty $manifest 'minimumCompatibleControllerVersion' 'Agent manifest')
    $assets = @(Get-RequiredJsonProperty $manifest 'assets' 'Agent manifest')
    $stableVersion = '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
    $parsedPublishedAt = [DateTimeOffset]::MinValue
    $publishedAtValid = $publishedAtValue -is [DateTime] -or $publishedAtValue -is [DateTimeOffset]
    if (-not $publishedAtValid -and $publishedAtValue -is [string]) {
        $publishedAt = [string]$publishedAtValue
        $publishedAtValid = $publishedAt -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' -and
            [DateTimeOffset]::TryParse($publishedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedPublishedAt)
    }
    if ((($schemaVersion -isnot [int]) -and ($schemaVersion -isnot [long])) -or [long]$schemaVersion -ne 1 -or $manifestVersion -cne $Version -or
        $minimumController -notmatch $stableVersion -or
        -not $publishedAtValid) {
        throw 'Agent manifest 的 schema、版本、发布时间或最低兼容版本无效。'
    }
    if ($assets.Count -ne 4) { throw 'Agent manifest 必须且只能包含四个平台制品。' }

    $versionNumber = $Version.Substring(1)
    $expectedFiles = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $expectedFiles.Add('linux/amd64', "xingchen-agent_${versionNumber}_linux_amd64.tar.gz")
    $expectedFiles.Add('linux/arm64', "xingchen-agent_${versionNumber}_linux_arm64.tar.gz")
    $expectedFiles.Add('windows/amd64', "xingchen-agent_${versionNumber}_windows_amd64.zip")
    $expectedFiles.Add('windows/arm64', "xingchen-agent_${versionNumber}_windows_arm64.zip")
    $manifestHashes = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($asset in $assets) {
        $os = [string](Get-RequiredJsonProperty $asset 'os' 'Agent manifest asset')
        $arch = [string](Get-RequiredJsonProperty $asset 'arch' 'Agent manifest asset')
        $file = [string](Get-RequiredJsonProperty $asset 'file' 'Agent manifest asset')
        $url = [string](Get-RequiredJsonProperty $asset 'url' 'Agent manifest asset')
        $sha256 = [string](Get-RequiredJsonProperty $asset 'sha256' 'Agent manifest asset')
        $size = Get-RequiredJsonProperty $asset 'size' 'Agent manifest asset'
        $platform = "$os/$arch"
        if (-not $expectedFiles.ContainsKey($platform) -or $file -cne $expectedFiles[$platform] -or $manifestHashes.ContainsKey($file)) {
            throw "Agent manifest 平台或文件名无效/重复：$platform $file"
        }
        if (-not [string]::IsNullOrEmpty($url)) {
            try {
                $uri = [Uri]$url
                $decodedPath = [Uri]::UnescapeDataString($uri.AbsolutePath)
            }
            catch { throw "Agent manifest URL 无效：$file" }
            if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or
                -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment) -or
                $decodedPath.Contains('\') -or ($decodedPath.TrimEnd('/').Split('/')[-1] -cne $file)) {
                throw "Agent manifest URL 路径与文件名不一致：$file"
            }
        }
        if ($sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
            (($size -isnot [int]) -and ($size -isnot [long])) -or $size -le 0 -or $size -gt 536870912) {
            throw "Agent manifest 摘要或大小无效：$file"
        }
        $relative = "release/assets/$file"
        if (-not $Verified.Contains($relative)) { throw "离线校验清单缺少 Agent 制品：$relative" }
        $path = Get-SafeBundleFile $Root $relative
        $actualSize = (Get-Item -LiteralPath $path).Length
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSize -ne [long]$size) { throw "Agent manifest 大小与制品不一致：$file" }
        if ($actualHash -cne $sha256.ToLowerInvariant()) { throw "Agent manifest SHA256 与制品不一致：$file" }
        $manifestHashes.Add($file, $actualHash)
    }
    foreach ($expected in $expectedFiles.Values) {
        if (-not $manifestHashes.ContainsKey($expected)) { throw "Agent manifest 缺少平台制品：$expected" }
    }

    $checksumHashes = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $Root 'release/assets/checksums.txt'))) {
        if ($line -notmatch '^([a-fA-F0-9]{64}) ([ *])([A-Za-z0-9][A-Za-z0-9._-]{0,199})$') {
            throw 'Agent checksums.txt 格式无效。'
        }
        $file = $Matches[3]
        if ($checksumHashes.ContainsKey($file)) { throw "Agent checksums.txt 包含重复文件：$file" }
        $checksumHashes.Add($file, $Matches[1].ToLowerInvariant())
    }
    if ($checksumHashes.Count -ne 4) { throw 'Agent checksums.txt 必须且只能包含四个平台制品。' }
    foreach ($file in $manifestHashes.Keys) {
        if (-not $checksumHashes.ContainsKey($file) -or $checksumHashes[$file] -cne $manifestHashes[$file]) {
            throw "Agent checksums.txt 与 manifest 不一致：$file"
        }
    }
}

function Test-OfflineBundle([string] $Root) {
    Assert-NoReparsePoint $Root '离线 bundle 根目录'
    $checksumPath = Join-Path $Root 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) { throw '离线 bundle 缺少可信 SHA256SUMS。' }
    Assert-NoReparsePoint $checksumPath '离线校验清单'
    $verified = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $lines = [System.IO.File]::ReadAllLines($checksumPath)
    if ($lines.Count -eq 0) { throw '离线校验清单不能为空。' }
    foreach ($line in $lines) {
        if ($line -notmatch '^([a-fA-F0-9]{64}) ([ *])([A-Za-z0-9][A-Za-z0-9._/-]*)$') {
            throw '离线校验清单格式无效。'
        }
        $expected = $Matches[1].ToLowerInvariant()
        $relative = $Matches[3]
        if (-not $verified.Add($relative)) { throw "离线校验清单包含重复路径：$relative" }
        $path = Get-SafeBundleFile $Root $relative
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "离线文件校验失败：$relative" }
    }
    $required = @(
        'bundle-metadata.txt',
        'docker-compose.yml',
        'deploy/offline-bundle-integrity.sh',
        'deploy/update-controller.ps1',
        'upgrade-offline.sh',
        'upgrade-offline.ps1',
        'images/controller-images.tar',
        'release/manifest.json',
        'release/assets/checksums.txt'
    )
    foreach ($relative in $required) {
        if (-not $verified.Contains($relative)) { throw "离线校验清单缺少必要文件：$relative" }
    }
    foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -Force) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "离线 bundle 包含符号链接或重解析点：$($item.FullName)"
        }
        if ($item.PSIsContainer) { continue }
        $relative = $item.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
        if ($relative -ne 'SHA256SUMS' -and -not $verified.Contains($relative)) {
            throw "离线 bundle 包含未校验文件：$relative"
        }
    }

    $metadata = @{}
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $Root 'bundle-metadata.txt'))) {
        if ($line -notmatch '^([a-z]+)=([A-Za-z0-9.]+)$') { throw '离线 bundle 元数据格式无效。' }
        $key = $Matches[1]
        if ($key -notin @('schema', 'version', 'architecture') -or $metadata.ContainsKey($key)) {
            throw "离线 bundle 元数据字段无效或重复：$key"
        }
        $metadata[$key] = $Matches[2]
    }
    if ($metadata.Count -ne 3 -or $metadata.schema -ne '1' -or
        $metadata.version -notmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
        $metadata.architecture -notin @('amd64', 'arm64')) {
        throw '离线 bundle 元数据无效。'
    }
    $hostArchitecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
        'X64' { 'amd64' }
        'Arm64' { 'arm64' }
        default { throw '当前主机架构不受离线 bundle 支持。' }
    }
    if ($hostArchitecture -ne $metadata.architecture) {
        throw "离线 bundle 架构 $($metadata.architecture) 与主机 $hostArchitecture 不匹配。"
    }
    Test-ControllerImageArchive (Join-Path $Root 'images/controller-images.tar') ([string]$metadata.version)
    Test-AgentReleaseAssets $Root ([string]$metadata.version) $verified
    return [pscustomobject]@{
        Version = [string]$metadata.version
        Architecture = [string]$metadata.architecture
        ManifestSHA256 = (Get-FileHash -LiteralPath (Join-Path $Root 'release/manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$bundleMetadata = $null
if ($offlineBundleWasProvided) { $bundleMetadata = Test-OfflineBundle $OfflineBundle }

$composeFile = Join-Path $ProjectRoot 'docker-compose.yml'
$envFile = Join-Path $ProjectRoot '.env'
if ($Check -and $offlineBundleWasProvided) {
    Write-Host "离线 bundle $($bundleMetadata.Version) 已通过完整性、版本与架构检查；未加载镜像或修改部署。"
    exit 0
}

function Get-FileSnapshot([string] $Path) {
    $Path = Assert-DeploymentChild $Path
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Exists = $false; Bytes = $null; Attributes = $null; LastWriteTimeUtc = $null }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "预期文件却发现目录：$Path" }
    Assert-NoReparsePoint $Path '部署文件'
    $item = Get-Item -LiteralPath $Path -Force
    return [pscustomobject]@{
        Exists = $true
        Bytes = [System.IO.File]::ReadAllBytes($Path)
        Attributes = $item.Attributes
        LastWriteTimeUtc = $item.LastWriteTimeUtc
    }
}

function Assert-DeploymentChild([string] $Path) {
    $rootPrefix = $ProjectRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝修改项目根之外的路径：$resolved"
    }
    $current = $ProjectRoot
    $relative = $resolved.Substring($rootPrefix.Length)
    $separators = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    foreach ($segment in $relative.Split($separators, [System.StringSplitOptions]::RemoveEmptyEntries)) {
        if ($segment -eq '.' -or $segment -eq '..') { throw "部署路径包含不安全组件：$resolved" }
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            Assert-NoReparsePoint $current '部署路径组件'
            $componentPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $current -ErrorAction Stop).ProviderPath)
            if (-not $componentPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "部署路径解析后超出项目根：$current"
            }
        }
    }
    return $resolved
}

function Write-FileAtomically([string] $Path, [byte[]] $Bytes) {
    $Path = Assert-DeploymentChild $Path
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "目标目录不存在：$parent" }
    Assert-NoReparsePoint $parent '部署目录'
    $temporary = Join-Path $parent ('.controller-update-file-' + [Guid]::NewGuid().ToString('N'))
    $replaceBackup = $temporary + '.replaced'
    try {
        [System.IO.File]::WriteAllBytes($temporary, $Bytes)
        if (Test-Path -LiteralPath $Path) {
            Assert-NoReparsePoint $Path '部署文件'
            [System.IO.File]::Replace($temporary, $Path, $replaceBackup)
            Remove-Item -LiteralPath $replaceBackup -Force
        }
        else {
            [System.IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if (Test-Path -LiteralPath $replaceBackup) { Remove-Item -LiteralPath $replaceBackup -Force }
    }
}

function Restore-FileSnapshot([string] $Path, $Snapshot) {
    $Path = Assert-DeploymentChild $Path
    if ($Snapshot.Exists) {
        Write-FileAtomically $Path $Snapshot.Bytes
        [System.IO.File]::SetAttributes($Path, $Snapshot.Attributes)
        (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc = $Snapshot.LastWriteTimeUtc
    }
    elseif (Test-Path -LiteralPath $Path) {
        Assert-NoReparsePoint $Path '部署文件'
        Remove-Item -LiteralPath $Path -Force
    }
}

function Get-EnvValueFromFile([string] $Path, [string] $Name, [string] $DefaultValue = '') {
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line.StartsWith("$Name=", [System.StringComparison]::Ordinal)) {
            $value = $line.Substring($Name.Length + 1)
            if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            return $value
        }
    }
    return $DefaultValue
}

function New-UpdatedEnvBytes([string] $Path, [hashtable] $Settings) {
    foreach ($entry in $Settings.GetEnumerator()) {
        if ($entry.Key -notmatch '^[A-Z][A-Z0-9_]*$' -or
            ([string]$entry.Value).Contains("`r") -or
            ([string]$entry.Value).Contains("`n") -or
            ([string]$entry.Value).Contains('"')) {
            throw "拒绝写入无效的环境设置：$($entry.Key)"
        }
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $found = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $name = $null
        foreach ($key in $Settings.Keys) {
            if ($line.StartsWith("$key=", [System.StringComparison]::Ordinal)) { $name = [string]$key; break }
        }
        if ($null -eq $name) {
            [void]$lines.Add($line)
        }
        elseif ($found.Add($name)) {
            [void]$lines.Add("$name=`"$($Settings[$name])`"")
        }
    }
    foreach ($key in @($Settings.Keys | Sort-Object)) {
        if ($found.Add([string]$key)) { [void]$lines.Add("$key=`"$($Settings[$key])`"") }
    }
    $text = [string]::Join([Environment]::NewLine, $lines) + [Environment]::NewLine
    return [System.Text.UTF8Encoding]::new($false).GetBytes($text)
}

function Get-ProcessEnvironmentSnapshot([string[]] $Names) {
    $snapshot = @{}
    foreach ($name in $Names) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        $snapshot[$name] = [pscustomobject]@{ Exists = $null -ne $value; Value = $value }
    }
    return $snapshot
}

function Restore-ProcessEnvironment([hashtable] $Snapshot) {
    foreach ($name in $Snapshot.Keys) {
        $item = $Snapshot[$name]
        [Environment]::SetEnvironmentVariable($name, $(if ($item.Exists) { $item.Value } else { $null }), 'Process')
    }
}

function Set-ProcessEnvironment([hashtable] $Settings) {
    foreach ($name in $Settings.Keys) {
        [Environment]::SetEnvironmentVariable([string]$name, [string]$Settings[$name], 'Process')
    }
}

function Invoke-DockerLoad([string] $Archive, [int] $TimeoutSeconds) {
    $docker = Get-Command docker -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $quotedArchive = '"' + $Archive + '"'
    $process = Start-Process -FilePath $docker.Source -ArgumentList @('load', '--input', $quotedArchive) -WindowStyle Hidden -PassThru
    $process.Handle | Out-Null
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        try { $process.WaitForExit() } catch { }
        throw "Docker 离线镜像导入超过 $TimeoutSeconds 秒，已终止。"
    }
    $process.WaitForExit()
    $process.Refresh()
    if ($process.ExitCode -ne 0) { throw 'Docker 离线镜像导入失败。' }
}

function Test-LoadedBundleImages([hashtable] $Images, [string] $Version, [string] $Architecture) {
    foreach ($name in @('setup', 'server', 'web', 'agent', 'postgres', 'redis')) {
        $image = [string]$Images[$name]
        & docker image inspect $image *> $null
        if ($LASTEXITCODE -ne 0) { throw "离线镜像导入后仍缺失：$image" }
        $actualArchitecture = ([string](& docker image inspect --format '{{.Architecture}}' $image 2>$null | Select-Object -First 1)).Trim().ToLowerInvariant()
        if ($LASTEXITCODE -ne 0 -or $actualArchitecture -ne $Architecture) {
            throw "离线镜像架构不匹配：$image 标记为 $actualArchitecture，期望 $Architecture。"
        }
        if ($name -in @('setup', 'server', 'web', 'agent')) {
            $actualVersion = ([string](& docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' $image 2>$null | Select-Object -First 1)).Trim()
            if ($LASTEXITCODE -ne 0 -or $actualVersion.TrimStart('v') -ne $Version.TrimStart('v')) {
                throw "离线镜像版本不匹配：$image 标记为 $(if ($actualVersion) { $actualVersion } else { 'unknown' })，期望 $Version。"
            }
        }
    }
}

function Get-RunningImageSnapshots([string[]] $Services, [string[]] $ComposeArguments) {
    $snapshots = @()
    foreach ($service in $Services) {
        $containerId = ([string](& docker compose @ComposeArguments ps -q $service 2>$null | Select-Object -First 1)).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $containerId) { throw "无法定位正在运行的 $service 容器，更新未开始。" }
        $imageId = ([string](& docker inspect --format '{{.Image}}' $containerId 2>$null | Select-Object -First 1)).Trim()
        $imageReference = ([string](& docker inspect --format '{{.Config.Image}}' $containerId 2>$null | Select-Object -First 1)).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $imageId -or -not $imageReference) {
            throw "无法记录 $service 的旧镜像，更新未开始。"
        }
        $snapshots += [pscustomobject]@{ Service = $service; Id = $imageId; Reference = $imageReference }
    }
    return $snapshots
}

function New-ControllerDatabaseBackup([string[]] $ComposeArguments) {
    $containerId = ([string](& docker compose @ComposeArguments ps -q postgres 2>$null | Select-Object -First 1)).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $containerId) { throw '无法定位 PostgreSQL 容器，更新未开始。' }
    $backupDirectory = Assert-DeploymentChild (Join-Path $ProjectRoot 'backups')
    if (Test-Path -LiteralPath $backupDirectory) {
        if (-not (Test-Path -LiteralPath $backupDirectory -PathType Container)) { throw '数据库备份路径不是目录。' }
        Assert-NoReparsePoint $backupDirectory '数据库备份目录'
    }
    else {
        New-Item -ItemType Directory -Path $backupDirectory | Out-Null
    }
    $numericSuffix = '{0}{1}' -f $PID, [DateTime]::UtcNow.Ticks
    $identifier = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + $numericSuffix
    $containerPath = "/tmp/xingchen-controller-update-$identifier.sql"
    $partial = Join-Path $backupDirectory ("xingchen-monitor-$identifier.sql.partial")
    $final = Join-Path $backupDirectory ("xingchen-monitor-$identifier.sql")
    $dumpScript = 'umask 077; export PGPASSWORD="${POSTGRES_PASSWORD:?}"; exec pg_dump --clean --if-exists --no-owner --no-privileges -U "${POSTGRES_USER:-xingchen}" -d "${POSTGRES_DB:-xingchen_monitor}" -f "$1"'
    try {
        & docker exec $containerId sh -ec $dumpScript sh $containerPath | Out-Null
        $dumpStatus = $LASTEXITCODE
        if ($dumpStatus -ne 0) { throw 'PostgreSQL 备份命令失败，更新未开始。' }
        & docker cp "${containerId}:$containerPath" $partial | Out-Null
        $copyStatus = $LASTEXITCODE
        if ($copyStatus -ne 0 -or -not (Test-Path -LiteralPath $partial -PathType Leaf) -or (Get-Item -LiteralPath $partial).Length -lt 1) {
            throw 'PostgreSQL 备份复制失败或备份为空，更新未开始。'
        }
        Move-Item -LiteralPath $partial -Destination $final
        return $final
    }
    finally {
        & docker exec $containerId rm -f $containerPath *> $null
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}

function Invoke-ControllerCompose([string[]] $ComposeArguments, [string[]] $Services, [bool] $IsRunner) {
    $arguments = @('up', '-d', '--force-recreate', '--pull', 'never', '--no-build', '--wait', '--wait-timeout', '300')
    if (-not $IsRunner) { $arguments += '--remove-orphans' }
    & docker compose @ComposeArguments @arguments @Services | Out-Host
    $status = $LASTEXITCODE
    return $status -eq 0
}

function Invoke-OfflineBundleApply($Metadata) {
    $services = @('setup', 'server', 'web')
    $images = @{
        setup = "ghcr.io/pstarchen/monitor-for-server-setup:$($Metadata.Version)"
        server = "ghcr.io/pstarchen/monitor-for-server-server:$($Metadata.Version)"
        web = "ghcr.io/pstarchen/monitor-for-server-web:$($Metadata.Version)"
        agent = "ghcr.io/pstarchen/monitor-for-server-agent:$($Metadata.Version)"
        postgres = 'postgres:16-alpine'
        redis = 'redis:7.4-alpine'
    }
    $settings = @{
        XINGCHEN_TARGET_VERSION = $Metadata.Version
        XINGCHEN_SETUP_IMAGE = $images.setup
        XINGCHEN_SERVER_IMAGE = $images.server
        XINGCHEN_WEB_IMAGE = $images.web
        XINGCHEN_AGENT_IMAGE = $images.agent
        XINGCHEN_POSTGRES_IMAGE = $images.postgres
        XINGCHEN_REDIS_IMAGE = $images.redis
        XINGCHEN_RELEASE_MANIFEST_PATH = '/workspace/release/manifest.json'
        XINGCHEN_RELEASE_MANIFEST_SHA256 = $Metadata.ManifestSHA256
        XINGCHEN_AGENT_OFFLINE_DIR = '/workspace/release/assets'
        XINGCHEN_RELEASE_MANIFEST_URLS = ''
        XINGCHEN_AGENT_RELEASE_BASE_URLS = ''
        XINGCHEN_CONTROLLER_ALLOW_GITHUB_API = 'false'
        XINGCHEN_NETWORK_MODE = 'offline'
        XINGCHEN_ALLOW_GITEE = 'false'
    }
    $composeArguments = @('-f', $composeFile, '--project-directory', $ProjectRoot, '--env-file', $envFile)
    $loadTimeout = 900
    $configuredLoadTimeout = [Environment]::GetEnvironmentVariable('XINGCHEN_UPDATE_LOAD_TIMEOUT_SECONDS')
    if (-not $configuredLoadTimeout) { $configuredLoadTimeout = Get-EnvValueFromFile $envFile 'XINGCHEN_UPDATE_LOAD_TIMEOUT_SECONDS' '900' }
    if (-not [int]::TryParse($configuredLoadTimeout, [ref]$loadTimeout) -or $loadTimeout -lt 1) {
        throw 'XINGCHEN_UPDATE_LOAD_TIMEOUT_SECONDS 必须是正整数。'
    }
    $minimumFreeBytes = 0L
    $configuredMinimumFreeBytes = [Environment]::GetEnvironmentVariable('XINGCHEN_UPDATE_MIN_FREE_BYTES')
    if (-not $configuredMinimumFreeBytes) {
        $configuredMinimumFreeBytes = Get-EnvValueFromFile $envFile 'XINGCHEN_UPDATE_MIN_FREE_BYTES' '1073741824'
    }
    if (-not [long]::TryParse($configuredMinimumFreeBytes, [ref]$minimumFreeBytes) -or $minimumFreeBytes -lt 1) {
        throw 'XINGCHEN_UPDATE_MIN_FREE_BYTES 必须是正整数。'
    }
    function Assert-OfflineFreeSpace([string] $Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $drive = (Get-Item -LiteralPath $Path).PSDrive
        if ($null -eq $drive -or $null -eq $drive.Free) { throw "无法确认 $Path 的可用磁盘空间。" }
        if ([long]$drive.Free -lt $minimumFreeBytes) {
            throw "可用磁盘空间不足：$Path 需要至少 $minimumFreeBytes 字节，当前约 $([long]$drive.Free) 字节。"
        }
    }
    Assert-OfflineFreeSpace $ProjectRoot
    $dockerRootOutput = @(& docker info --format '{{.DockerRootDir}}' 2>$null | Select-Object -First 1)
    $dockerInfoSucceeded = $LASTEXITCODE -eq 0
    $dockerRoot = if ($dockerRootOutput.Count -eq 0) { '' } else { [System.Convert]::ToString($dockerRootOutput[0]).Trim() }
    if ($dockerInfoSucceeded -and $dockerRoot -and (Test-Path -LiteralPath $dockerRoot)) {
        Assert-OfflineFreeSpace $dockerRoot
    }

    $composeSnapshot = Get-FileSnapshot $composeFile
    $envSnapshot = Get-FileSnapshot $envFile
    $updaterPath = Join-Path $ProjectRoot 'deploy/update-controller.ps1'
    $updaterSnapshot = Get-FileSnapshot $updaterPath
    $releasePath = Assert-DeploymentChild (Join-Path $ProjectRoot 'release')
    [void](Assert-DeploymentChild (Join-Path $ProjectRoot 'backups'))
    if (Test-Path -LiteralPath $releasePath) {
        if (-not (Test-Path -LiteralPath $releasePath -PathType Container)) { throw '现有 release 路径不是目录。' }
        Assert-NoReparsePoint $releasePath '现有 release 目录'
        foreach ($item in Get-ChildItem -LiteralPath $releasePath -Recurse -Force) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw '现有 release 目录包含重解析点，拒绝自动替换。' }
        }
    }
    $releaseOriginallyExisted = Test-Path -LiteralPath $releasePath -PathType Container
    $oldImages = Get-RunningImageSnapshots $services $composeArguments
    $processEnvironment = Get-ProcessEnvironmentSnapshot @($settings.Keys)

    $transactionRoot = Assert-DeploymentChild (Join-Path $ProjectRoot ('.controller-update-transaction-' + [Guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $transactionRoot | Out-Null
    [void](Assert-DeploymentChild $transactionRoot)
    $releaseSnapshotPath = Join-Path $transactionRoot 'release.snapshot'
    $releaseCandidatePath = Join-Path $transactionRoot 'release.candidate'
    $releaseFailedPath = Join-Path $transactionRoot 'release.failed'
    if ($releaseOriginallyExisted) { Copy-Item -LiteralPath $releasePath -Destination $releaseSnapshotPath -Recurse }
    Copy-Item -LiteralPath (Join-Path $OfflineBundle 'release') -Destination $releaseCandidatePath -Recurse
    $candidateComposeBytes = [System.IO.File]::ReadAllBytes((Join-Path $OfflineBundle 'docker-compose.yml'))
    $candidateUpdaterBytes = [System.IO.File]::ReadAllBytes((Join-Path $OfflineBundle 'deploy/update-controller.ps1'))
    $candidateEnvBytes = New-UpdatedEnvBytes $envFile $settings
    $candidateEnvPath = Join-Path $transactionRoot 'candidate.env'
    [System.IO.File]::WriteAllBytes($candidateEnvPath, $candidateEnvBytes)
    $candidateComposePath = Join-Path $OfflineBundle 'docker-compose.yml'
    $candidateComposeArguments = @('-f', $candidateComposePath, '--project-directory', $ProjectRoot, '--env-file', $candidateEnvPath)

    $backupPath = $null
    $loadStarted = $false
    $deploymentFilesChanged = $false
    $releaseOriginalMoved = $false
    $releaseCandidateInstalled = $false
    $rollbackCompleted = $false
    $succeeded = $false
    try {
        $backupPath = New-ControllerDatabaseBackup $composeArguments
        Write-Host "数据库备份已保存：$backupPath"

        $loadStarted = $true
        Invoke-DockerLoad (Join-Path $OfflineBundle 'images/controller-images.tar') $loadTimeout
        Test-LoadedBundleImages $images $Metadata.Version $Metadata.Architecture
        Set-ProcessEnvironment $settings
        $configuredImages = @(& docker compose @candidateComposeArguments config --images 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        if ($LASTEXITCODE -ne 0) { throw '无法解析候选 Compose 镜像。' }
        $allowedImages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($image in $images.Values) { [void]$allowedImages.Add([string]$image) }
        $actualImages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($image in $configuredImages) {
            if (-not $allowedImages.Contains($image)) { throw "候选 Compose 引用了离线 bundle 之外的镜像：$image" }
            [void]$actualImages.Add($image)
        }
        foreach ($name in @('setup', 'server', 'web', 'postgres', 'redis')) {
            if (-not $actualImages.Contains([string]$images[$name])) {
                throw "候选 Compose 缺少必要镜像：$($images[$name])"
            }
        }
        & docker compose @candidateComposeArguments config --quiet
        if ($LASTEXITCODE -ne 0) { throw '候选 Compose 配置校验失败。' }

        if ($releaseOriginallyExisted) {
            [void](Assert-DeploymentChild $releasePath)
            Move-Item -LiteralPath $releasePath -Destination $releaseFailedPath
            $releaseOriginalMoved = $true
        }
        [void](Assert-DeploymentChild $releaseCandidatePath)
        [void](Assert-DeploymentChild $releasePath)
        Move-Item -LiteralPath $releaseCandidatePath -Destination $releasePath
        $releaseCandidateInstalled = $true
        $deploymentFilesChanged = $true
        Write-FileAtomically $composeFile $candidateComposeBytes
        Write-FileAtomically $updaterPath $candidateUpdaterBytes
        Write-FileAtomically $envFile $candidateEnvBytes

        if (-not (Invoke-ControllerCompose $composeArguments $services $runnerMode)) {
            throw '候选总控未通过 Compose 健康检查。'
        }
        $succeeded = $true
        Write-Host "总控已从离线 bundle 更新到 $($Metadata.Version)。数据库备份保留在：$backupPath"
    }
    catch {
        $failure = $_
        if (-not $loadStarted -and -not $deploymentFilesChanged) { throw }
        Write-Warning '离线总控更新失败，正在恢复原始配置、文件和运行镜像；数据库不会自动恢复。'
        $rollbackFailed = $false
        try { Restore-ProcessEnvironment $processEnvironment } catch { $rollbackFailed = $true; Write-Warning $_.Exception.Message }
        try { Restore-FileSnapshot $envFile $envSnapshot } catch { $rollbackFailed = $true; Write-Warning $_.Exception.Message }
        try { Restore-FileSnapshot $composeFile $composeSnapshot } catch { $rollbackFailed = $true; Write-Warning $_.Exception.Message }
        try { Restore-FileSnapshot $updaterPath $updaterSnapshot } catch { $rollbackFailed = $true; Write-Warning $_.Exception.Message }
        try {
            if ($releaseCandidateInstalled -and (Test-Path -LiteralPath $releasePath)) {
                [void](Assert-DeploymentChild $releasePath)
                $failedCandidate = Join-Path $transactionRoot 'release.candidate.failed'
                Move-Item -LiteralPath $releasePath -Destination $failedCandidate
            }
            if ($releaseOriginallyExisted) {
                if ($releaseOriginalMoved -and (Test-Path -LiteralPath $releaseFailedPath -PathType Container)) {
                    Move-Item -LiteralPath $releaseFailedPath -Destination $releasePath
                }
                elseif (-not (Test-Path -LiteralPath $releasePath -PathType Container)) {
                    if (-not (Test-Path -LiteralPath $releaseSnapshotPath -PathType Container)) { throw 'release 快照缺失。' }
                    Move-Item -LiteralPath $releaseSnapshotPath -Destination $releasePath
                }
            }
        }
        catch { $rollbackFailed = $true; Write-Warning $_.Exception.Message }
        foreach ($oldImage in $oldImages) {
            if ($oldImage.Reference.Contains('@') -or $oldImage.Reference.StartsWith('sha256:')) { continue }
            & docker tag $oldImage.Id $oldImage.Reference
            if ($LASTEXITCODE -ne 0) { $rollbackFailed = $true; Write-Warning "恢复 $($oldImage.Service) 旧镜像标签失败。" }
        }
        if (-not $rollbackFailed -and -not (Invoke-ControllerCompose $composeArguments $services $runnerMode)) { $rollbackFailed = $true }
        $backupMessage = if ($backupPath) { "数据库备份位于 $backupPath；仅在人工评估迁移兼容性后恢复。" } else { '没有可用数据库备份。' }
        if ($rollbackFailed) {
            [Console]::Error.WriteLine("离线更新失败且自动恢复未通过健康检查：$($failure.Exception.Message) $backupMessage")
            exit 11
        }
        $rollbackCompleted = $true
        [Console]::Error.WriteLine("离线更新失败，原始部署已恢复并通过健康检查：$($failure.Exception.Message) $backupMessage")
        exit 10
    }
    finally {
        if ($succeeded) { Restore-ProcessEnvironment $processEnvironment }
        if (Test-Path -LiteralPath $candidateEnvPath) {
            [void](Assert-DeploymentChild $candidateEnvPath)
            Remove-Item -LiteralPath $candidateEnvPath -Force
        }
        if (($succeeded -or $rollbackCompleted -or -not $loadStarted) -and (Test-Path -LiteralPath $transactionRoot)) {
            [void](Assert-DeploymentChild $transactionRoot)
            Remove-Item -LiteralPath $transactionRoot -Recurse -Force
        }
    }
}

Push-Location $ProjectRoot
$lockPath = Join-Path $ProjectRoot '.controller-update.lock'
$lockStream = $null
try {
    try {
        $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        throw '已有总控更新任务正在执行，请稍后重试。'
    }
    if ($offlineBundleWasProvided) {
        Invoke-OfflineBundleApply $bundleMetadata
        return
    }
    $composeArgs = @('-f', $composeFile, '--project-directory', $ProjectRoot, '--env-file', $envFile)
    function Read-UpdateSetting([string] $Name, [string] $DefaultValue = '') {
        $value = [Environment]::GetEnvironmentVariable($Name)
        if (-not $value -and (Test-Path -LiteralPath $envFile)) {
            $line = Select-String -LiteralPath $envFile -Pattern "^$Name=(.*)$" | Select-Object -First 1
            if ($line) { $value = $line.Matches[0].Groups[1].Value.Trim('"') }
        }
        if ($value) { return $value }
        return $DefaultValue
    }
    function Read-FileSetting([string] $Name) {
        if (-not (Test-Path -LiteralPath $envFile)) { return '' }
        $line = Select-String -LiteralPath $envFile -Pattern "^$Name=(.*)$" | Select-Object -First 1
        if ($line) { return $line.Matches[0].Groups[1].Value.Trim('"') }
        return ''
    }
    function Set-UpdateSettings([string[]] $Names, [string[]] $Values) {
        if (-not (Test-Path -LiteralPath $envFile)) { throw '总控 .env 不存在，请先完成安装。' }
        if ($Names.Count -eq 0 -or $Names.Count -ne $Values.Count) { throw '环境设置必须成对提供。' }
        $settings = @{}
        for ($index = 0; $index -lt $Names.Count; $index++) {
            $name = $Names[$index]
            $value = $Values[$index]
            if ($name -notmatch '^[A-Z][A-Z0-9_]*$' -or $value.Contains("`r") -or $value.Contains("`n") -or $value.Contains('"')) {
                throw "拒绝写入无效的环境设置：$name"
            }
            $settings[$name] = $value
        }
        $lines = [System.Collections.Generic.List[string]]::new()
        $found = @{}
        foreach ($line in [System.IO.File]::ReadAllLines($envFile)) {
            $matched = $false
            foreach ($name in $Names) {
                if ($line.StartsWith("$name=")) {
                    if (-not $found.ContainsKey($name)) { [void] $lines.Add("$name=`"$($settings[$name])`"") }
                    $found[$name] = $true
                    $matched = $true
                    break
                }
            }
            if (-not $matched) { [void] $lines.Add($line) }
        }
        foreach ($name in $Names) {
            if (-not $found.ContainsKey($name)) { [void] $lines.Add("$name=`"$($settings[$name])`"") }
        }
        $temporary = Join-Path $projectRoot ('.env.controller-update.' + [Guid]::NewGuid().ToString('N'))
        try {
            [System.IO.File]::WriteAllLines($temporary, $lines, [System.Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $temporary -Destination $envFile -Force
        }
        finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
    }
    function Set-UpdateSetting([string] $Name, [string] $Value) {
        Set-UpdateSettings @($Name) @($Value)
    }
    $networkMode = ([string](Read-UpdateSetting 'XINGCHEN_NETWORK_MODE' 'public')).Trim().ToLowerInvariant()
    if ($networkMode -notin @('public', 'internal', 'offline')) {
        throw 'XINGCHEN_NETWORK_MODE 必须是 public、internal 或 offline。'
    }
    $allowGiteeValue = ([string](Read-UpdateSetting 'XINGCHEN_ALLOW_GITEE' 'false')).Trim().ToLowerInvariant()
    if ($allowGiteeValue -notin @('true', 'false')) { throw 'XINGCHEN_ALLOW_GITEE 必须是 true 或 false。' }
    $allowGitee = $allowGiteeValue -eq 'true'
    if ($Offline) {
        $networkMode = 'offline'
        $NoSourceFallback = $true
    }
    elseif ($networkMode -eq 'offline') {
        $Offline = $true
        $NoSourceFallback = $true
        if ($Build -or $SourceBuild -or $Auto) { throw 'offline 网络模式不能执行自动更新、镜像拉取或源码构建。' }
    }
    if ($networkMode -eq 'internal') {
        $NoSourceFallback = $true
        if ($Build -or $SourceBuild) {
            throw 'internal 网络模式禁止 -Build 和 -SourceBuild；请使用已导入镜像或内部 Registry。'
        }
        if ($Auto) {
            throw 'internal 网络模式不允许由此脚本启动可能隐式拉取镜像的自动更新。'
        }
    }
    function Test-NetworkHostMatches([string] $HostName, [string] $Suffix) {
        $hostValue = $HostName.Trim().TrimEnd('.').ToLowerInvariant()
        $suffixValue = $Suffix.Trim().TrimEnd('.').ToLowerInvariant()
        return $hostValue -eq $suffixValue -or $hostValue.EndsWith(".$suffixValue", [System.StringComparison]::Ordinal)
    }
    function Test-ForbiddenPublicHost([string] $HostName) {
        foreach ($suffix in @(
                'github.com', 'githubusercontent.com', 'githubassets.com', 'ghcr.io',
                'docker.io', 'docker.com', 'ghcr.1ms.run', 'ghcr.nju.edu.cn', 'ghcr.m.daocloud.io'
            )) {
            if (Test-NetworkHostMatches $HostName $suffix) { return $true }
        }
        return $false
    }
    if ((Test-Path -LiteralPath $envFile) -and -not (Select-String -LiteralPath $envFile -Pattern '^COMPOSE_PROJECT_NAME=' -Quiet)) {
        $legacyDatabase = Read-UpdateSetting 'POSTGRES_DB'
        $legacyVolume = (& docker volume inspect 'guanlan-monitor_postgres-data' 2>$null)
        $projectName = if ($legacyDatabase -eq 'guanlan_monitor' -or $legacyVolume) { 'guanlan-monitor' } else { 'xingchen-monitor' }
        Set-UpdateSetting 'COMPOSE_PROJECT_NAME' $projectName
    }
    # Registry mirrors should fail over quickly, while the official registry
    # keeps a longer window for constrained international links.
    $pullTimeoutSeconds = [int](Read-UpdateSetting 'XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS' '180')
    $mirrorTimeoutSeconds = [int](Read-UpdateSetting 'XINGCHEN_UPDATE_MIRROR_TIMEOUT_SECONDS' '45')
    $composeTimeoutSeconds = [int](Read-UpdateSetting 'XINGCHEN_UPDATE_COMPOSE_TIMEOUT_SECONDS' '900')
    if ($pullTimeoutSeconds -lt 1 -or $mirrorTimeoutSeconds -lt 1 -or $composeTimeoutSeconds -lt 1) { throw '更新超时必须是正整数秒数。' }
    $minimumFreeBytes = 0L
    if (-not [long]::TryParse((Read-UpdateSetting 'XINGCHEN_UPDATE_MIN_FREE_BYTES' '1073741824'), [ref]$minimumFreeBytes) -or $minimumFreeBytes -lt 1) {
        throw 'XINGCHEN_UPDATE_MIN_FREE_BYTES 必须是正整数。'
    }
    function Assert-FreeSpace([string] $Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $drive = (Get-Item -LiteralPath $Path).PSDrive
        if ($null -eq $drive -or $null -eq $drive.Free) { throw "无法确认 $Path 的可用磁盘空间。" }
        if ([long]$drive.Free -lt $minimumFreeBytes) {
            throw "可用磁盘空间不足：$Path 需要至少 $minimumFreeBytes 字节，当前约 $([long]$drive.Free) 字节。"
        }
    }
    Assert-FreeSpace $projectRoot
    $dockerRootOutput = @(& docker info --format '{{.DockerRootDir}}' 2>$null | Select-Object -First 1)
    $dockerRoot = if ($dockerRootOutput.Count -eq 0) { '' } else { [System.Convert]::ToString($dockerRootOutput[0]).Trim() }
    if ($LASTEXITCODE -eq 0 -and $dockerRoot -and (Test-Path -LiteralPath $dockerRoot)) { Assert-FreeSpace $dockerRoot }
    $env:DOCKER_CLIENT_TIMEOUT = [string]$pullTimeoutSeconds
    $env:COMPOSE_HTTP_TIMEOUT = [string]$composeTimeoutSeconds
    if ($Auto) {
        if (-not (Test-Path -LiteralPath $envFile)) { throw '总控 .env 不存在，请先完成安装。' }
        Set-UpdateSetting 'CONTROLLER_AUTO_UPDATE' 'true'
        foreach ($taskName in @('XingchenControllerUpdate', 'GuanlanControllerUpdate')) {
            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            }
        }
        & docker compose @composeArgs up -d --no-deps --wait --wait-timeout 300 setup
        if ($LASTEXITCODE -ne 0) { throw '自动更新设置已保存，但 setup 服务启动失败。' }
        Write-Host '总控自动更新已启用：每天 04:00 按 APP_TIMEZONE 执行。'
        exit 0
    }
    $services = @('setup', 'server', 'web')
    $imageKeys = @('XINGCHEN_SETUP_IMAGE', 'XINGCHEN_SERVER_IMAGE', 'XINGCHEN_WEB_IMAGE')
    $imageDefaults = @(
        'ghcr.io/pstarchen/monitor-for-server-setup:v1.20.17',
        'ghcr.io/pstarchen/monitor-for-server-server:v1.20.17',
        'ghcr.io/pstarchen/monitor-for-server-web:v1.20.17'
    )
    $sourceContexts = @('.', 'server', 'web')
    $sourceDockerfiles = @('setup/Dockerfile', '', '')
    $targetVersion = Read-UpdateSetting 'XINGCHEN_TARGET_VERSION'
    if ($targetVersion) {
        if ($targetVersion -notmatch '^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'XINGCHEN_TARGET_VERSION 必须是稳定语义版本，例如 v1.20.5。' }
        $targetVersion = "v$($Matches[1]).$($Matches[2]).$($Matches[3])"
        $sourceRef = $targetVersion
    }
    else {
        $sourceRef = Read-UpdateSetting 'XINGCHEN_SOURCE_REF' 'main'
    }
    if ($Offline -and -not $targetVersion) { throw '离线模式要求通过 XINGCHEN_TARGET_VERSION 指定稳定版本。' }
    if ($sourceRef -notmatch '^[a-zA-Z0-9._/-]+$' -or $sourceRef.StartsWith('-') -or $sourceRef.Contains('..')) {
        throw '总控源码 Git ref 无效。'
    }
    $sourceRepositoryValue = [string](Read-UpdateSetting 'XINGCHEN_SOURCE_REPOSITORIES')
    $sourceRepositories = @()
    if ($sourceRepositoryValue) {
        $sourceRepositories = @($sourceRepositoryValue.Split(',') | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }
    if ($SourceBuild -and $sourceRepositories.Count -eq 0) {
        throw '源码构建要求显式配置允许访问的 XINGCHEN_SOURCE_REPOSITORIES。'
    }
    if ($sourceRepositories.Count -eq 0) {
        $NoSourceFallback = $true
    }
    foreach ($repository in $sourceRepositories) {
        try { $uri = [System.Uri]::new($repository, [System.UriKind]::Absolute) }
        catch { throw "总控源码仓库地址无效：$repository" }
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('https', 'ssh') -or [string]::IsNullOrWhiteSpace($uri.Host)) {
            throw "总控源码仓库地址无效：$repository"
        }
        $hostName = ([string]$uri.Host).ToLowerInvariant().TrimEnd('.')
        if ((Test-NetworkHostMatches $hostName 'gitee.com') -and -not $allowGitee) {
            throw 'Gitee 源仅在 XINGCHEN_ALLOW_GITEE=true 时可用。'
        }
        if ($networkMode -eq 'internal' -and (Test-ForbiddenPublicHost $hostName)) {
            throw "internal 网络模式拒绝公共 GitHub 源或 Docker 公共源：$repository"
        }
    }
    $resolvedImages = @()
    for ($index = 0; $index -lt $imageKeys.Count; $index++) {
        $resolvedImages += (Read-UpdateSetting $imageKeys[$index] $imageDefaults[$index])
    }

    function ConvertTo-VersionedReference([string] $Image) {
        if (-not $targetVersion -or $Image.Contains('@')) { return $Image }
        $slash = $Image.LastIndexOf('/')
        $colon = $Image.LastIndexOf(':')
        if ($colon -gt $slash) { return $Image.Substring(0, $colon) + ":$targetVersion" }
        return "${Image}:$targetVersion"
    }
    $candidateImages = @($resolvedImages | ForEach-Object { ConvertTo-VersionedReference $_ })
    $dependencyKeys = @('XINGCHEN_POSTGRES_IMAGE', 'XINGCHEN_REDIS_IMAGE')
    $resolvedDependencyImages = @(
        (Read-UpdateSetting 'XINGCHEN_POSTGRES_IMAGE' 'postgres:16-alpine'),
        (Read-UpdateSetting 'XINGCHEN_REDIS_IMAGE' 'redis:7.4-alpine')
    )

    function ConvertTo-ManagedDependencyReference([string] $Image) {
        if (-not $targetVersion -or $Image.Contains('@')) { return $Image }
        $slash = $Image.LastIndexOf('/')
        if ($slash -lt 0) { return $Image }
        $leaf = $Image.Substring($slash + 1)
        $colon = $leaf.LastIndexOf(':')
        if ($colon -lt 0) { return $Image }
        $repository = $leaf.Substring(0, $colon)
        if ($repository -notin @('monitor-for-server-postgres', 'monitor-for-server-redis')) { return $Image }
        return $Image.Substring(0, $slash + 1 + $colon) + ":$targetVersion"
    }
    $dependencyImages = @($resolvedDependencyImages | ForEach-Object { ConvertTo-ManagedDependencyReference $_ })

    $controllerMirrorValue = [string](Read-UpdateSetting 'XINGCHEN_CONTROLLER_IMAGE_MIRRORS')
    $controllerImageMirrors = @()
    if ($controllerMirrorValue) {
        $controllerImageMirrors = @($controllerMirrorValue.Split(',') | ForEach-Object { ([string]$_).Trim().TrimEnd('/') } | Where-Object { $_ })
    }

    function Assert-InternalImageReference([string] $Image, [bool] $AllowLogicalGhcr = $false) {
        if ([string]::IsNullOrWhiteSpace($Image) -or $Image -match '\s' -or $Image.Contains('://')) {
            if ($networkMode -ne 'internal') { return }
            throw "internal 网络模式拒绝无效镜像引用：$Image"
        }
        $name = ($Image -split '@', 2)[0]
        if (-not $name.Contains('/')) {
            if ($networkMode -ne 'internal') { return }
            throw "internal 网络模式拒绝无 registry 的镜像引用：$Image"
        }
        $registry = ([string](($name -split '/', 2)[0])).ToLowerInvariant()
        if (-not ($registry.Contains('.') -or $registry.Contains(':') -or $registry -eq 'localhost')) {
            if ($networkMode -ne 'internal') { return }
            throw "internal 网络模式拒绝 Docker Hub 或无 registry 的镜像引用：$Image"
        }
        $registryHost = ([string](($registry -split ':', 2)[0])).TrimEnd('.')
        if ((Test-NetworkHostMatches $registryHost 'gitee.com') -and -not $allowGitee) {
            throw "Gitee Registry 仅在 XINGCHEN_ALLOW_GITEE=true 时可用：$Image"
        }
        if ($networkMode -ne 'internal') { return }
        if ($AllowLogicalGhcr -and $registryHost -eq 'ghcr.io') { return }
        if (Test-ForbiddenPublicHost $registryHost) {
            throw "internal 网络模式拒绝公共镜像源：$Image"
        }
    }

    if ($networkMode -eq 'internal') {
        foreach ($image in $candidateImages) {
            $isLogicalGhcr = ([string]$image).StartsWith('ghcr.io/', [System.StringComparison]::OrdinalIgnoreCase)
            Assert-InternalImageReference ([string]$image) $isLogicalGhcr
            if ($isLogicalGhcr) {
                $suffix = ([string]$image).Substring(8)
                foreach ($mirror in $controllerImageMirrors) {
                    Assert-InternalImageReference "$mirror/$suffix"
                }
            }
        }
        foreach ($image in $dependencyImages) { Assert-InternalImageReference ([string]$image) }
    }

    function Get-RunningServiceVersion([string] $Service) {
        $containerId = ([string] (& docker compose @composeArgs ps -q $Service 2>$null | Select-Object -First 1)).Trim()
        if (-not $containerId) { return $null }
        $actual = ([string] (& docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' $containerId 2>$null | Select-Object -First 1)).Trim().TrimStart('v')
        if ($actual -notmatch '^\d+\.\d+\.\d+$') { return $null }
        return "v$actual"
    }

    if ($targetVersion) {
        $runningVersion = Get-RunningServiceVersion 'server'
        if ($runningVersion -and ([Version] $targetVersion.TrimStart('v')) -lt ([Version] $runningVersion.TrimStart('v'))) {
            throw "拒绝将总控从 $runningVersion 降级到 $targetVersion。"
        }
        if ($Apply) {
            $allCurrent = $true
            foreach ($service in $services) {
                if ((Get-RunningServiceVersion $service) -ne $targetVersion) {
                    $allCurrent = $false
                    break
                }
            }
            if ($allCurrent) {
                for ($index = 0; $index -lt $resolvedDependencyImages.Count; $index++) {
                    if (-not [string]::Equals($resolvedDependencyImages[$index], $dependencyImages[$index], [System.StringComparison]::Ordinal)) {
                        $allCurrent = $false
                        break
                    }
                }
            }
            if ($allCurrent) {
                Write-Host "总控所有组件已是 $targetVersion，无需重复更新。"
                exit 0
            }
        }
    }

    function Invoke-DockerPull([string] $Image, [int] $TimeoutSeconds) {
        $docker = Get-Command docker -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $process = Start-Process -FilePath $docker.Source -ArgumentList @('pull', $Image) -NoNewWindow -PassThru
        $process.Handle | Out-Null
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            try { $process.WaitForExit() } catch { }
            Write-Warning "Docker 拉取超过 $TimeoutSeconds 秒，已切换下一个镜像源：$Image"
            return $false
        }
        $process.WaitForExit()
        $process.Refresh()
        return $process.ExitCode -eq 0
    }

    function Test-ImageVersion([string] $Image) {
        if (-not $targetVersion) { return $true }
        $inspectOutput = & docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' $Image 2>$null
        $inspectStatus = $LASTEXITCODE
        [string] $actual = $inspectOutput | Select-Object -First 1
        $actual = $actual.Trim()
        if ($inspectStatus -eq 0 -and $actual.TrimStart('v') -eq $targetVersion.TrimStart('v')) { return $true }
        Write-Warning "镜像版本不匹配：$Image 标记为 $(if ($actual) { $actual } else { 'unknown' })，期望 $targetVersion。"
        return $false
    }

    function Test-LocalCandidateImage([string] $Image) {
        & docker image inspect $Image *> $null
        if ($LASTEXITCODE -ne 0) { return $false }
        return (Test-ImageVersion $Image)
    }

    if ($networkMode -eq 'internal') {
        foreach ($image in $candidateImages) {
            $image = [string]$image
            if (-not $image.StartsWith('ghcr.io/', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if (Test-LocalCandidateImage $image) { continue }
            if ($NoMirror -or $controllerImageMirrors.Count -eq 0) {
                throw "internal 网络模式下本地缺少 GHCR 逻辑镜像，且未配置可用的内部镜像源：$image"
            }
        }
    }

    function Pull-Image([string] $Image) {
        $isLogicalGhcr = $Image.StartsWith('ghcr.io/', [System.StringComparison]::OrdinalIgnoreCase)
        if ($networkMode -eq 'internal' -and $isLogicalGhcr -and (Test-LocalCandidateImage $Image)) {
            Write-Host "使用本地 GHCR 逻辑镜像：$Image"
            return
        }
        if (-not $NoMirror -and $isLogicalGhcr) {
            $suffix = $Image.Substring(8)
            foreach ($mirror in $controllerImageMirrors) {
                $candidate = "$mirror/$suffix"
                Assert-InternalImageReference $candidate
                Write-Host "尝试$(if ($networkMode -eq 'internal') { '内部' } else { '国内' })镜像源：$candidate"
                if ((Invoke-DockerPull $candidate $mirrorTimeoutSeconds) -and (Test-ImageVersion $candidate)) {
                    & docker tag $candidate $Image
                    if ($LASTEXITCODE -eq 0) { return }
                }
            }
            if ($networkMode -eq 'internal') {
                throw "所有已配置的内部总控镜像源均不可用：$Image"
            }
        }
        elseif ($networkMode -eq 'internal' -and $isLogicalGhcr) {
            throw "internal 网络模式下本地缺少 GHCR 逻辑镜像，且内部镜像源已禁用：$Image"
        }
        Assert-InternalImageReference $Image
        Write-Host "尝试$(if ($networkMode -eq 'internal') { '内部' } else { '官方' })镜像源：$Image"
        if (-not (Invoke-DockerPull $Image $pullTimeoutSeconds)) { throw "镜像拉取失败：$Image" }
        if (-not (Test-ImageVersion $Image)) { throw "镜像版本校验失败：$Image" }
    }

    function Prepare-DependencyImages {
        foreach ($image in $dependencyImages) {
            Assert-InternalImageReference ([string]$image)
            & docker image inspect $image *> $null
            if ($LASTEXITCODE -eq 0) { continue }
            if ($Offline) { throw "离线基础镜像缺失：$image" }
            Write-Host "正在准备总控基础镜像：$image"
            if (-not (Invoke-DockerPull $image $pullTimeoutSeconds)) {
                throw "总控基础镜像不可用：$image；请配置内部镜像引用或使用完整离线包。"
            }
        }
    }

    function Remove-SourceBuildImages([string[]] $Images) {
        if ($Images.Count -gt 0) { & docker image rm -f @Images | Out-Null }
    }

    function Build-ImagesFromRepositories {
        foreach ($image in $candidateImages) {
            if ($image.Contains('@')) { throw "固定摘要镜像无法使用源码构建回退：$image" }
        }
        $buildVersion = if ($targetVersion) { $targetVersion } else { 'dev' }
        $buildPrefix = "xingchen-controller-source-$PID-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
        foreach ($repository in $sourceRepositories) {
            $temporaryImages = @()
            $success = $true
            Write-Host "正在尝试总控源码仓库：$repository ($sourceRef)"
            for ($index = 0; $index -lt $sourceContexts.Count; $index++) {
                $temporaryImage = "$buildPrefix-$index`:candidate"
                $temporaryImages += $temporaryImage
                $context = if ($sourceContexts[$index] -eq '.') { "${repository}#${sourceRef}" } else { "${repository}#${sourceRef}:$($sourceContexts[$index])" }
                $buildArguments = @('build')
                if ($networkMode -eq 'public') { $buildArguments += '--pull' }
                if ($sourceDockerfiles[$index]) { $buildArguments += @('--file', $sourceDockerfiles[$index]) }
                $buildArguments += @('--build-arg', "VERSION=$buildVersion", '--tag', $temporaryImage, $context)
                & docker @buildArguments
                if ($LASTEXITCODE -ne 0 -or -not (Test-ImageVersion $temporaryImage)) { $success = $false; break }
            }
            if ($success) {
                for ($index = 0; $index -lt $candidateImages.Count; $index++) {
                    & docker tag $temporaryImages[$index] $candidateImages[$index]
                    if ($LASTEXITCODE -ne 0) {
                        Remove-SourceBuildImages $temporaryImages
                        throw "源码镜像标签写入失败：$($candidateImages[$index])"
                    }
                }
                Remove-SourceBuildImages $temporaryImages
                return
            }
            Remove-SourceBuildImages $temporaryImages
        }
        throw '已配置的总控源码仓库均无法完成 Docker 构建。'
    }

    $previousImages = @()
    $previousTargetSetting = Read-FileSetting 'XINGCHEN_TARGET_VERSION'
    if ($Apply) {
        for ($index = 0; $index -lt $services.Count; $index++) {
            $containerId = ([string] (& docker compose @composeArgs ps -q $services[$index] 2>$null | Select-Object -First 1)).Trim()
            $imageId = if ($containerId) { ([string] (& docker inspect --format '{{.Image}}' $containerId 2>$null | Select-Object -First 1)).Trim() } else { '' }
            if (-not $imageId) { $imageId = ([string] (& docker image inspect --format '{{.Id}}' $resolvedImages[$index] 2>$null | Select-Object -First 1)).Trim() }
            if (-not $imageId) { throw "无法记录 $($services[$index]) 的旧镜像，更新未开始。" }
            $previousImages += $imageId
        }
        $databaseBackupPath = New-ControllerDatabaseBackup $composeArgs
        Write-Host "升级前数据库备份已保存：$databaseBackupPath"
    }

    if ($Offline) {
        foreach ($image in $candidateImages) {
            & docker image inspect $image | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-ImageVersion $image)) {
                throw "离线镜像缺失或版本不匹配：$image"
            }
        }
        Prepare-DependencyImages
    }
    elseif ($Build) {
        Prepare-DependencyImages
        $buildArguments = @('build')
        if ($networkMode -eq 'public') { $buildArguments += '--pull' }
        $buildArguments += $services
        & docker compose @composeArgs @buildArguments
        if ($LASTEXITCODE -ne 0) { throw '总控镜像构建失败。' }
    }
    elseif ($SourceBuild) {
        Prepare-DependencyImages
        Build-ImagesFromRepositories
    }
    else {
        Prepare-DependencyImages
        $pullFailed = $false
        foreach ($image in $candidateImages) {
            try { Pull-Image $image }
            catch {
                $pullFailed = $true
                Write-Warning $_.Exception.Message
                break
            }
        }
        if ($pullFailed) {
            if ($NoSourceFallback) { throw '总控镜像拉取失败，且源码构建回退已关闭。' }
            Write-Host '所有总控镜像源均不可用，开始从已配置的源码仓库构建 Docker 镜像。'
            Build-ImagesFromRepositories
        }
    }
    if ($targetVersion) {
        foreach ($image in $candidateImages) {
            if (-not (Test-ImageVersion $image)) { throw "准备后的镜像版本校验失败：$image" }
        }
    }
    if ($Apply) {
        $settingNames = @($imageKeys) + @($dependencyKeys)
        $settingValues = @($candidateImages) + @($dependencyImages)
        if ($targetVersion) {
            $settingNames += 'XINGCHEN_TARGET_VERSION'
            $settingValues += $targetVersion
        }
        Set-UpdateSettings $settingNames $settingValues
        for ($index = 0; $index -lt $imageKeys.Count; $index++) {
            [Environment]::SetEnvironmentVariable($imageKeys[$index], $candidateImages[$index], 'Process')
        }
        for ($index = 0; $index -lt $dependencyKeys.Count; $index++) {
            [Environment]::SetEnvironmentVariable($dependencyKeys[$index], $dependencyImages[$index], 'Process')
        }
        if ($targetVersion) {
            $env:XINGCHEN_TARGET_VERSION = $targetVersion
        }
        $composeApplyArguments = @('up', '-d', '--remove-orphans', '--wait', '--wait-timeout', '300')
        if ($Offline) { $composeApplyArguments += @('--pull', 'never') }
        & docker compose @composeArgs @composeApplyArguments $services
        if ($LASTEXITCODE -ne 0) {
            Write-Warning '总控健康检查失败，正在恢复更新前镜像。数据库不会自动回退。'
            $rollbackFailed = $false
            $rollbackImages = @()
            for ($index = 0; $index -lt $resolvedImages.Count; $index++) {
                $rollbackImage = if ($resolvedImages[$index].Contains('@')) { "xingchen-controller-rollback-$($services[$index]):$PID" } else { $resolvedImages[$index] }
                $rollbackImages += $rollbackImage
                & docker tag $previousImages[$index] $rollbackImage
                if ($LASTEXITCODE -ne 0) { $rollbackFailed = $true }
            }
            if (-not $rollbackFailed) {
                $rollbackNames = @($imageKeys) + @($dependencyKeys) + @('XINGCHEN_TARGET_VERSION')
                $rollbackValues = @($rollbackImages) + @($resolvedDependencyImages) + @($previousTargetSetting)
                Set-UpdateSettings $rollbackNames $rollbackValues
                for ($index = 0; $index -lt $imageKeys.Count; $index++) {
                    [Environment]::SetEnvironmentVariable($imageKeys[$index], $rollbackImages[$index], 'Process')
                }
                for ($index = 0; $index -lt $dependencyKeys.Count; $index++) {
                    [Environment]::SetEnvironmentVariable($dependencyKeys[$index], $resolvedDependencyImages[$index], 'Process')
                }
                $env:XINGCHEN_TARGET_VERSION = $previousTargetSetting
                & docker compose @composeArgs @composeApplyArguments $services
                $rollbackFailed = $LASTEXITCODE -ne 0
            }
            if ($rollbackFailed) { throw '总控更新失败，且镜像自动恢复未通过健康检查；不要在未评估迁移兼容性前恢复数据库。' }
            throw '总控更新失败，旧镜像已恢复；如新版本执行过数据库迁移，请人工确认兼容性。'
        }
        Write-Host '总控服务已更新并重启。'
    }
    else {
        Write-Host '总控镜像检查完成；如需使新镜像生效，请运行：.\deploy\update-controller.ps1 -Apply'
    }
}
finally {
    if ($lockStream) { $lockStream.Dispose() }
    Pop-Location
}
