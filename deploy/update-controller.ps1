[CmdletBinding()]
param(
    [switch] $Check,
    [switch] $Apply,
    [switch] $Auto,
    [switch] $Build,
    [switch] $SourceBuild,
    [switch] $NoMirror,
    [switch] $NoSourceFallback
)

$ErrorActionPreference = 'Stop'
if ($Build -and $SourceBuild) { throw '-Build 与 -SourceBuild 不能同时使用。' }
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
    if (Test-Path -LiteralPath $envFile -and -not (Select-String -LiteralPath $envFile -Pattern '^COMPOSE_PROJECT_NAME=' -Quiet)) {
        $legacyDatabase = Read-UpdateSetting 'POSTGRES_DB'
        $legacyVolume = (& docker volume inspect 'guanlan-monitor_postgres-data' 2>$null)
        $projectName = if ($legacyDatabase -eq 'guanlan_monitor' -or $legacyVolume) { 'guanlan-monitor' } else { 'xingchen-monitor' }
        $lines = [System.Collections.Generic.List[string]]::new()
        [System.IO.File]::ReadAllLines($envFile) | ForEach-Object { [void]$lines.Add($_) }
        [void]$lines.Add("COMPOSE_PROJECT_NAME=$projectName")
        [System.IO.File]::WriteAllLines($envFile, $lines, [System.Text.UTF8Encoding]::new($false))
    }
    # Registry mirrors should fail over quickly, while the official registry
    # keeps a longer window for constrained international links.
    $pullTimeoutSeconds = [int](Read-UpdateSetting 'XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS' '180')
    $mirrorTimeoutSeconds = [int](Read-UpdateSetting 'XINGCHEN_UPDATE_MIRROR_TIMEOUT_SECONDS' '45')
    $composeTimeoutSeconds = [int](Read-UpdateSetting 'XINGCHEN_UPDATE_COMPOSE_TIMEOUT_SECONDS' '900')
    if ($pullTimeoutSeconds -lt 1 -or $mirrorTimeoutSeconds -lt 1 -or $composeTimeoutSeconds -lt 1) { throw '更新超时必须是正整数秒数。' }
    $env:DOCKER_CLIENT_TIMEOUT = [string]$pullTimeoutSeconds
    $env:COMPOSE_HTTP_TIMEOUT = [string]$composeTimeoutSeconds
    if ($Auto) {
        if (-not (Test-Path -LiteralPath $envFile)) { throw '总控 .env 不存在，请先完成安装。' }
        $lines = [System.Collections.Generic.List[string]]::new()
        $found = $false
        foreach ($line in [System.IO.File]::ReadAllLines($envFile)) {
            if ($line.StartsWith('CONTROLLER_AUTO_UPDATE=')) {
                if (-not $found) { [void] $lines.Add('CONTROLLER_AUTO_UPDATE="true"') }
                $found = $true
            }
            else { [void] $lines.Add($line) }
        }
        if (-not $found) { [void] $lines.Add('CONTROLLER_AUTO_UPDATE="true"') }
        $temporary = Join-Path $projectRoot ('.env.controller-update.' + [Guid]::NewGuid().ToString('N'))
        try {
            [System.IO.File]::WriteAllLines($temporary, $lines, [System.Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $temporary -Destination $envFile -Force
        }
        finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
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
    $imageNames = @(
        'XINGCHEN_SETUP_IMAGE=ghcr.io/pstarchen/monitor-for-server-setup:latest',
        'XINGCHEN_SERVER_IMAGE=ghcr.io/pstarchen/monitor-for-server-server:latest',
        'XINGCHEN_WEB_IMAGE=ghcr.io/pstarchen/monitor-for-server-web:latest'
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
    if ($sourceRef -notmatch '^[a-zA-Z0-9._/-]+$' -or $sourceRef.StartsWith('-') -or $sourceRef.Contains('..')) {
        throw '总控源码 Git ref 无效。'
    }
    $sourceRepositories = @((Read-UpdateSetting 'XINGCHEN_SOURCE_REPOSITORIES' 'https://gitee.com/starchen520/monitor-for-server.git,https://github.com/Pstarchen/monitor-for-server.git').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($sourceRepositories.Count -eq 0) { throw '总控源码仓库地址不能为空。' }
    $resolvedImages = @()
    foreach ($entry in $imageNames) {
        $pair = $entry.Split('=', 2)
        $resolvedImages += (Read-UpdateSetting $pair[0] $pair[1])
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
        $sourceImage = $Image
        if ($targetVersion -and $Image -match '^ghcr\.io/pstarchen/monitor-for-server-(setup|server|web|agent):latest$') {
            $sourceImage = $Image.Substring(0, $Image.Length - ':latest'.Length) + ":$targetVersion"
        }
        if (-not $NoMirror -and $sourceImage.StartsWith('ghcr.io/')) {
            $suffix = $sourceImage.Substring(7)
            $mirrorValue = Read-UpdateSetting 'XINGCHEN_CONTROLLER_IMAGE_MIRRORS'
            $mirrors = if ($mirrorValue) { $mirrorValue.Split(',') } else { @('ghcr.1ms.run', 'ghcr.nju.edu.cn') }
            foreach ($mirror in $mirrors) {
                $candidate = $mirror.TrimEnd('/') + '/' + $suffix
                Write-Host "尝试国内镜像源：$candidate"
                if ((Invoke-DockerPull $candidate $mirrorTimeoutSeconds) -and (Test-ImageVersion $candidate)) {
                    & docker tag $candidate $Image
                    if ($LASTEXITCODE -eq 0) { return }
                }
            }
        }
        Write-Host "尝试官方镜像源：$sourceImage"
        if (-not (Invoke-DockerPull $sourceImage $pullTimeoutSeconds)) { throw "镜像拉取失败：$sourceImage" }
        if (-not (Test-ImageVersion $sourceImage)) { throw "镜像版本校验失败：$sourceImage" }
        if ($sourceImage -ne $Image) {
            & docker tag $sourceImage $Image
            if ($LASTEXITCODE -ne 0) { throw "镜像标签写入失败：$Image" }
        }
    }

    function Remove-SourceBuildImages([string[]] $Images) {
        if ($Images.Count -gt 0) { & docker image rm -f @Images | Out-Null }
    }

    function Build-ImagesFromRepositories {
        foreach ($image in $resolvedImages) {
            if ($image.Contains('@')) { throw "固定摘要镜像无法使用源码构建回退：$image" }
        }
        $buildPrefix = "xingchen-controller-source-$PID-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
        foreach ($repository in $sourceRepositories) {
            $temporaryImages = @()
            $success = $true
            Write-Host "正在尝试总控源码仓库：$repository ($sourceRef)"
            for ($index = 0; $index -lt $sourceContexts.Count; $index++) {
                $temporaryImage = "$buildPrefix-$index`:candidate"
                $temporaryImages += $temporaryImage
                $context = "${repository}#${sourceRef}:$($sourceContexts[$index])"
                & docker build --pull --tag $temporaryImage $context
                if ($LASTEXITCODE -ne 0) { $success = $false; break }
            }
            if ($success) {
                for ($index = 0; $index -lt $resolvedImages.Count; $index++) {
                    & docker tag $temporaryImages[$index] $resolvedImages[$index]
                    if ($LASTEXITCODE -ne 0) {
                        Remove-SourceBuildImages $temporaryImages
                        throw "源码镜像标签写入失败：$($resolvedImages[$index])"
                    }
                }
                Remove-SourceBuildImages $temporaryImages
                return
            }
            Remove-SourceBuildImages $temporaryImages
        }
        throw 'GitHub 与 Gitee 总控源码均无法完成 Docker 构建。'
    }

    if ($Build) {
        & docker compose @composeArgs build --pull $services
        if ($LASTEXITCODE -ne 0) { throw '总控镜像构建失败。' }
    }
    elseif ($SourceBuild) {
        Build-ImagesFromRepositories
    }
    else {
        $pullFailed = $false
        foreach ($image in $resolvedImages) {
            try { Pull-Image $image }
            catch {
                $pullFailed = $true
                Write-Warning $_.Exception.Message
                break
            }
        }
        if ($pullFailed) {
            if ($NoSourceFallback) { throw '总控镜像拉取失败，且源码构建回退已关闭。' }
            Write-Host '所有总控镜像源均不可用，开始从 Gitee/GitHub 源码构建 Docker 镜像。'
            Build-ImagesFromRepositories
        }
    }
    if ($Apply) {
        & docker compose @composeArgs up -d --remove-orphans --wait --wait-timeout 300 $services
        if ($LASTEXITCODE -ne 0) { throw '总控服务更新失败。' }
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
