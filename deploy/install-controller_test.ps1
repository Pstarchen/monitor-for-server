$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $scriptRoot 'install-controller.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('xingchen-controller-install-test-' + [Guid]::NewGuid().ToString('N'))

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Write-Utf8([string] $Path, [string] $Content) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Assert-BytesEqual([byte[]] $Expected, [byte[]] $Actual, [string] $Message) {
    if ($Expected.Length -ne $Actual.Length) { throw $Message }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) { throw $Message }
    }
}

function New-TestFixture([string] $Name, [string] $EnvironmentContent, [bool] $WithDocker = $true, [bool] $WithWinget = $false) {
    $root = Join-Path $testRoot $Name
    $project = Join-Path $root 'project'
    $bin = Join-Path $root 'bin'
    New-Item -ItemType Directory -Path (Join-Path $project 'deploy'), $bin -Force | Out-Null
    Copy-Item -LiteralPath $installer -Destination (Join-Path $project 'deploy/install-controller.ps1')
    Write-Utf8 (Join-Path $project 'docker-compose.yml') "services: {}`n"
    Write-Utf8 (Join-Path $project 'deploy/update-controller.ps1') @'
[System.IO.File]::AppendAllText(
    $env:TEST_LOG,
    "updater mode=$env:XINGCHEN_NETWORK_MODE allow_gitee=$env:XINGCHEN_ALLOW_GITEE args=$($args -join ' ')`n",
    [System.Text.UTF8Encoding]::new($false)
)
'@
    if ($null -ne $EnvironmentContent) { Write-Utf8 (Join-Path $project '.env') $EnvironmentContent }
    if ($WithDocker) {
        Write-Utf8 (Join-Path $bin 'docker.cmd') @"
@echo off
echo docker %*>>"%TEST_LOG%"
if "%~1"=="volume" if "%~2"=="inspect" exit /b 1
exit /b 0
"@
    }
    if ($WithWinget) {
        Write-Utf8 (Join-Path $bin 'winget.cmd') @"
@echo off
echo winget %*>>"%TEST_LOG%"
exit /b 0
"@
    }
    return [pscustomobject]@{
        Root = $root
        Project = $project
        Bin = $bin
        Log = Join-Path $root 'commands.log'
        Installer = Join-Path $project 'deploy/install-controller.ps1'
    }
}

$installerEnvironmentNames = @(
    'XINGCHEN_POSTGRES_IMAGE', 'XINGCHEN_REDIS_IMAGE',
    'XINGCHEN_SETUP_IMAGE', 'XINGCHEN_SERVER_IMAGE', 'XINGCHEN_WEB_IMAGE', 'XINGCHEN_AGENT_IMAGE',
    'XINGCHEN_TARGET_VERSION', 'XINGCHEN_RELEASE_MANIFEST_PATH', 'XINGCHEN_RELEASE_MANIFEST_URLS', 'XINGCHEN_RELEASE_MANIFEST_SHA256',
    'XINGCHEN_AGENT_RELEASE_BASE_URLS', 'XINGCHEN_AGENT_CACHE_DIR', 'XINGCHEN_AGENT_OFFLINE_DIR',
    'XINGCHEN_CONTROLLER_ALLOW_GITHUB_API', 'XINGCHEN_CONTROLLER_IMAGE_MIRRORS', 'XINGCHEN_AGENT_IMAGE_MIRRORS',
    'XINGCHEN_NETWORK_MODE', 'XINGCHEN_ALLOW_GITEE',
    'XINGCHEN_SOURCE_REPOSITORIES', 'XINGCHEN_SOURCE_REF', 'XINGCHEN_SOURCE_BUILD_TIMEOUT_SECONDS',
    'XINGCHEN_UPDATE_MIRROR_TIMEOUT_SECONDS', 'XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS', 'XINGCHEN_UPDATE_COMPOSE_TIMEOUT_SECONDS', 'XINGCHEN_UPDATE_MIN_FREE_BYTES'
)

function Invoke-TestInstaller($Fixture, [hashtable] $Parameters = @{}, [hashtable] $Environment = @{}) {
    $savedPath = $env:PATH
    $savedLog = $env:TEST_LOG
    $saved = @{}
    foreach ($name in $installerEnvironmentNames) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string] $entry.Key, [string] $entry.Value, 'Process')
    }
    $env:PATH = $Fixture.Bin
    $env:TEST_LOG = $Fixture.Log
    $succeeded = $false
    $output = @()
    try {
        try {
            $installerPath = $Fixture.Installer
            $output = @(& $installerPath @Parameters 2>&1)
            $succeeded = $true
        }
        catch {
            $output += $_.Exception.Message
        }
        return [pscustomobject]@{ Succeeded = $succeeded; Output = ($output -join "`n") }
    }
    finally {
        $env:PATH = $savedPath
        $env:TEST_LOG = $savedLog
        foreach ($name in $installerEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
        }
    }
}

function Invoke-WebRequest {
    return [pscustomobject]@{ StatusCode = 200 }
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    $fixture = New-TestFixture 'existing-policy' @'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE="internal"
XINGCHEN_ALLOW_GITEE="true"
CUSTOM_SETTING="preserve-me"
'@
    $result = Invoke-TestInstaller -Fixture $fixture -Parameters @{ NoInstallDependencies = $true }
    Assert-True $result.Succeeded "Existing policy install failed: $($result.Output)"
    $lines = [System.IO.File]::ReadAllLines((Join-Path $fixture.Project '.env'))
    Assert-True ($lines -contains 'XINGCHEN_NETWORK_MODE="internal"') 'Existing internal network mode was not preserved.'
    Assert-True ($lines -contains 'XINGCHEN_ALLOW_GITEE="true"') 'Existing Gitee policy was not preserved.'
    Assert-True ($lines -contains 'CUSTOM_SETTING="preserve-me"') 'An unrelated existing setting was changed.'
    Assert-True ([System.IO.File]::ReadAllText($fixture.Log).Contains('updater mode=internal allow_gitee=true')) 'Inherited policy was not passed to the updater.'

    $fixture = New-TestFixture 'process-policy' @'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE="offline"
XINGCHEN_ALLOW_GITEE="false"
'@
    $result = Invoke-TestInstaller -Fixture $fixture -Parameters @{ NoInstallDependencies = $true } -Environment @{ XINGCHEN_NETWORK_MODE = 'public'; XINGCHEN_ALLOW_GITEE = 'true' }
    Assert-True $result.Succeeded "Process policy install failed: $($result.Output)"
    $lines = [System.IO.File]::ReadAllLines((Join-Path $fixture.Project '.env'))
    Assert-True ($lines -contains 'XINGCHEN_NETWORK_MODE="public"') 'Process network mode did not override the existing file.'
    Assert-True ($lines -contains 'XINGCHEN_ALLOW_GITEE="true"') 'Process Gitee policy did not override the existing file.'

    $fixture = New-TestFixture 'argument-policy' @'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE="offline"
'@
    $result = Invoke-TestInstaller -Fixture $fixture -Parameters @{ NetworkMode = 'public'; NoInstallDependencies = $true } -Environment @{ XINGCHEN_NETWORK_MODE = 'internal' }
    Assert-True $result.Succeeded "Explicit policy install failed: $($result.Output)"
    $lines = [System.IO.File]::ReadAllLines((Join-Path $fixture.Project '.env'))
    Assert-True ($lines -contains 'XINGCHEN_NETWORK_MODE="public"') 'Explicit network mode did not override the process environment.'

    $fixture = New-TestFixture 'missing-password' @'
XINGCHEN_NETWORK_MODE="public"
WEB_PORT="19090"
CUSTOM_SETTING="preserve-me"
'@
    $result = Invoke-TestInstaller -Fixture $fixture -Parameters @{ NoInstallDependencies = $true }
    Assert-True $result.Succeeded "Missing-password install failed: $($result.Output)"
    $lines = [System.IO.File]::ReadAllLines((Join-Path $fixture.Project '.env'))
    Assert-True ($lines -contains 'WEB_PORT="19090"') 'Adding a password removed the configured Web port.'
    Assert-True ($lines -contains 'CUSTOM_SETTING="preserve-me"') 'Adding a password removed an unrelated setting.'
    Assert-True (@($lines | Where-Object { $_ -match '^POSTGRES_PASSWORD=' }).Count -eq 1) 'A missing password was not added exactly once.'
    Assert-True (@($lines | Where-Object { $_ -match '^POSTGRES_PASSWORD="[0-9a-f]{64}"$' }).Count -eq 1) 'The generated password is invalid.'

    $fixture = New-TestFixture 'invalid-password' @'
POSTGRES_PASSWORD=""
XINGCHEN_NETWORK_MODE="public"
CUSTOM_SETTING="preserve-me"
'@
    $before = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Project '.env'))
    $result = Invoke-TestInstaller -Fixture $fixture -Parameters @{ NoInstallDependencies = $true }
    Assert-True (-not $result.Succeeded -and $result.Output.Contains('POSTGRES_PASSWORD')) 'An invalid existing password did not fail clearly.'
    Assert-BytesEqual $before ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Project '.env'))) 'The invalid environment file was modified.'

    $fixtureEnvironment = @'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE="internal"
'@
    $fixture = New-TestFixture 'restricted-dependencies' $fixtureEnvironment $false $true
    $result = Invoke-TestInstaller -Fixture $fixture
    Assert-True (-not $result.Succeeded) 'Restricted mode did not fail without Docker.'
    Assert-True (-not (Test-Path -LiteralPath $fixture.Log)) 'Restricted mode invoked winget.'

    $fixtureEnvironment = @'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE="public"
'@
    $fixture = New-TestFixture 'public-disabled-dependencies' $fixtureEnvironment $false $true
    $result = Invoke-TestInstaller -Fixture $fixture -Parameters @{ NoInstallDependencies = $true }
    Assert-True (-not $result.Succeeded -and $result.Output.Contains('-NoInstallDependencies')) 'Dependency installation opt-out did not fail clearly.'
    Assert-True (-not (Test-Path -LiteralPath $fixture.Log)) 'Dependency installation opt-out invoked winget.'

    $fixtureEnvironment = @'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE="public"
'@
    $fixture = New-TestFixture 'public-dependencies' $fixtureEnvironment $false $true
    $result = Invoke-TestInstaller -Fixture $fixture
    Assert-True (-not $result.Succeeded -and $result.Output.Contains('Docker Desktop')) 'Successful winget install did not require Docker startup and a rerun.'
    Assert-True ((Test-Path -LiteralPath $fixture.Log) -and [System.IO.File]::ReadAllText($fixture.Log).Contains('winget install --id Docker.DockerDesktop')) 'Public mode did not invoke winget for Docker Desktop.'

    Write-Host 'install-controller.ps1 behavior tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
