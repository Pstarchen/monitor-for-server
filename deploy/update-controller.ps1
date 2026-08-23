[CmdletBinding()]
param(
    [switch] $Check,
    [switch] $Apply,
    [switch] $Auto,
    [switch] $Build,
    [switch] $NoMirror
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw '需要安装 Docker Engine。' }
& docker compose version | Out-Null
if ($LASTEXITCODE -ne 0) { throw '需要 Docker Compose v2。' }

if (-not $Check -and -not $Apply) { $Check = $true }
$pullTimeoutSeconds = if ($env:GUANLAN_UPDATE_PULL_TIMEOUT_SECONDS) { [int]$env:GUANLAN_UPDATE_PULL_TIMEOUT_SECONDS } else { 120 }
$composeTimeoutSeconds = if ($env:GUANLAN_UPDATE_COMPOSE_TIMEOUT_SECONDS) { [int]$env:GUANLAN_UPDATE_COMPOSE_TIMEOUT_SECONDS } else { 360 }
if ($pullTimeoutSeconds -lt 1 -or $composeTimeoutSeconds -lt 1) { throw '更新超时必须是正整数秒数。' }
$env:DOCKER_CLIENT_TIMEOUT = [string]$pullTimeoutSeconds
$env:COMPOSE_HTTP_TIMEOUT = [string]$composeTimeoutSeconds
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
    function Pull-Image([string] $Image) {
        if (-not $NoMirror -and $Image.StartsWith('ghcr.io/')) {
            $suffix = $Image.Substring(7)
            $mirrorValue = $env:GUANLAN_CONTROLLER_IMAGE_MIRRORS
            if (-not $mirrorValue -and (Test-Path -LiteralPath $envFile)) {
                $mirrorLine = Select-String -LiteralPath $envFile -Pattern '^GUANLAN_CONTROLLER_IMAGE_MIRRORS=(.*)$' | Select-Object -First 1
                if ($mirrorLine) { $mirrorValue = $mirrorLine.Matches[0].Groups[1].Value.Trim('"') }
            }
            $mirrors = if ($mirrorValue) { $mirrorValue.Split(',') } else { @('ghcr.nju.edu.cn', 'ghcr.1ms.run') }
            foreach ($mirror in $mirrors) {
                $candidate = $mirror.TrimEnd('/') + '/' + $suffix
                Write-Host "尝试国内镜像源：$candidate"
                & docker pull $candidate | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    & docker tag $candidate $Image
                    if ($LASTEXITCODE -eq 0) { return }
                }
            }
        }
        Write-Host "尝试官方镜像源：$Image"
        & docker pull $Image
        if ($LASTEXITCODE -ne 0) { throw "镜像拉取失败：$Image" }
    }

    if ($Build) {
        & docker compose @composeArgs build --pull $services
        if ($LASTEXITCODE -ne 0) { throw '总控镜像构建失败。' }
    }
    else {
        foreach ($entry in $imageNames) {
            $pair = $entry.Split('=', 2)
            $value = [Environment]::GetEnvironmentVariable($pair[0])
            if (-not $value -and (Test-Path -LiteralPath $envFile)) {
                $line = Select-String -LiteralPath $envFile -Pattern "^$($pair[0])=(.*)$" | Select-Object -First 1
                if ($line) { $value = $line.Matches[0].Groups[1].Value.Trim('"') }
            }
            Pull-Image ($(if ($value) { $value } else { $pair[1] }))
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
