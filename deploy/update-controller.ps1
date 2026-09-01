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
    # Registry mirrors should fail over quickly, while the official registry
    # keeps a longer window for constrained international links.
    $pullTimeoutSeconds = [int](Read-UpdateSetting 'GUANLAN_UPDATE_PULL_TIMEOUT_SECONDS' '180')
    $mirrorTimeoutSeconds = [int](Read-UpdateSetting 'GUANLAN_UPDATE_MIRROR_TIMEOUT_SECONDS' '45')
    $composeTimeoutSeconds = [int](Read-UpdateSetting 'GUANLAN_UPDATE_COMPOSE_TIMEOUT_SECONDS' '900')
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
        if (Get-ScheduledTask -TaskName 'GuanlanControllerUpdate' -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName 'GuanlanControllerUpdate' -Confirm:$false
        }
        & docker compose @composeArgs up -d --no-deps --wait --wait-timeout 300 setup
        if ($LASTEXITCODE -ne 0) { throw '自动更新设置已保存，但 setup 服务启动失败。' }
        Write-Host '总控自动更新已启用：每天 04:00 按 APP_TIMEZONE 执行。'
        exit 0
    }
    $services = @('setup', 'server', 'web')
    $imageNames = @(
        'GUANLAN_SETUP_IMAGE=ghcr.io/pstarchen/monitor-for-server-setup:latest',
        'GUANLAN_SERVER_IMAGE=ghcr.io/pstarchen/monitor-for-server-server:latest',
        'GUANLAN_WEB_IMAGE=ghcr.io/pstarchen/monitor-for-server-web:latest'
    )
    $sourceContexts = @('setup', 'server', 'web')
    $sourceRef = Read-UpdateSetting 'GUANLAN_SOURCE_REF' 'main'
    if ($sourceRef -notmatch '^[a-zA-Z0-9._/-]+$' -or $sourceRef.StartsWith('-') -or $sourceRef.Contains('..')) {
        throw '总控源码 Git ref 无效。'
    }
    $sourceRepositories = @((Read-UpdateSetting 'GUANLAN_SOURCE_REPOSITORIES' 'https://gitee.com/starchen520/monitor-for-server.git,https://github.com/Pstarchen/monitor-for-server.git').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
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

    function Pull-Image([string] $Image) {
        if (-not $NoMirror -and $Image.StartsWith('ghcr.io/')) {
            $suffix = $Image.Substring(7)
            $mirrorValue = Read-UpdateSetting 'GUANLAN_CONTROLLER_IMAGE_MIRRORS'
            $mirrors = if ($mirrorValue) { $mirrorValue.Split(',') } else { @('ghcr.1ms.run', 'ghcr.nju.edu.cn') }
            foreach ($mirror in $mirrors) {
                $candidate = $mirror.TrimEnd('/') + '/' + $suffix
                Write-Host "尝试国内镜像源：$candidate"
                if (Invoke-DockerPull $candidate $mirrorTimeoutSeconds) {
                    & docker tag $candidate $Image
                    if ($LASTEXITCODE -eq 0) { return }
                }
            }
        }
        Write-Host "尝试官方镜像源：$Image"
        if (-not (Invoke-DockerPull $Image $pullTimeoutSeconds)) { throw "镜像拉取失败：$Image" }
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
