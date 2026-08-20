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

if ($Auto) {
    $taskName = 'GuanlanControllerUpdate'
    $scriptPath = Join-Path $PSScriptRoot 'update-controller.ps1'
    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File \`"$scriptPath\`" -Apply"
    $trigger = New-ScheduledTaskTrigger -Daily -At 4:00am
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -RunLevel Highest -Force | Out-Null
    Write-Host '总控自动更新已启用：GuanlanControllerUpdate'
    exit 0
}

if (-not $Check -and -not $Apply) { $Check = $true }
Push-Location $projectRoot
try {
    $composeArgs = @()
    $envFile = Join-Path $projectRoot '.env'
    if (Test-Path -LiteralPath $envFile) { $composeArgs += @('--env-file', $envFile) }
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
            $mirrors = if ($mirrorValue) { $mirrorValue.Split(',') } else { @('ghcr.nju.edu.cn', 'ghcr.m.daocloud.io', 'ghcr.1ms.run') }
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
        & docker compose @composeArgs up -d --remove-orphans $services
        if ($LASTEXITCODE -ne 0) { throw '总控服务更新失败。' }
        Write-Host '总控服务已更新并重启。'
    }
    else {
        Write-Host '总控镜像检查完成；如需使新镜像生效，请运行：.\deploy\update-controller.ps1 -Apply'
    }
}
finally { Pop-Location }
