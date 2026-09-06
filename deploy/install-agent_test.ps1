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
    'Get-AgentSource',
    'Assert-AgentBinaryVersion',
    'Merge-AgentConfiguration',
    'Test-SourceCheckoutMatchesRelease'
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

function Test-AgentVersion { $global:LASTEXITCODE = 0; 'v1.20.14' }
Assert-AgentBinaryVersion 'Test-AgentVersion' 'v1.20.14'
$wrongVersionRejected = $false
try { Assert-AgentBinaryVersion 'Test-AgentVersion' 'v1.20.17' }
catch { $wrongVersionRejected = $true }
Assert-True $wrongVersionRejected 'Agent installer accepted a binary with a mismatched version.'
function Test-AgentVersion { $global:LASTEXITCODE = 1; 'v1.20.14' }
$failedVersionRejected = $false
try { Assert-AgentBinaryVersion 'Test-AgentVersion' 'v1.20.14' }
catch { $failedVersionRejected = $true }
Assert-True $failedVersionRejected 'Agent installer accepted a failed version command.'
$global:LASTEXITCODE = 0

$existingConfig = [pscustomobject]@{
    server_url = 'https://monitor.example.com'; device_id = 'existing-device'; agent_key = 'old-test-credential'
    interval = '30s'; allow_command_execution = $true; monitored_processes = @('sqlservr')
    request_timeout = '45s'; spool_dir = 'D:\AgentData\spool'; custom_metrics = @([pscustomobject]@{ name = 'queue_depth'; args = @('one', 'two') })
    update_launcher_path = 'old-launcher'
}
$generatedConfig = [ordered]@{
    server_url = 'https://monitor.example.com'; device_id = 'existing-device'; agent_key = 'new-test-credential'
    interval = '3s'; allow_command_execution = $false; monitored_processes = @()
    request_timeout = '10s'; spool_dir = 'C:\Default\spool'; update_launcher_path = 'new-launcher'
}
$mergedConfig = Merge-AgentConfiguration $generatedConfig $existingConfig @{}
Assert-True ($mergedConfig.interval -eq '30s') 'Reinstall reset the existing collection interval.'
Assert-True ($mergedConfig.allow_command_execution -and $mergedConfig.monitored_processes[0] -eq 'sqlservr') 'Reinstall reset collection or permission settings.'
Assert-True ($mergedConfig.request_timeout -eq '45s' -and $mergedConfig.spool_dir -eq 'D:\AgentData\spool') 'Reinstall reset custom transport or spool settings.'
Assert-True ($mergedConfig.custom_metrics[0].args[1] -eq 'two') 'Reinstall lost nested custom metrics.'
Assert-True ($mergedConfig.agent_key -eq 'new-test-credential' -and $mergedConfig.update_launcher_path -eq 'new-launcher') 'Reinstall failed to refresh credentials or managed paths.'
$overriddenConfig = Merge-AgentConfiguration $generatedConfig $existingConfig @{ Interval = '3s'; AllowCommandExecution = $false; MonitoredProcess = @() }
Assert-True ($overriddenConfig.interval -eq '3s' -and -not $overriddenConfig.allow_command_execution -and $overriddenConfig.monitored_processes.Count -eq 0) 'Explicit reinstall settings did not replace stored values.'

$script:testTargetCommit = 'current-commit'
$script:testSourceChanges = ''
function git {
    $global:LASTEXITCODE = 0
    if ($args -contains 'status') { return $script:testSourceChanges }
    if ($args[-1] -eq 'HEAD') { return 'current-commit' }
    return $script:testTargetCommit
}
try {
    Assert-True (Test-SourceCheckoutMatchesRelease 'fixture' 'v1.20.14') 'Matching clean checkout was rejected.'
    $script:testTargetCommit = 'other-commit'
    Assert-True (-not (Test-SourceCheckoutMatchesRelease 'fixture' 'v1.20.14')) 'Pinned source fallback accepted a different local commit.'
    $script:testTargetCommit = 'current-commit'
    $script:testSourceChanges = ' M agent/main.go'
    Assert-True (-not (Test-SourceCheckoutMatchesRelease 'fixture' 'v1.20.14')) 'Pinned source fallback accepted modified local source.'
}
finally { Remove-Item Function:git }

$identityBlock = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ($Action -eq ''install'' -and (Test-Path -LiteralPath $configPath))')
}, $true) | Select-Object -First 1
Assert-True ($null -ne $identityBlock) 'Existing installation identity handling was not found.'
$identityFixture = Join-Path ([IO.Path]::GetTempPath()) ('xingchen-agent-identity-test-' + [Guid]::NewGuid().ToString('N') + '.json')
try {
    [IO.File]::WriteAllText($identityFixture, ($existingConfig | ConvertTo-Json -Depth 20))
    $configPath = $identityFixture
    $Action = 'install'
    $ServerUrl = ''; $DeviceId = ''; $agentKey = ''; $enrollmentToken = ''; $preservedConfig = $null
    . ([scriptblock]::Create($identityBlock.Extent.Text))
    Assert-True ($DeviceId -ceq 'existing-device' -and $ServerUrl -eq 'https://monitor.example.com' -and $agentKey -eq 'old-test-credential') 'Reinstall did not reuse the existing identity.'
    $DeviceId = 'different-device'; $agentKey = ''; $preservedConfig = $null
    . ([scriptblock]::Create($identityBlock.Extent.Text))
    Assert-True ([string]::IsNullOrEmpty($agentKey) -and $null -eq $preservedConfig) 'Installing another device reused the previous credential or settings.'
}
finally { Remove-Item -LiteralPath $identityFixture -Force }

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

$updaterAssignment = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script'
}, $true) | Select-Object -First 1
Assert-True ($null -ne $updaterAssignment) 'Generated updater was not found.'
$updaterSource = $updaterAssignment.Right.Expression.Value
$updaterTokens = $null
$updaterErrors = $null
$updaterAst = [System.Management.Automation.Language.Parser]::ParseInput($updaterSource, [ref] $updaterTokens, [ref] $updaterErrors)
Assert-True ($updaterErrors.Count -eq 0) 'Generated updater has parser errors.'
foreach ($functionAst in $updaterAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Assert-AgentBinaryVersion', 'Normalize-Version')
}, $true)) { Invoke-Expression $functionAst.Extent.Text }
function Test-AgentVersion { $global:LASTEXITCODE = 0; 'v1.20.14' }
Assert-AgentBinaryVersion 'Test-AgentVersion' 'v1.20.14'
$wrongUpdaterVersionRejected = $false
try { Assert-AgentBinaryVersion 'Test-AgentVersion' 'v1.20.17' }
catch { $wrongUpdaterVersionRejected = $true }
Assert-True $wrongUpdaterVersionRejected 'Generated updater accepted a binary with a mismatched version.'

$replacementTry = $updaterAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.TryStatementAst] -and $node.Body.Statements.Count -gt 0 -and $node.Body.Statements[0].Extent.Text -like 'Stop-Service -Name *'
}, $true) | Select-Object -First 1
Assert-True ($null -ne $replacementTry) 'Generated updater replacement transaction was not found.'
Assert-True ($updaterSource.IndexOf("Copy-Item -LiteralPath '`$targetBinary' -Destination `$backup") -lt $replacementTry.Extent.StartOffset) 'Updater stops the service before creating the backup.'
$rollbackFixture = Join-Path ([IO.Path]::GetTempPath()) ('xingchen-agent-rollback-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $rollbackFixture | Out-Null
try {
    $oldBinary = Join-Path $rollbackFixture 'agent.exe'
    $backup = Join-Path $rollbackFixture 'agent.backup'
    $staged = Join-Path $rollbackFixture 'agent.new'
    [IO.File]::WriteAllText($oldBinary, 'previous-binary')
    Copy-Item -LiteralPath $oldBinary -Destination $backup
    [IO.File]::WriteAllText($staged, 'replacement-binary')
    $script:serviceEvents = [Collections.Generic.List[string]]::new()
    $script:startAttempts = 0
    function Stop-Service { param($Name, [switch] $Force, $ErrorAction) $script:serviceEvents.Add('stop') }
    function Start-Service {
        param($Name, $ErrorAction)
        $script:serviceEvents.Add('start')
        $script:startAttempts++
        if ($script:startAttempts -eq 1) { throw 'Simulated replacement startup failure.' }
    }
    function Get-Service {
        param($Name)
        $mockService = [pscustomobject]@{}
        $mockService | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
            param($Status, $Timeout)
            $script:serviceEvents.Add("wait:$Status")
        }
        return $mockService
    }
    function Write-AgentUpdateStatus { param($Status, $Message) $script:serviceEvents.Add("status:$Status") }
    $transaction = $replacementTry.Extent.Text.Replace('$targetBinary', $oldBinary.Replace("'", "''")).Replace('$serviceName', 'MockAgent')
    $replacementFailed = $false
    try { & ([scriptblock]::Create($transaction)) }
    catch { $replacementFailed = $true }
    Assert-True $replacementFailed 'Failed replacement was incorrectly reported as successful.'
    Assert-True ((Get-Content -Raw -LiteralPath $oldBinary) -eq 'previous-binary') 'Failed replacement did not restore the previous executable.'
    Assert-True (($script:serviceEvents -join ',') -eq 'stop,wait:Stopped,start,status:ROLLING_BACK,stop,wait:Stopped,start,wait:Running') 'Rollback did not stop the failed service and wait before restoring the binary.'
}
finally {
    Remove-Item Function:Stop-Service, Function:Start-Service, Function:Get-Service, Function:Write-AgentUpdateStatus -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $rollbackFixture -Recurse -Force
}

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
