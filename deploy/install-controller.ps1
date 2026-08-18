[CmdletBinding()]
param(
    [switch] $Overwrite,
    [switch] $AllowLocalHttp,
    [switch] $AllowInsecureHttp
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $projectRoot '.env'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw '需要安装 Docker Engine。' }
& docker compose version | Out-Null
if ($LASTEXITCODE -ne 0) { throw '需要 Docker Compose v2。' }
if ((Test-Path -LiteralPath $envPath) -and -not $Overwrite) {
    throw '.env 已存在。请手动编辑，或使用 -Overwrite 覆盖并自动备份。'
}

$mysqlCommand = Get-Command mysql -ErrorAction SilentlyContinue
if (-not $mysqlCommand) { $mysqlCommand = Get-Command mariadb -ErrorAction SilentlyContinue }
if (-not $mysqlCommand) { throw '需要安装 MySQL 客户端（mysql.exe 或 mariadb.exe），用于创建应用数据库。' }

function Read-Required([string] $Label) {
    do { $value = Read-Host $Label } while ([string]::IsNullOrWhiteSpace($value))
    return $value.Trim()
}

function Read-Default([string] $Label, [string] $Default) {
    $value = Read-Host "$Label [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Read-Secret([string] $Label, [int] $MinimumLength) {
    do {
        $secure = Read-Host "$Label（至少 $MinimumLength 位）" -AsSecureString
        $value = [Net.NetworkCredential]::new('', $secure).Password
        if ($value.Length -lt $MinimumLength) { Write-Warning "输入不能为空且至少需要 $MinimumLength 个字符。" }
    } while ($value.Length -lt $MinimumLength)
    if ($value.Contains("`n") -or $value.Contains("`r")) { throw '密码不能包含换行。' }
    return $value
}

function New-Base64Secret {
    $bytes = [byte[]]::new(32)
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) } finally { $random.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

function Assert-Port([string] $Label, [string] $Value) {
    $number = 0
    if ($Value -notmatch '^[0-9]+$' -or -not [int]::TryParse($Value, [ref]$number) -or $number -lt 1 -or $number -gt 65535) {
        throw "$Label无效。"
    }
}

function Assert-Identifier([string] $Label, [string] $Value) {
    if ($Value -notmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$') {
        throw "$Label只能以字母开头，并且只能包含字母、数字和下划线（最多 64 位）。"
    }
}

function Assert-Host([string] $Label, [string] $Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '[\s/\?#]') { throw "$Label格式无效。" }
}

function ConvertTo-MySqlLiteral([string] $Value) {
    $escaped = $Value.Replace('\', '\\').Replace("'", "''")
    return "'$escaped'"
}

function ConvertTo-DotEnvValue([string] $Value) {
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace('$', '$$')
    return '"' + $escaped + '"'
}

function Invoke-MySqlQuery([string] $Sql) {
    $previousPassword = $env:MYSQL_PWD
    try {
        $env:MYSQL_PWD = $mysqlAdminPassword
        $output = & $mysqlCommand.Source @mysqlArgs --raw --execute $Sql
        if ($LASTEXITCODE -ne 0) { throw 'MySQL 查询失败。' }
        return (($output -join "`n").Trim())
    }
    finally {
        if ($null -eq $previousPassword) { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue }
        else { $env:MYSQL_PWD = $previousPassword }
    }
}

function Invoke-MySqlScript([string] $Sql) {
    $previousPassword = $env:MYSQL_PWD
    try {
        $env:MYSQL_PWD = $mysqlAdminPassword
        $Sql | & $mysqlCommand.Source @mysqlArgs --batch --skip-column-names
        if ($LASTEXITCODE -ne 0) { throw 'MySQL 初始化失败。' }
    }
    finally {
        if ($null -eq $previousPassword) { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue }
        else { $env:MYSQL_PWD = $previousPassword }
    }
}

$tmpPath = $null
try {
    Write-Host '先配置外部 MySQL。安装器会创建新的数据库和最小权限应用账号，不会覆盖已有同名对象。'
    $mysqlAdminHost = Read-Required 'MySQL 管理地址（安装器所在主机可访问，例如 127.0.0.1）'
    Assert-Host 'MySQL 管理地址' $mysqlAdminHost
    $mysqlAdminPort = Read-Required 'MySQL 管理端口（1-65535）'
    Assert-Port 'MySQL 管理端口' $mysqlAdminPort
    $mysqlAdminUser = Read-Required 'MySQL 管理用户名（需要建库、建用户和授权权限）'
    $mysqlAdminPassword = Read-Secret 'MySQL 管理密码' 1
    $mysqlArgs = @('--protocol=tcp', "--host=$mysqlAdminHost", "--port=$mysqlAdminPort", "--user=$mysqlAdminUser", '--batch', '--skip-column-names')

    if ((Invoke-MySqlQuery 'SELECT 1;') -ne '1') { throw 'MySQL 管理账号连接测试未返回预期结果。' }

    $mysqlAppHost = Read-Default '容器连接 MySQL 地址（同机 Docker 使用 host.docker.internal）' 'host.docker.internal'
    Assert-Host '容器连接 MySQL 地址' $mysqlAppHost
    $mysqlAppPort = Read-Default '容器连接 MySQL 端口' $mysqlAdminPort
    Assert-Port '容器连接 MySQL 端口' $mysqlAppPort
    $databaseName = Read-Required '目标数据库名（新建，字母开头，仅字母/数字/下划线）'
    Assert-Identifier '目标数据库名' $databaseName
    $appUsername = Read-Required '应用数据库用户名（新建，字母开头，仅字母/数字/下划线）'
    Assert-Identifier '应用数据库用户名' $appUsername
    $appPassword = Read-Secret '应用数据库密码' 12
    $appPasswordConfirm = Read-Secret '再次输入应用数据库密码' 12
    if ($appPassword -cne $appPasswordConfirm) { throw '两次应用数据库密码不一致。' }

    $publicBaseUrl = Read-Required '公网入口 URL（HTTPS；临时 IP/HTTP 请使用 -AllowInsecureHttp）'
    try { $uri = [Uri]$publicBaseUrl } catch { throw '公网入口 URL 格式无效。' }
    $localHttp = $uri.Scheme -eq 'http' -and @('localhost', '127.0.0.1', '::1') -contains $uri.Host
    if ([string]::IsNullOrWhiteSpace($uri.Host) -or $uri.Query -or $uri.Fragment -or ($uri.Scheme -ne 'https' -and -not (($AllowInsecureHttp -and $uri.Scheme -eq 'http') -or ($AllowLocalHttp -and $localHttp)))) {
        throw '公网入口必须是 HTTPS；临时 IP/HTTP 初始化请使用 -AllowInsecureHttp。'
    }
    if ($AllowInsecureHttp -and $uri.Scheme -eq 'http' -and -not $localHttp) {
        Write-Warning '当前使用明文 HTTP，仅限初始化。绑定 HTTPS 域名后必须更新 .env 并重建 server。'
    }
    $allowedOrigins = Read-Required 'Web 来源（通常与公网入口相同）'
    $siteName = Read-Required '站点名称'
    $adminUsername = Read-Required '初始管理员用户名'
    $timezone = Read-Required '服务时区（例如 Asia/Shanghai）'
    $webPort = Read-Required 'Web 端口（1-65535）'
    Assert-Port 'Web 端口' $webPort
    $webBindAddress = Read-Required 'Web 绑定地址（0.0.0.0 允许 IP 直连；127.0.0.1 仅供宝塔反代）'
    if ($webBindAddress -notin @('0.0.0.0', '127.0.0.1', 'localhost', '::1')) { throw 'Web 绑定地址只支持 0.0.0.0、127.0.0.1、localhost 或 ::1。' }
    $adminPassword = Read-Secret '初始管理员密码' 12
    $adminPasswordConfirm = Read-Secret '再次输入初始管理员密码' 12
    if ($adminPassword -cne $adminPasswordConfirm) { throw '两次管理员密码不一致。' }

    $databaseSql = ConvertTo-MySqlLiteral $databaseName
    $appUserSql = ConvertTo-MySqlLiteral $appUsername
    if ((Invoke-MySqlQuery "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = $databaseSql;") -ne '0') {
        throw "数据库 $databaseName 已存在。为避免覆盖数据，安装器已停止；请换一个数据库名或手动完成后续配置。"
    }
    if ((Invoke-MySqlQuery "SELECT COUNT(*) FROM mysql.user WHERE User = $appUserSql;") -ne '0') {
        throw "应用用户 $appUsername 已存在。为避免修改现有账号，安装器已停止。"
    }

    $appPasswordSql = ConvertTo-MySqlLiteral $appPassword
    Write-Host "正在创建数据库 $databaseName、应用用户 $appUsername 并授予目标库权限..."
    Invoke-MySqlScript @"
CREATE DATABASE $databaseSql CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER $appUserSql@'%' IDENTIFIED BY $appPasswordSql;
GRANT ALL PRIVILEGES ON $databaseSql.* TO $appUserSql@'%';
FLUSH PRIVILEGES;
"@
    Remove-Variable mysqlAdminPassword -ErrorAction SilentlyContinue
    Remove-Variable appPasswordConfirm -ErrorAction SilentlyContinue

    $settingsKey = New-Base64Secret
    $secureLines = @(
        '# Generated by deploy/install-controller.ps1. Keep this file private.'
        'SPRING_PROFILES_ACTIVE=production'
        "DB_URL=$(ConvertTo-DotEnvValue "jdbc:mysql://${mysqlAppHost}:${mysqlAppPort}/${databaseName}?useUnicode=true&characterEncoding=utf8&serverTimezone=UTC")"
        "DB_USERNAME=$(ConvertTo-DotEnvValue $appUsername)"
        "DB_PASSWORD=$(ConvertTo-DotEnvValue $appPassword)"
        "BOOTSTRAP_ADMIN_USERNAME=$(ConvertTo-DotEnvValue $adminUsername)"
        "BOOTSTRAP_ADMIN_PASSWORD=$(ConvertTo-DotEnvValue $adminPassword)"
        "SETTINGS_ENCRYPTION_KEY=$(ConvertTo-DotEnvValue $settingsKey)"
        "WEB_PORT=$(ConvertTo-DotEnvValue $webPort)"
        "WEB_BIND_ADDRESS=$(ConvertTo-DotEnvValue $webBindAddress)"
        "APP_TIMEZONE=$(ConvertTo-DotEnvValue $timezone)"
        "SITE_NAME=$(ConvertTo-DotEnvValue $siteName)"
        "PUBLIC_BASE_URL=$(ConvertTo-DotEnvValue $publicBaseUrl)"
        "SESSION_COOKIE_SECURE=$(ConvertTo-DotEnvValue ($uri.Scheme -eq 'https'))"
        "ALLOW_INSECURE_HTTP=$(ConvertTo-DotEnvValue ($uri.Scheme -eq 'http'))"
        "ALLOWED_ORIGINS=$(ConvertTo-DotEnvValue $allowedOrigins)"
        'METRIC_RETENTION_DAYS=30'
        'DEVICE_OFFLINE_AFTER_SECONDS=30'
    )
    $tmpPath = Join-Path ([IO.Path]::GetTempPath()) ("guanlan-env-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllLines($tmpPath, $secureLines, [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $envPath) {
        Copy-Item -LiteralPath $envPath -Destination "$envPath.backup.$(Get-Date -Format yyyyMMddHHmmss)"
    }
    Move-Item -LiteralPath $tmpPath -Destination $envPath -Force
    $tmpPath = $null
    & icacls.exe $envPath /inheritance:r /grant:r 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '.env 权限收紧失败。' }
    & docker compose --env-file $envPath config --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Compose 配置校验失败。' }
    & docker compose --env-file $envPath up --build -d
    if ($LASTEXITCODE -ne 0) { throw '总终端服务器启动失败。' }
    Write-Host "总终端服务器已启动。请打开 $publicBaseUrl 并使用刚设置的管理员账号登录；后续站点、通知和设备配置由你在控制台完成。"
}
finally {
    if ($tmpPath -and (Test-Path -LiteralPath $tmpPath)) { Remove-Item -LiteralPath $tmpPath -Force }
    Remove-Variable mysqlAdminPassword, appPassword, adminPassword, adminPasswordConfirm, settingsKey -ErrorAction SilentlyContinue
}
