$ErrorActionPreference = 'Stop'

$installer = Join-Path $PSScriptRoot 'install-agent.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $installer,
    [ref] $tokens,
    [ref] $parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "install-agent.ps1 has parser errors: $($parseErrors[0].Message)"
}

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

$requiredFunctions = @(
    'Test-NetworkHostMatches',
    'Test-ForbiddenPublicHost',
    'Test-NetworkSourceAllowed',
    'Assert-NetworkSourcePolicy',
    'Normalize-ReleaseVersion',
    'Get-AgentSource'
)
$definitions = @{}
foreach ($functionAst in $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)) {
    if ($requiredFunctions -contains $functionAst.Name) {
        $definitions[$functionAst.Name] = $functionAst.Extent.Text
    }
}
foreach ($name in $requiredFunctions) {
    Assert-True $definitions.ContainsKey($name) "Missing network policy function: $name"
    Invoke-Expression $definitions[$name]
}

$NetworkMode = 'internal'
$AllowGitee = $false
Assert-True (-not (Test-NetworkSourceAllowed 'https://github.com/example/repo')) 'internal mode allowed github.com.'
Assert-True (-not (Test-NetworkSourceAllowed 'https://api.github.com/repos/example/repo')) 'internal mode allowed api.github.com.'
Assert-True (-not (Test-NetworkSourceAllowed 'https://raw.githubusercontent.com/example/repo/main/file')) 'internal mode allowed githubusercontent.com.'
Assert-True (-not (Test-NetworkSourceAllowed 'https://cdn.githubassets.com/assets/app.js')) 'internal mode allowed githubassets.com.'
Assert-True (-not (Test-NetworkSourceAllowed 'https://cache.ghcr.io/v2/example/image/manifests/v1')) 'internal mode allowed a ghcr.io subdomain.'
Assert-True (-not (Test-NetworkSourceAllowed 'https://registry-1.docker.io/v2/example/image/manifests/v1')) 'internal mode allowed Docker Hub.'
Assert-True (-not (Test-NetworkSourceAllowed 'https://hub.docker.com/v2/repositories/example/image')) 'internal mode allowed a docker.com subdomain.'
Assert-True (-not (Test-NetworkSourceAllowed 'https://git.gitee.com/example/repo')) 'internal mode allowed a Gitee subdomain without opt-in.'
Assert-True (Test-NetworkSourceAllowed 'https://github.com.evil.example/example/repo') 'internal mode rejected a non-GitHub suffix lookalike.'
Assert-True (Test-NetworkSourceAllowed 'https://releases.internal.example/agent/manifest.json') 'internal mode rejected an internal HTTPS source.'
Assert-True (-not (Test-NetworkSourceAllowed 'http://releases.internal.example/agent/manifest.json')) 'internal mode allowed plaintext HTTP.'
Assert-True (-not (Get-AgentSource 'unused')) 'internal mode allowed the source checkout fallback.'
Assert-True ((Normalize-ReleaseVersion '1.20.14') -ceq 'v1.20.14') 'Agent installer rejected a canonical version.'
$leadingZeroRejected = $false
try { Normalize-ReleaseVersion 'v01.20.14' | Out-Null }
catch { $leadingZeroRejected = $true }
Assert-True $leadingZeroRejected 'Agent installer accepted a leading-zero version.'

$AllowGitee = $true
Assert-True (Test-NetworkSourceAllowed 'https://git.gitee.com/example/repo') 'internal mode rejected explicitly enabled Gitee.'

$NetworkMode = 'public'
$AllowGitee = $false
Assert-True (-not (Test-NetworkSourceAllowed 'https://gitee.com/example/repo')) 'public mode allowed Gitee without opt-in.'
$AllowGitee = $true
Assert-True (Test-NetworkSourceAllowed 'https://gitee.com/example/repo') 'public mode rejected explicitly enabled Gitee.'

$NetworkMode = 'offline'
Assert-True (-not (Test-NetworkSourceAllowed 'https://releases.internal.example/agent/manifest.json')) 'offline mode allowed a remote source.'
$rejected = $false
try { Assert-NetworkSourcePolicy 'https://releases.internal.example/agent/manifest.json' 'artifact source' }
catch { $rejected = $true }
Assert-True $rejected 'offline mode did not fail closed for a configured source.'

$source = Get-Content -Raw -LiteralPath $installer
Assert-True (([regex]::Matches($source, "\^v\?\(0\|\[1-9\]\[0-9\]\*\)\\\.\(0\|\[1-9\]\[0-9\]\*\)\\\.\(0\|\[1-9\]\[0-9\]\*\)\$")).Count -ge 2) 'Generated updater does not enforce canonical semantic versions.'
Assert-True $source.Contains('if (`$networkMode -eq ''offline'') { throw ''offline') 'Generated updater does not fail closed in offline mode.'
Assert-True $source.Contains('`$networkMode -eq ''public'' -and `$allowGitHubApi') 'Generated updater does not scope GitHub API access to public mode.'
Assert-True $source.Contains("'docker.io', 'docker.com'") 'Generated updater does not reject Docker Hub redirects in internal mode.'
Assert-True $source.Contains('internal 网络模式下预编译 Agent Release 不可用，拒绝源码构建回退') 'Windows Agent installer does not fail closed after an internal Release failure.'
Assert-True $source.Contains('Unregister-ScheduledTask -TaskName $taskName') 'Disabling updates does not remove the previous scheduled task.'
Assert-True $source.Contains('update_status_path = $updateStatusPath') 'Installer does not persist the updater status path in Agent config.'
Assert-True $source.Contains('update_request_path = $updateRequestPath') 'Installer does not persist the dedicated update request path.'
Assert-True $source.Contains('update_launcher_path = $updateLauncherPath') 'Installer does not persist the fixed Windows update launcher path.'
Assert-True $source.Contains("Write-AgentUpdateStatus 'CHECKING'") 'Generated updater does not report the checking state.'
Assert-True $source.Contains("Write-AgentUpdateStatus 'ROLLING_BACK'") 'Generated updater does not report rollback state.'
Assert-True $source.Contains('-X main.version=$sourceBuildVersion') 'Source fallback does not inject the resolved Agent version.'
Assert-True (-not $source.Contains("Write-AgentUpdateStatus 'FAILED' ([string] `$_.Exception.Message)")) 'Generated updater persists raw exception details.'
Assert-True $source.Contains('Start-Sleep -Seconds 10') 'Update launcher does not delay replacement long enough to report task acceptance.'
Assert-True $source.Contains('& `$powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `$updaterPath `$action `$version') 'Update launcher does not use the fixed updater entry point.'
Assert-True (-not $source.Contains('Invoke-Expression')) 'Update launcher must not evaluate request content.'

$launcherAssignment = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$launcherScript'
}, $true) | Select-Object -First 1
Assert-True ($null -ne $launcherAssignment) 'Generated update launcher was not found.'
$launcherSource = $launcherAssignment.Right.Expression.Value
$nestedTokens = $null
$nestedErrors = $null
[System.Management.Automation.Language.Parser]::ParseInput($launcherSource, [ref] $nestedTokens, [ref] $nestedErrors) | Out-Null
Assert-True ($nestedErrors.Count -eq 0) "Generated update launcher has parser errors: $($nestedErrors[0].Message)"

$bridgeFixture = Join-Path ([IO.Path]::GetTempPath()) ('xingchen-agent-bridge-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $bridgeFixture | Out-Null
try {
    $requestPath = Join-Path $bridgeFixture 'update-request'
    $updaterPath = Join-Path $bridgeFixture 'update-agent.ps1'
    $statusPath = Join-Path $bridgeFixture 'update-status.json'
    $launcherPath = Join-Path $bridgeFixture 'invoke-update-request.ps1'
    $logPath = Join-Path $bridgeFixture 'updater.log'
    $launcherSource = "function Start-Sleep { param([int] `$Seconds) }`r`n" + $launcherSource
    $launcherSource = $launcherSource.Replace('$updateRequestPathLiteral', $requestPath.Replace("'", "''"))
    $launcherSource = $launcherSource.Replace('$updaterPathLiteral', $updaterPath.Replace("'", "''"))
    $launcherSource = $launcherSource.Replace('$updateStatusPathLiteral', $statusPath.Replace("'", "''"))
    [IO.File]::WriteAllText($launcherPath, $launcherSource, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($updaterPath, 'param([string] $Command, [string] $RequestedVersion)' + [Environment]::NewLine + '[IO.File]::WriteAllText($env:XINGCHEN_BRIDGE_TEST_LOG, "$Command $RequestedVersion", [Text.UTF8Encoding]::new($false))', [Text.UTF8Encoding]::new($false))
    $env:XINGCHEN_BRIDGE_TEST_LOG = $logPath
    $testPowerShell = (Get-Process -Id $PID).Path

    [IO.File]::WriteAllLines($requestPath, @('action=update', 'version=v1.20.14', 'rollout_id=7', 'member_id=11'), [Text.UTF8Encoding]::new($false))
    & $testPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcherPath
    Assert-True ($LASTEXITCODE -eq 0) 'Valid update request did not reach the fixed updater.'
    Assert-True ((Get-Content -Raw -LiteralPath $logPath) -eq 'update v1.20.14') 'Fixed updater received unexpected arguments.'

    Remove-Item -LiteralPath $logPath -Force
    [IO.File]::WriteAllLines($requestPath, @('action=update', 'version=v1.20.14;whoami', 'rollout_id=7', 'member_id=11'), [Text.UTF8Encoding]::new($false))
    $previousErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $testPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcherPath 2>$null
        $invalidExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorPreference }
    Assert-True ($invalidExitCode -ne 0) 'Injected update version was accepted.'
    Assert-True (-not (Test-Path -LiteralPath $logPath)) 'Rejected update request reached the updater.'
    $global:LASTEXITCODE = 0
}
finally {
    Remove-Item Env:XINGCHEN_BRIDGE_TEST_LOG -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $bridgeFixture -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'install-agent.ps1 network policy tests passed.'
