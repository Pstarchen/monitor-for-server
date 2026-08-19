[CmdletBinding()]
param(
    [switch] $Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    @'
Usage: install-controller.ps1

Builds and starts the controller services. Database and site configuration are
completed in the browser setup guide at /setup.
'@
    exit 0
}

$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw '需要安装 Docker Engine。' }
& docker compose version | Out-Null
if ($LASTEXITCODE -ne 0) { throw '需要 Docker Compose v2。' }

Push-Location $projectRoot
try {
    & docker compose config --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Compose 配置校验失败。' }
    & docker compose up --build -d
    if ($LASTEXITCODE -ne 0) { throw '总终端服务器启动失败。' }
}
finally {
    Pop-Location
}

Write-Host '总终端服务器已启动。请打开 http://<服务器IP>:18080/setup 完成首次安装。'
Write-Host '安装向导会要求你明确填写 MySQL 地址、端口、已创建的数据库名、用户名和密码。'
Write-Host '本脚本不会安装 MySQL、创建数据库、创建用户、授权账号或猜测 Docker 网桥地址。'
