[CmdletBinding()]
param(
    [switch] $Check,
    [switch] $Apply,
    [switch] $Auto,
    [switch] $Build,
    [switch] $SourceBuild,
    [switch] $Offline,
    [switch] $NoMirror,
    [switch] $NoSourceFallback
)

$ErrorActionPreference = 'Stop'
if ($Build -and $SourceBuild) { throw '-Build 与 -SourceBuild 不能同时使用。' }
if ($Offline -and ($Build -or $SourceBuild -or $Auto)) { throw '-Offline 不能与 -Build、-SourceBuild 或 -Auto 同时使用。' }
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw '需要安装 Docker Engine。' }
& docker compose version | Out-Null
if ($LASTEXITCODE -ne 0) { throw '需要 Docker Compose v2。' }

if (-not $Check -and -not $Apply) { $Check = $true }
Push-Location $projectRoot
$lockPath = Join-Path $projectRoot '.controller-update.lock'
$lockStream = $null
try {
    try {
        $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        throw '已有总控更新任务正在执行，请稍后重试。'
    }
    $composeArgs = @()
    $envFile = Join-Path $projectRoot '.env'
    if (Test-Path -LiteralPath $envFile) { $composeArgs += @('--env-file', $envFile) }
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
    if (Test-Path -LiteralPath $envFile -and -not (Select-String -LiteralPath $envFile -Pattern '^COMPOSE_PROJECT_NAME=' -Quiet)) {
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
    $dockerRoot = ([string](& docker info --format '{{.DockerRootDir}}' 2>$null | Select-Object -First 1)).Trim()
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
        'ghcr.io/pstarchen/monitor-for-server-setup:v1.20.12',
        'ghcr.io/pstarchen/monitor-for-server-server:v1.20.12',
        'ghcr.io/pstarchen/monitor-for-server-web:v1.20.12'
    )
    $sourceContexts = @('setup', 'server', 'web')
    $targetVersion = Read-UpdateSetting 'XINGCHEN_TARGET_VERSION'
    if ($targetVersion) {
        if ($targetVersion -notmatch '^v?(\d+)\.(\d+)\.(\d+)$') { throw 'XINGCHEN_TARGET_VERSION 必须是稳定语义版本，例如 v1.20.5。' }
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
    $sourceRepositories = @((Read-UpdateSetting 'XINGCHEN_SOURCE_REPOSITORIES' 'https://gitee.com/starchen520/monitor-for-server.git').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($sourceRepositories.Count -eq 0) { throw '总控源码仓库地址不能为空。' }
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
    $dependencyImages = @(
        (Read-UpdateSetting 'XINGCHEN_POSTGRES_IMAGE' 'postgres:16-alpine'),
        (Read-UpdateSetting 'XINGCHEN_REDIS_IMAGE' 'redis:7.4-alpine')
    )

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
                Write-Host "总控所有组件已是 $targetVersion，无需重复更新。"
                exit 0
            }
        }
    }

    function Invoke-DockerPull([string] $Image, [int] $TimeoutSeconds) {
        $process = Start-Process -FilePath 'docker' -ArgumentList @('pull', $Image) -NoNewWindow -PassThru
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            try { $process.WaitForExit() } catch { }
            Write-Warning "Docker 拉取超过 $TimeoutSeconds 秒，已切换下一个镜像源：$Image"
            return $false
        }
        return $process.ExitCode -eq 0
    }

    function Test-ImageVersion([string] $Image) {
        if (-not $targetVersion) { return $true }
        $actual = ([string](& docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' $Image 2>$null | Select-Object -First 1)).Trim()
        if ($LASTEXITCODE -eq 0 -and $actual.TrimStart('v') -eq $targetVersion.TrimStart('v')) { return $true }
        Write-Warning "镜像版本不匹配：$Image 标记为 $(if ($actual) { $actual } else { 'unknown' })，期望 $targetVersion。"
        return $false
    }

    function Pull-Image([string] $Image) {
        if (-not $NoMirror -and $Image.StartsWith('ghcr.io/')) {
            $suffix = $Image.Substring(7)
            $mirrorValue = Read-UpdateSetting 'XINGCHEN_CONTROLLER_IMAGE_MIRRORS'
            $mirrors = if ($mirrorValue) { $mirrorValue.Split(',') } else { @() }
            foreach ($mirror in $mirrors) {
                $candidate = $mirror.TrimEnd('/') + '/' + $suffix
                Write-Host "尝试国内镜像源：$candidate"
                if ((Invoke-DockerPull $candidate $mirrorTimeoutSeconds) -and (Test-ImageVersion $candidate)) {
                    & docker tag $candidate $Image
                    if ($LASTEXITCODE -eq 0) { return }
                }
            }
        }
        Write-Host "尝试官方镜像源：$Image"
        if (-not (Invoke-DockerPull $Image $pullTimeoutSeconds)) { throw "镜像拉取失败：$Image" }
        if (-not (Test-ImageVersion $Image)) { throw "镜像版本校验失败：$Image" }
    }

    function Prepare-DependencyImages {
        foreach ($image in $dependencyImages) {
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
                $context = "${repository}#${sourceRef}:$($sourceContexts[$index])"
                & docker build --pull --build-arg "VERSION=$buildVersion" --tag $temporaryImage $context
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
        & docker compose @composeArgs build --pull $services
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
        $settingNames = @($imageKeys)
        $settingValues = @($candidateImages)
        if ($targetVersion) {
            $settingNames += 'XINGCHEN_TARGET_VERSION'
            $settingValues += $targetVersion
        }
        Set-UpdateSettings $settingNames $settingValues
        for ($index = 0; $index -lt $imageKeys.Count; $index++) {
            [Environment]::SetEnvironmentVariable($imageKeys[$index], $candidateImages[$index], 'Process')
        }
        if ($targetVersion) {
            $env:XINGCHEN_TARGET_VERSION = $targetVersion
        }
        & docker compose @composeArgs up -d --remove-orphans --wait --wait-timeout 300 $services
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
                $rollbackNames = @($imageKeys) + @('XINGCHEN_TARGET_VERSION')
                $rollbackValues = @($rollbackImages) + @($previousTargetSetting)
                Set-UpdateSettings $rollbackNames $rollbackValues
                for ($index = 0; $index -lt $imageKeys.Count; $index++) {
                    [Environment]::SetEnvironmentVariable($imageKeys[$index], $rollbackImages[$index], 'Process')
                }
                $env:XINGCHEN_TARGET_VERSION = $previousTargetSetting
                & docker compose @composeArgs up -d --remove-orphans --wait --wait-timeout 300 $services
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
