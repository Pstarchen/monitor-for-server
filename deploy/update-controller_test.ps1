$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$updater = Join-Path $scriptRoot 'update-controller.ps1'
$hostExecutable = (Get-Process -Id $PID).Path
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('xingchen-controller-update-test-' + [Guid]::NewGuid().ToString('N'))
$fakeBin = Join-Path $testRoot 'bin'
$logPath = Join-Path $testRoot 'docker.log'
$originalPath = $env:PATH

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

$policyTokens = $null
$policyErrors = $null
$policyAst = [System.Management.Automation.Language.Parser]::ParseFile($updater, [ref]$policyTokens, [ref]$policyErrors)
if ($policyErrors.Count -gt 0) { throw "Controller updater has parser errors: $($policyErrors[0].Message)" }
foreach ($name in @('Test-NetworkHostMatches', 'Test-ForbiddenPublicHost', 'Assert-InternalImageReference')) {
    $definition = $policyAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true) | Select-Object -First 1
    Assert-True ($null -ne $definition) "Missing Controller network policy function: $name"
    Invoke-Expression $definition.Extent.Text
}
$networkMode = 'internal'
$allowGitee = $false
foreach ($hostName in @('api.github.com', 'raw.githubusercontent.com', 'cdn.githubassets.com', 'cache.ghcr.io', 'registry-1.docker.io', 'hub.docker.com')) {
    Assert-True (Test-ForbiddenPublicHost $hostName) "Internal Controller policy allowed public host: $hostName"
}
Assert-True (-not (Test-ForbiddenPublicHost 'github.com.evil.example')) 'Controller suffix matching rejected a lookalike internal host.'
$giteeRejected = $false
try { Assert-InternalImageReference 'registry.gitee.com/example/controller:v1.20.14' }
catch { $giteeRejected = $true }
Assert-True $giteeRejected 'Controller policy allowed a Gitee Registry without explicit opt-in.'
$allowGitee = $true
Assert-InternalImageReference 'registry.gitee.com/example/controller:v1.20.14'

function Assert-BytesEqual([byte[]] $Expected, [byte[]] $Actual, [string] $Message) {
    if ($Expected.Length -ne $Actual.Length) { throw $Message }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) { throw $Message }
    }
}

function Write-Utf8([string] $Path, [string] $Content) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Get-HostArchitecture {
    switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
        'X64' { return 'amd64' }
        'Arm64' { return 'arm64' }
        default { throw 'Tests require an amd64 or arm64 host.' }
    }
}

function Set-TestTarField([byte[]] $Header, [int] $Offset, [int] $Length, [string] $Value) {
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Value)
    if ($bytes.Length -gt $Length) { throw "Test tar field is too long: $Value" }
    [Array]::Copy($bytes, 0, $Header, $Offset, $bytes.Length)
}

function Write-TestTarEntry([System.IO.Stream] $Stream, [string] $Name, [byte[]] $Content) {
    $header = New-Object byte[] 512
    Set-TestTarField $header 0 100 $Name
    Set-TestTarField $header 100 8 (('0000644') + [char]0)
    Set-TestTarField $header 108 8 (('0000000') + [char]0)
    Set-TestTarField $header 116 8 (('0000000') + [char]0)
    Set-TestTarField $header 124 12 ([Convert]::ToString($Content.Length, 8).PadLeft(11, '0') + [char]0)
    Set-TestTarField $header 136 12 ([Convert]::ToString(0, 8).PadLeft(11, '0') + [char]0)
    Set-TestTarField $header 148 8 '        '
    $header[156] = 48
    Set-TestTarField $header 257 6 ("ustar" + [char]0)
    Set-TestTarField $header 263 2 '00'
    $checksum = [long]0
    foreach ($value in $header) { $checksum += $value }
    Set-TestTarField $header 148 8 ([Convert]::ToString($checksum, 8).PadLeft(6, '0') + [char]0 + ' ')
    $Stream.Write($header, 0, $header.Length)
    $Stream.Write($Content, 0, $Content.Length)
    $padding = (512 - ($Content.Length % 512)) % 512
    if ($padding -gt 0) {
        $paddingBytes = New-Object byte[] $padding
        $Stream.Write($paddingBytes, 0, $paddingBytes.Length)
    }
}

function New-TestDockerArchive([string] $Path, [string] $Version, [string] $OmittedComponent = '', [bool] $IncludeUnexpected = $false) {
    $manifestEntries = [System.Collections.Generic.List[object]]::new()
    $archiveEntries = [ordered]@{}
    $components = @('setup', 'server', 'web', 'agent', 'postgres', 'redis')
    if ($IncludeUnexpected) { $components += 'unexpected' }
    foreach ($component in $components) {
        if ($component -eq $OmittedComponent) { continue }
        $image = switch ($component) {
            'postgres' { 'postgres:16-alpine' }
            'redis' { 'redis:7.4-alpine' }
            default { "ghcr.io/pstarchen/monitor-for-server-$component`:$Version" }
        }
        $config = "$component.json"
        $layer = "$component/layer.tar"
        $archiveEntries[$config] = [System.Text.Encoding]::UTF8.GetBytes('{"architecture":"amd64"}')
        $archiveEntries[$layer] = [System.Text.Encoding]::UTF8.GetBytes("layer for $component")
        [void]$manifestEntries.Add([ordered]@{ Config = $config; RepoTags = @($image); Layers = @($layer) })
    }
    $allArchiveEntries = [ordered]@{
        'manifest.json' = [System.Text.Encoding]::UTF8.GetBytes(($manifestEntries.ToArray() | ConvertTo-Json -Depth 5 -Compress))
    }
    foreach ($entry in $archiveEntries.GetEnumerator()) { $allArchiveEntries.Add($entry.Key, $entry.Value) }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        foreach ($entry in $allArchiveEntries.GetEnumerator()) { Write-TestTarEntry $stream ([string]$entry.Key) ([byte[]]$entry.Value) }
        $end = New-Object byte[] 1024
        $stream.Write($end, 0, $end.Length)
    }
    finally { $stream.Dispose() }
}

function Write-TestBundleChecksums([string] $Bundle) {
    $checksumLines = [System.Collections.Generic.List[string]]::new()
    $checksumIndex = 0
    foreach ($file in Get-ChildItem -LiteralPath $Bundle -File -Recurse | Where-Object { $_.Name -ne 'SHA256SUMS' } | Sort-Object FullName) {
        $relative = $file.FullName.Substring($Bundle.Length).TrimStart('\', '/') -replace '\\', '/'
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $marker = if (($checksumIndex++ % 2) -eq 0) { ' ' } else { '*' }
        [void]$checksumLines.Add("$hash $marker$relative")
    }
    Write-Utf8 (Join-Path $Bundle 'SHA256SUMS') ([string]::Join("`n", $checksumLines) + "`n")
}

function New-TestFixture([string] $Name) {
    $root = Join-Path $testRoot $Name
    $project = Join-Path $root 'project'
    $bundle = Join-Path $root 'bundle'
    New-Item -ItemType Directory -Path (Join-Path $project 'deploy'), (Join-Path $project 'release/assets'), (Join-Path $bundle 'deploy'), (Join-Path $bundle 'images'), (Join-Path $bundle 'release/assets') -Force | Out-Null

    $originalEnv = "# preserve comments and CRLF`r`nPOSTGRES_PASSWORD=`"test-only`"`r`nXINGCHEN_TARGET_VERSION=`"v1.20.14`"`r`nXINGCHEN_SETUP_IMAGE=`"registry.old.local/xingchen/setup:v1.20.14`"`r`nXINGCHEN_SERVER_IMAGE=`"registry.old.local/xingchen/server:v1.20.14`"`r`nXINGCHEN_WEB_IMAGE=`"registry.old.local/xingchen/web:v1.20.14`"`r`n"
    [System.IO.File]::WriteAllBytes((Join-Path $project '.env'), [System.Text.UTF8Encoding]::new($false).GetBytes($originalEnv))
    Write-Utf8 (Join-Path $project 'docker-compose.yml') "name: old-controller`nservices: {}`n"
    Write-Utf8 (Join-Path $project 'deploy/update-controller.ps1') "# old updater`r`n"
    Write-Utf8 (Join-Path $project 'release/assets/old-agent.txt') "old release`n"
    Write-Utf8 (Join-Path $project 'release/manifest.json') '{"schemaVersion":1,"version":"v1.20.14"}'

    $version = 'v1.20.16'
    $architecture = Get-HostArchitecture
    Write-Utf8 (Join-Path $bundle 'bundle-metadata.txt') "schema=1`nversion=$version`narchitecture=$architecture`n"
    Write-Utf8 (Join-Path $bundle 'docker-compose.yml') "name: candidate-controller`nservices: {}`n"
    Copy-Item -LiteralPath (Join-Path $scriptRoot 'offline-bundle-integrity.sh') -Destination (Join-Path $bundle 'deploy/offline-bundle-integrity.sh')
    Write-Utf8 (Join-Path $bundle 'deploy/update-controller.ps1') "# verified candidate updater`n"
    Write-Utf8 (Join-Path $bundle 'upgrade-offline.sh') "#!/usr/bin/env bash`n"
    Write-Utf8 (Join-Path $bundle 'upgrade-offline.ps1') "# verified offline launcher`n"
    New-TestDockerArchive (Join-Path $bundle 'images/controller-images.tar') $version

    $manifestAssets = [System.Collections.Generic.List[object]]::new()
    $assetChecksums = [System.Collections.Generic.List[string]]::new()
    foreach ($platform in @(
        [pscustomobject]@{ OS = 'linux'; Arch = 'amd64'; Extension = 'tar.gz' },
        [pscustomobject]@{ OS = 'linux'; Arch = 'arm64'; Extension = 'tar.gz' },
        [pscustomobject]@{ OS = 'windows'; Arch = 'amd64'; Extension = 'zip' },
        [pscustomobject]@{ OS = 'windows'; Arch = 'arm64'; Extension = 'zip' }
    )) {
        $assetName = "xingchen-agent_1.20.16_$($platform.OS)_$($platform.Arch).$($platform.Extension)"
        $assetPath = Join-Path $bundle "release/assets/$assetName"
        Write-Utf8 $assetPath "Agent fixture for $($platform.OS)/$($platform.Arch)`n"
        $assetHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $assetSize = (Get-Item -LiteralPath $assetPath).Length
        [void]$manifestAssets.Add([ordered]@{
            os = $platform.OS
            arch = $platform.Arch
            file = $assetName
            url = "https://releases.example.invalid/$version/$assetName"
            sha256 = $assetHash
            size = $assetSize
        })
        [void]$assetChecksums.Add("$assetHash  $assetName")
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        version = $version
        publishedAt = '2026-09-04T00:00:00Z'
        minimumCompatibleControllerVersion = 'v1.20.0'
        assets = $manifestAssets
    }
    Write-Utf8 (Join-Path $bundle 'release/manifest.json') ($manifest | ConvertTo-Json -Depth 5)
    Write-Utf8 (Join-Path $bundle 'release/assets/checksums.txt') ([string]::Join("`n", $assetChecksums) + "`n")
    Write-TestBundleChecksums $bundle
    return [pscustomobject]@{ Root = $root; Project = $project; Bundle = $bundle; Version = $version; Architecture = $architecture }
}

function Get-ReleaseState([string] $Project) {
    $release = Join-Path $Project 'release'
    $state = @{}
    if (-not (Test-Path -LiteralPath $release)) { return $state }
    foreach ($file in Get-ChildItem -LiteralPath $release -File -Recurse | Sort-Object FullName) {
        $relative = $file.FullName.Substring($release.Length).TrimStart('\', '/') -replace '\\', '/'
        $state[$relative] = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file.FullName))
    }
    return $state
}

function Assert-ReleaseState([hashtable] $Expected, [string] $Project, [string] $Message) {
    $actual = Get-ReleaseState $Project
    Assert-True ($Expected.Count -eq $actual.Count) $Message
    foreach ($key in $Expected.Keys) {
        Assert-True ($actual.ContainsKey($key) -and $actual[$key] -eq $Expected[$key]) $Message
    }
}

function Invoke-Update($Fixture, [string[]] $Arguments, [hashtable] $Environment = @{}, [bool] $IncludeBundle = $true) {
    [System.IO.File]::WriteAllText($logPath, '', [System.Text.UTF8Encoding]::new($false))
    $composeState = Join-Path $Fixture.Root 'compose-state'
    if (Test-Path -LiteralPath $composeState) { Remove-Item -LiteralPath $composeState -Force }
    $names = @(
        'TEST_DOCKER_LOG', 'TEST_ARCHITECTURE', 'TEST_IMAGE_VERSION', 'TEST_BACKUP_FAIL',
        'TEST_LOAD_FAIL', 'TEST_COMPOSE_MODE', 'TEST_COMPOSE_STATE', 'TEST_MISSING_IMAGES',
        'TEST_PULL_SUCCESS_PREFIX', 'XINGCHEN_SOURCE_REPOSITORIES', 'XINGCHEN_UPDATE_MIN_FREE_BYTES'
    )
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        $env:TEST_DOCKER_LOG = $logPath
        $env:TEST_ARCHITECTURE = $Fixture.Architecture
        $env:TEST_IMAGE_VERSION = $Fixture.Version
        $env:TEST_BACKUP_FAIL = 'false'
        $env:TEST_LOAD_FAIL = 'false'
        $env:TEST_COMPOSE_MODE = ''
        $env:TEST_COMPOSE_STATE = $composeState
        $env:TEST_MISSING_IMAGES = ''
        $env:TEST_PULL_SUCCESS_PREFIX = ''
        foreach ($entry in $Environment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
        }
        $scriptArguments = @('-ProjectRoot', $Fixture.Project)
        if ($IncludeBundle) { $scriptArguments += @('-OfflineBundle', $Fixture.Bundle) }
        $scriptArguments += $Arguments
        $renderedArguments = $scriptArguments | ForEach-Object {
            $value = [string]$_
            if ($value -match '^-[A-Za-z][A-Za-z0-9]*$') { $value } else { "'" + $value.Replace("'", "''") + "'" }
        }
        Assert-True (-not [string]::IsNullOrWhiteSpace($global:XingchenControllerUpdateFakeDockerFunction) -and
            (Test-Path -LiteralPath $global:XingchenControllerUpdateFakeDockerFunction -PathType Leaf)) 'Fake Docker function is unavailable to Invoke-Update.'
        $updaterLiteral = "'" + $updater.Replace("'", "''") + "'"
        $fakeDockerFunctionLiteral = "'" + ([string]$global:XingchenControllerUpdateFakeDockerFunction).Replace("'", "''") + "'"
        $fakeDockerDirectory = Split-Path -Parent $global:XingchenControllerUpdateFakeDockerFunction
        $fakeDockerDirectoryLiteral = "'" + $fakeDockerDirectory.Replace("'", "''") + "'"
        $fakeDockerExecutablePath = Join-Path $fakeDockerDirectory 'docker.exe'
        $fakeDockerExecutableLiteral = "'" + $fakeDockerExecutablePath.Replace("'", "''") + "'"
        $invocation = '& ' + $updaterLiteral + ' ' + ($renderedArguments -join ' ')
        $dotSourceFakeDocker = '. ' + $fakeDockerFunctionLiteral
        $prependFakeDockerPath = '$env:PATH = ' + $fakeDockerDirectoryLiteral + ' + '';'' + $env:PATH'
        $wrapperPath = Join-Path $Fixture.Root 'invoke-updater.ps1'
        $wrapper = @(
            '$ErrorActionPreference = ''Stop''',
            '$ProgressPreference = ''SilentlyContinue''',
            '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)',
            $prependFakeDockerPath,
            $dotSourceFakeDocker,
            '$resolvedDocker = (Get-Command docker -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path',
            'if (-not [string]::Equals($resolvedDocker, ' + $fakeDockerExecutableLiteral + ', [System.StringComparison]::OrdinalIgnoreCase)) { throw "Fake Docker executable resolution failed: $resolvedDocker" }',
            'try {',
            '    ' + $invocation,
            '    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }',
            '}',
            'catch {',
            '    [Console]::Out.WriteLine($_.Exception.Message)',
            '    [Console]::Out.WriteLine($_.ScriptStackTrace)',
            '    exit 1',
            '}'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($wrapperPath, $wrapper + "`r`n", [System.Text.Encoding]::Unicode)
        $stdoutPath = Join-Path $Fixture.Root 'updater.stdout.log'
        $stderrPath = Join-Path $Fixture.Root 'updater.stderr.log'
        $processArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $wrapperPath.Replace('"', '\"') + '"'
        $process = Start-Process -FilePath $hostExecutable -ArgumentList $processArguments `
            -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -Wait
        $status = $process.ExitCode
        $output = [System.IO.File]::ReadAllText($stdoutPath) + [System.IO.File]::ReadAllText($stderrPath)
        return [pscustomobject]@{ Status = $status; Output = $output; Log = [System.IO.File]::ReadAllText($logPath) }
    }
    finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}

try {
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    $controllerInstaller = Join-Path $scriptRoot 'install-controller.ps1'
    foreach ($buildOption in @('-Build', '-SourceBuild')) {
        $installStdout = Join-Path $testRoot ("install-$($buildOption.TrimStart('-')).stdout.log")
        $installStderr = Join-Path $testRoot ("install-$($buildOption.TrimStart('-')).stderr.log")
        $installArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $controllerInstaller.Replace('"', '\"') + '" -NetworkMode internal ' + $buildOption
        $installProcess = Start-Process -FilePath $hostExecutable -ArgumentList $installArguments -WindowStyle Hidden -RedirectStandardOutput $installStdout -RedirectStandardError $installStderr -PassThru -Wait
        $installOutput = [System.IO.File]::ReadAllText($installStdout) + [System.IO.File]::ReadAllText($installStderr)
        Assert-True ($installProcess.ExitCode -ne 0) "Controller installer accepted $buildOption in internal mode.`n$installOutput"
    }
    $fakeDockerSource = Join-Path $fakeBin 'fake-docker.cs'
    $fakeDockerExecutable = Join-Path $fakeBin 'docker.exe'
    Write-Utf8 $fakeDockerSource @'
using System;
using System.IO;
using System.Text;

public static class FakeDocker
{
    private static bool Has(string[] args, string value)
    {
        return Array.IndexOf(args, value) >= 0;
    }

    private static string ArgumentAfter(string[] args, string value)
    {
        int index = Array.IndexOf(args, value);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : string.Empty;
    }

    private static string EnvironmentValue(string name)
    {
        return Environment.GetEnvironmentVariable(name) ?? string.Empty;
    }

    private static bool CsvContains(string value, string expected)
    {
        foreach (string item in value.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
        {
            if (string.Equals(item.Trim(), expected, StringComparison.Ordinal)) return true;
        }
        return false;
    }

    public static int Main(string[] args)
    {
        string logPath = EnvironmentValue("TEST_DOCKER_LOG");
        File.AppendAllText(logPath, "docker " + string.Join(" ", args) + Environment.NewLine, new UTF8Encoding(false));
        if (args.Length == 0) return 0;

        if (args[0] == "compose")
        {
            if (Has(args, "version")) return 0;
            if (Has(args, "ps") && Has(args, "-q"))
            {
                Console.WriteLine("container-" + args[args.Length - 1]);
                return 0;
            }
            if (Has(args, "config"))
            {
                if (Has(args, "--images"))
                {
                    string version = EnvironmentValue("TEST_IMAGE_VERSION");
                    Console.WriteLine("ghcr.io/pstarchen/monitor-for-server-setup:" + version);
                    Console.WriteLine("ghcr.io/pstarchen/monitor-for-server-server:" + version);
                    Console.WriteLine("ghcr.io/pstarchen/monitor-for-server-web:" + version);
                    Console.WriteLine("postgres:16-alpine");
                    Console.WriteLine("redis:7.4-alpine");
                }
                return 0;
            }
            if (Has(args, "up"))
            {
                string mode = EnvironmentValue("TEST_COMPOSE_MODE");
                if (mode == "always") return 1;
                string statePath = EnvironmentValue("TEST_COMPOSE_STATE");
                if (mode == "once" && !File.Exists(statePath))
                {
                    File.WriteAllText(statePath, "failed once");
                    return 1;
                }
                return 0;
            }
        }

        if (args[0] == "inspect")
        {
            string template = ArgumentAfter(args, "--format");
            string service = args[args.Length - 1].Replace("container-", string.Empty);
            if (template.Contains(".Config.Image")) Console.WriteLine("registry.old.local/xingchen/" + service + ":v1.20.14");
            else if (template.Contains(".Image")) Console.WriteLine("sha256:old-" + service);
            return 0;
        }

        if (args.Length > 1 && args[0] == "image" && args[1] == "inspect")
        {
            string template = ArgumentAfter(args, "--format");
            string image = args[args.Length - 1];
            if (template.Length == 0 && CsvContains(EnvironmentValue("TEST_MISSING_IMAGES"), image)) return 1;
            if (template.Contains("Architecture")) Console.WriteLine(EnvironmentValue("TEST_ARCHITECTURE"));
            else if (template.Contains("org.opencontainers.image.version")) Console.WriteLine(EnvironmentValue("TEST_IMAGE_VERSION"));
            else if (template.Contains(".Id")) Console.WriteLine("sha256:old-local");
            return 0;
        }

        if (args[0] == "exec")
        {
            if (string.Join(" ", args).Contains("pg_dump") && EnvironmentValue("TEST_BACKUP_FAIL") == "true") return 1;
            return 0;
        }
        if (args[0] == "cp")
        {
            File.WriteAllText(args[args.Length - 1], "fake database backup", new UTF8Encoding(false));
            return 0;
        }
        if (args[0] == "load") return EnvironmentValue("TEST_LOAD_FAIL") == "true" ? 1 : 0;
        if (args[0] == "tag") return 0;
        if (args[0] == "pull")
        {
            string prefix = EnvironmentValue("TEST_PULL_SUCCESS_PREFIX");
            bool allowed = prefix.Length > 0 && args.Length > 1 && args[1].StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
            return allowed ? 0 : 99;
        }
        if (args[0] == "build") return 99;
        return 0;
    }
}
'@
    $compilerCandidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $compiler) { throw 'Controller updater tests require the .NET Framework C# compiler.' }
    & $compiler /nologo /target:exe "/out:$fakeDockerExecutable" $fakeDockerSource | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fakeDockerExecutable -PathType Leaf)) {
        throw 'Unable to compile the fake Docker executable.'
    }
    $global:XingchenControllerUpdateFakeDockerFunction = Join-Path $fakeBin 'fake-docker-function.ps1'
    Write-Utf8 $global:XingchenControllerUpdateFakeDockerFunction @'
function global:docker {
    $dockerArguments = @($args)
    $global:LASTEXITCODE = 0
    $line = 'docker ' + ($dockerArguments -join ' ')
    [System.IO.File]::AppendAllText($env:TEST_DOCKER_LOG, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    if ($dockerArguments.Count -eq 0) { return }
    if ($dockerArguments[0] -eq 'compose') {
        if ($dockerArguments -contains 'version') { return }
        if ($dockerArguments -contains 'ps' -and $dockerArguments -contains '-q') {
            Write-Output ('container-' + $dockerArguments[-1])
            return
        }
        if ($dockerArguments -contains 'config') {
            if ($dockerArguments -contains '--images') {
                $version = $env:TEST_IMAGE_VERSION
                Write-Output "ghcr.io/pstarchen/monitor-for-server-setup:$version"
                Write-Output "ghcr.io/pstarchen/monitor-for-server-server:$version"
                Write-Output "ghcr.io/pstarchen/monitor-for-server-web:$version"
                Write-Output 'postgres:16-alpine'
                Write-Output 'redis:7.4-alpine'
            }
            return
        }
        if ($dockerArguments -contains 'up') {
            if ($env:TEST_COMPOSE_MODE -eq 'always') { $global:LASTEXITCODE = 1; return }
            if ($env:TEST_COMPOSE_MODE -eq 'once' -and -not (Test-Path -LiteralPath $env:TEST_COMPOSE_STATE)) {
                [System.IO.File]::WriteAllText($env:TEST_COMPOSE_STATE, 'failed once')
                $global:LASTEXITCODE = 1
            }
            return
        }
    }
    if ($dockerArguments[0] -eq 'inspect') {
        $template = if ($dockerArguments -contains '--format') { $dockerArguments[[Array]::IndexOf($dockerArguments, '--format') + 1] } else { '' }
        $service = ([string]$dockerArguments[-1]).Replace('container-', '')
        if ($template -like '*.Config.Image*') { Write-Output "registry.old.local/xingchen/$service`:v1.20.14" }
        elseif ($template -like '*.Image*') { Write-Output "sha256:old-$service" }
        return
    }
    if ($dockerArguments[0] -eq 'image' -and $dockerArguments.Count -gt 1 -and $dockerArguments[1] -eq 'inspect') {
        $template = if ($dockerArguments -contains '--format') { $dockerArguments[[Array]::IndexOf($dockerArguments, '--format') + 1] } else { '' }
        $image = [string]$dockerArguments[-1]
        $missingImages = @(([string]$env:TEST_MISSING_IMAGES).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (-not $template -and $missingImages -contains $image) { $global:LASTEXITCODE = 1; return }
        if ($template -like '*Architecture*') { Write-Output $env:TEST_ARCHITECTURE }
        elseif ($template -like '*org.opencontainers.image.version*') { Write-Output $env:TEST_IMAGE_VERSION }
        elseif ($template -like '*.Id*') { Write-Output 'sha256:old-local' }
        return
    }
    if ($dockerArguments[0] -eq 'exec') {
        if (($dockerArguments -join ' ') -like '*pg_dump*' -and $env:TEST_BACKUP_FAIL -eq 'true') { $global:LASTEXITCODE = 1 }
        return
    }
    if ($dockerArguments[0] -eq 'cp') {
        [System.IO.File]::WriteAllText([string]$dockerArguments[-1], 'fake database backup', [System.Text.UTF8Encoding]::new($false))
        return
    }
    if ($dockerArguments[0] -eq 'load') {
        if ($env:TEST_LOAD_FAIL -eq 'true') { $global:LASTEXITCODE = 1 }
        return
    }
    if ($dockerArguments[0] -eq 'tag') { return }
    if ($dockerArguments[0] -eq 'pull') {
        if (-not $env:TEST_PULL_SUCCESS_PREFIX -or
            $dockerArguments.Count -lt 2 -or
            -not ([string]$dockerArguments[1]).StartsWith($env:TEST_PULL_SUCCESS_PREFIX, [System.StringComparison]::OrdinalIgnoreCase)) {
            $global:LASTEXITCODE = 99
        }
        return
    }
    if ($dockerArguments[0] -eq 'build') { $global:LASTEXITCODE = 99 }
}
'@
    Assert-True (-not [string]::IsNullOrWhiteSpace($global:XingchenControllerUpdateFakeDockerFunction) -and
        (Test-Path -LiteralPath $global:XingchenControllerUpdateFakeDockerFunction -PathType Leaf)) 'Fake Docker function was not created.'
    $env:PATH = "$fakeBin;$originalPath"

    $fixture = New-TestFixture 'default-check'
    $envBefore = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Project '.env'))
    $composeBefore = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'docker-compose.yml'))
    $updaterBefore = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'deploy/update-controller.ps1'))
    $releaseBefore = Get-ReleaseState $fixture.Project
    $result = Invoke-Update $fixture @()
    Assert-True ($result.Status -eq 0) "Default check failed: $($result.Output)"
    Assert-BytesEqual $envBefore ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Project '.env'))) 'Default check changed .env.'
    Assert-BytesEqual $composeBefore ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'docker-compose.yml'))) 'Default check changed Compose.'
    Assert-BytesEqual $updaterBefore ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'deploy/update-controller.ps1'))) 'Default check changed updater.'
    Assert-ReleaseState $releaseBefore $fixture.Project 'Default check changed release files.'
    Assert-True ($result.Log -notmatch '(?m)^docker (load|pull|build|exec|cp|tag)\b' -and $result.Log -notmatch '\bup\b') 'Default check performed a mutating Docker command.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Project '.controller-update.lock'))) 'Default check created an update lock.'

    $fixture = New-TestFixture 'deploy-junction'
    $outsideDeploy = Join-Path $fixture.Root 'outside-deploy'
    Move-Item -LiteralPath (Join-Path $fixture.Project 'deploy') -Destination $outsideDeploy
    New-Item -ItemType Junction -Path (Join-Path $fixture.Project 'deploy') -Target $outsideDeploy | Out-Null
    $outsideUpdaterBefore = [System.IO.File]::ReadAllBytes((Join-Path $outsideDeploy 'update-controller.ps1'))
    $result = Invoke-Update $fixture @('-Apply')
    Assert-True ($result.Status -ne 0 -and $result.Output -match '重解析点') "Offline apply accepted a deploy ancestor junction.`n$($result.Output)"
    Assert-BytesEqual $outsideUpdaterBefore ([System.IO.File]::ReadAllBytes((Join-Path $outsideDeploy 'update-controller.ps1'))) 'Offline apply wrote through the deploy ancestor junction.'
    Assert-True ($result.Log -notmatch '(?m)^docker (?:load|cp|tag)\b|^docker compose .*\b(?:exec|up)\b') 'Deploy junction rejection happened after a mutating Docker operation.'

    $fixture = New-TestFixture 'release-junction'
    $outsideRelease = Join-Path $fixture.Root 'outside-release'
    Move-Item -LiteralPath (Join-Path $fixture.Project 'release') -Destination $outsideRelease
    New-Item -ItemType Junction -Path (Join-Path $fixture.Project 'release') -Target $outsideRelease | Out-Null
    $outsideManifestBefore = [System.IO.File]::ReadAllBytes((Join-Path $outsideRelease 'manifest.json'))
    $result = Invoke-Update $fixture @('-Apply')
    Assert-True ($result.Status -ne 0 -and $result.Output -match '重解析点') "Offline apply accepted a release ancestor junction.`n$($result.Output)"
    Assert-BytesEqual $outsideManifestBefore ([System.IO.File]::ReadAllBytes((Join-Path $outsideRelease 'manifest.json'))) 'Offline apply wrote through the release ancestor junction.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $outsideRelease 'versions'))) 'Offline apply created a version through the release ancestor junction.'
    Assert-True ($result.Log -notmatch '(?m)^docker (?:load|cp|tag)\b|^docker compose .*\b(?:exec|up)\b') 'Release junction rejection happened after a mutating Docker operation.'

    $fixture = New-TestFixture 'offline-low-space'
    $result = Invoke-Update $fixture @('-Apply') @{ XINGCHEN_UPDATE_MIN_FREE_BYTES = [long]::MaxValue.ToString() }
    Assert-True ($result.Status -ne 0 -and $result.Output -match '可用磁盘空间不足') "Offline apply ignored the free-space preflight.`n$($result.Output)"
    Assert-True ($result.Log -notmatch '(?m)^docker (?:load|exec|cp|tag)\b|^docker compose .*\b(?:exec|up)\b') 'Offline low-space rejection happened after a backup, image load, or service mutation.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Project 'backups'))) 'Offline low-space rejection created a database backup directory.'

    $fixture = New-TestFixture 'explicit-apply'
    $result = Invoke-Update $fixture @('-Apply')
    Assert-True ($result.Status -eq 0) "Explicit apply failed: $($result.Output)`nDocker log:`n$($result.Log)"
    $backupIndex = $result.Log.IndexOf('pg_dump', [System.StringComparison]::Ordinal)
    $loadIndex = $result.Log.IndexOf('docker load --input', [System.StringComparison]::Ordinal)
    Assert-True ($backupIndex -ge 0 -and $loadIndex -gt $backupIndex) "Apply did not back up PostgreSQL before docker load.`n$($result.Log)"
    Assert-True ($result.Log -match '(?m)^docker cp ' -and $result.Log -match '(?m)^docker compose .* up .*--pull never .*--no-build .* setup server web') 'Apply did not copy the backup or health-check the expected Windows services.'
    Assert-True ($result.Log -notmatch '(?m)^docker (pull|build)\b') 'Offline bundle apply attempted a pull or build.'
    $envAfter = [System.IO.File]::ReadAllText((Join-Path $fixture.Project '.env'))
    Assert-True ($envAfter.Contains('XINGCHEN_TARGET_VERSION="v1.20.16"') -and $envAfter.Contains('XINGCHEN_NETWORK_MODE="offline"') -and $envAfter.Contains('XINGCHEN_RELEASE_MANIFEST_SHA256="')) "Apply did not persist offline candidate settings.`n$envAfter"
    Assert-BytesEqual ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Bundle 'docker-compose.yml'))) ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'docker-compose.yml'))) 'Apply did not install the verified Compose file.'
    Assert-BytesEqual ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Bundle 'deploy/update-controller.ps1'))) ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'deploy/update-controller.ps1'))) 'Apply did not install the verified updater.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $fixture.Project 'backups') -Filter '*.sql').Count -eq 1) 'Apply did not retain one PostgreSQL backup.'
    $bundleImages = @(
        'ghcr.io/pstarchen/monitor-for-server-setup:v1.20.16',
        'ghcr.io/pstarchen/monitor-for-server-server:v1.20.16',
        'ghcr.io/pstarchen/monitor-for-server-web:v1.20.16',
        'ghcr.io/pstarchen/monitor-for-server-agent:v1.20.16',
        'postgres:16-alpine',
        'redis:7.4-alpine'
    )
    foreach ($image in $bundleImages) {
        Assert-True ($result.Log.Contains("docker image inspect $image")) "Bundle image was not checked after load: $image"
        Assert-True ($result.Log -match "(?m)^docker image inspect --format .*Architecture.*$([regex]::Escape($image))") "Bundle image architecture was not checked: $image"
    }
    foreach ($image in $bundleImages[0..3]) {
        Assert-True ($result.Log -match "(?m)^docker image inspect --format .*org\.opencontainers\.image\.version.*$([regex]::Escape($image))") "Xingchen image version label was not checked: $image"
    }

    $fixture = New-TestFixture 'tampered-bundle'
    [System.IO.File]::AppendAllText((Join-Path $fixture.Bundle 'docker-compose.yml'), "tampered`n")
    $result = Invoke-Update $fixture @()
    Assert-True ($result.Status -ne 0 -and $result.Output -match '校验失败') 'Tampered bundle was accepted.'
    Assert-True ($result.Log -notmatch '(?m)^docker (load|exec|cp|tag)\b') 'Tampered bundle reached a mutating Docker command.'

    $fixture = New-TestFixture 'missing-archive-image'
    New-TestDockerArchive (Join-Path $fixture.Bundle 'images/controller-images.tar') $fixture.Version 'redis'
    Write-TestBundleChecksums $fixture.Bundle
    $result = Invoke-Update $fixture @()
    Assert-True ($result.Status -ne 0 -and $result.Output -match 'redis:7\.4-alpine') "Bundle without the Redis archive image was accepted or rejected for the wrong reason.`n$($result.Output)"
    Assert-True ($result.Log -notmatch '(?m)^docker (load|exec|cp|tag)\b') 'Missing archive image was detected only after a mutating Docker command.'

    $fixture = New-TestFixture 'extra-archive-image'
    New-TestDockerArchive (Join-Path $fixture.Bundle 'images/controller-images.tar') $fixture.Version '' $true
    Write-TestBundleChecksums $fixture.Bundle
    $result = Invoke-Update $fixture @()
    Assert-True ($result.Status -ne 0 -and $result.Output -match '只能包含六个') "Bundle with an unexpected seventh archive image was accepted or rejected for the wrong reason.`n$($result.Output)"
    Assert-True ($result.Log -notmatch '(?m)^docker (load|exec|cp|tag)\b') 'Unexpected archive image was detected only after a mutating Docker command.'

    $fixture = New-TestFixture 'incomplete-agent-manifest'
    $manifestPath = Join-Path $fixture.Bundle 'release/manifest.json'
    $manifest = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    $manifest.assets = @($manifest.assets)[0..2]
    Write-Utf8 $manifestPath ($manifest | ConvertTo-Json -Depth 5)
    Write-TestBundleChecksums $fixture.Bundle
    $result = Invoke-Update $fixture @()
    Assert-True ($result.Status -ne 0 -and $result.Output -match '四个平台') "Bundle with an incomplete Agent manifest was accepted or rejected for the wrong reason.`n$($result.Output)"
    Assert-True ($result.Log -notmatch '(?m)^docker (load|exec|cp|tag)\b') 'Incomplete Agent manifest was detected only after a mutating Docker command.'

    $fixture = New-TestFixture 'agent-checksum-mismatch'
    $checksumsPath = Join-Path $fixture.Bundle 'release/assets/checksums.txt'
    $checksumLines = [System.IO.File]::ReadAllLines($checksumsPath)
    $checksumLines[0] = ('0' * 64) + $checksumLines[0].Substring(64)
    Write-Utf8 $checksumsPath ([string]::Join("`n", $checksumLines) + "`n")
    Write-TestBundleChecksums $fixture.Bundle
    $result = Invoke-Update $fixture @()
    Assert-True ($result.Status -ne 0 -and $result.Output -match 'checksums\.txt 与 manifest 不一致') "Bundle with inconsistent Agent checksums was accepted or rejected for the wrong reason.`n$($result.Output)"
    Assert-True ($result.Log -notmatch '(?m)^docker (load|exec|cp|tag)\b') 'Agent checksum mismatch was detected only after a mutating Docker command.'

    $fixture = New-TestFixture 'missing-offline-launcher'
    Remove-Item -LiteralPath (Join-Path $fixture.Bundle 'upgrade-offline.ps1') -Force
    $checksumLines = [System.IO.File]::ReadAllLines((Join-Path $fixture.Bundle 'SHA256SUMS')) |
        Where-Object { $_ -notmatch ' [ *]upgrade-offline\.ps1$' }
    Write-Utf8 (Join-Path $fixture.Bundle 'SHA256SUMS') ([string]::Join("`n", $checksumLines) + "`n")
    $result = Invoke-Update $fixture @()
    Assert-True ($result.Status -ne 0 -and $result.Output -match '缺少必要文件：upgrade-offline\.ps1') "Bundle without the PowerShell offline launcher was accepted or rejected for the wrong reason.`n$($result.Output)"
    Assert-True ($result.Log -notmatch '(?m)^docker load\b') 'Missing offline launcher was detected only after docker load.'

    $fixture = New-TestFixture 'backup-failure'
    $envBefore = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Project '.env'))
    $composeBefore = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'docker-compose.yml'))
    $result = Invoke-Update $fixture @('-Apply') @{ TEST_BACKUP_FAIL = 'true' }
    Assert-True ($result.Status -ne 0) 'Backup failure reported success.'
    Assert-True ($result.Log -notmatch '(?m)^docker load\b') 'docker load ran after PostgreSQL backup failure.'
    Assert-BytesEqual $envBefore ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Project '.env'))) 'Backup failure changed .env.'
    Assert-BytesEqual $composeBefore ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'docker-compose.yml'))) 'Backup failure changed Compose.'

    $fixture = New-TestFixture 'load-failure'
    $envBefore = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Project '.env'))
    $composeBefore = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'docker-compose.yml'))
    $updaterBefore = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'deploy/update-controller.ps1'))
    $releaseBefore = Get-ReleaseState $fixture.Project
    $result = Invoke-Update $fixture @('-Apply') @{ TEST_LOAD_FAIL = 'true' }
    Assert-True ($result.Status -eq 10) "Load failure returned $($result.Status), expected recoverable status 10. $($result.Output)"
    Assert-BytesEqual $envBefore ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Project '.env'))) 'Load failure did not restore .env exactly.'
    Assert-BytesEqual $composeBefore ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'docker-compose.yml'))) 'Load failure did not restore Compose exactly.'
    Assert-BytesEqual $updaterBefore ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'deploy/update-controller.ps1'))) 'Load failure did not restore updater exactly.'
    Assert-ReleaseState $releaseBefore $fixture.Project 'Load failure did not restore release state.'

    $fixture = New-TestFixture 'configuration-restoration'
    $envBefore = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Project '.env'))
    $composeBefore = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'docker-compose.yml'))
    $updaterBefore = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'deploy/update-controller.ps1'))
    $releaseBefore = Get-ReleaseState $fixture.Project
    $result = Invoke-Update $fixture @('-Apply') @{ TEST_COMPOSE_MODE = 'once' }
    Assert-True ($result.Status -eq 10) "Candidate health failure returned $($result.Status), expected 10. $($result.Output)"
    Assert-BytesEqual $envBefore ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Project '.env'))) 'Rollback did not restore .env byte-for-byte.'
    Assert-BytesEqual $composeBefore ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'docker-compose.yml'))) 'Rollback did not restore Compose byte-for-byte.'
    Assert-BytesEqual $updaterBefore ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Project 'deploy/update-controller.ps1'))) 'Rollback did not restore updater byte-for-byte.'
    Assert-ReleaseState $releaseBefore $fixture.Project 'Rollback did not restore release state.'
    Assert-True (([regex]::Matches($result.Log, '(?m)^docker compose .* up ')).Count -eq 2) 'Rollback did not run a second Compose health check.'
    foreach ($service in @('setup', 'server', 'web')) {
        Assert-True ($result.Log.Contains("docker tag sha256:old-$service registry.old.local/xingchen/$service`:v1.20.14")) "Rollback did not restore the $service image ID."
    }
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $fixture.Project 'backups') -Filter '*.sql').Count -eq 1) 'Rollback removed the database backup instead of leaving manual recovery evidence.'

    $fixture = New-TestFixture 'online-check-compatibility'
    Write-Utf8 (Join-Path $fixture.Project '.env') @'
POSTGRES_PASSWORD="test-only"
COMPOSE_PROJECT_NAME="test-controller"
XINGCHEN_NETWORK_MODE="public"
XINGCHEN_TARGET_VERSION="v1.20.16"
'@
    $result = Invoke-Update $fixture @('-Check', '-NoMirror', '-NoSourceFallback') @{ TEST_PULL_SUCCESS_PREFIX = 'ghcr.io/' } $false
    Assert-True ($result.Status -eq 0) "Online Check no longer prepares candidate images.`n$($result.Output)`n$($result.Log)"
    Assert-True ($result.Log.Contains('docker pull ghcr.io/pstarchen/monitor-for-server-server:v1.20.16')) "Online Check did not pull the expected candidate image.`n$($result.Log)"
    Assert-True ($result.Log -notmatch '(?m)^docker (build|compose .* up)\b') 'Online Check restarted services or built from source after successful pulls.'

    $result = Invoke-Update $fixture @('-Apply', '-NoMirror', '-NoSourceFallback') @{ TEST_PULL_SUCCESS_PREFIX = 'ghcr.io/' } $false
    Assert-True ($result.Status -eq 0) "Online Apply failed: $($result.Output)`n$($result.Log)"
    $backupIndex = $result.Log.IndexOf('pg_dump', [System.StringComparison]::Ordinal)
    $pullIndex = $result.Log.IndexOf('docker pull ', [System.StringComparison]::Ordinal)
    Assert-True ($backupIndex -ge 0 -and $pullIndex -gt $backupIndex) "Online Apply did not back up PostgreSQL before pulling images.`n$($result.Log)"
    $onlineBackups = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Project 'backups') -Filter '*.sql')
    Assert-True ($onlineBackups.Count -eq 1 -and $onlineBackups[0].Name -match '^xingchen-monitor-[0-9]{8}T[0-9]{6}Z-[0-9]+\.sql$') 'Online Apply backup is not visible to the Controller restore service.'

    $fixture = New-TestFixture 'online-backup-failure'
    Write-Utf8 (Join-Path $fixture.Project '.env') @'
POSTGRES_PASSWORD="test-only"
COMPOSE_PROJECT_NAME="test-controller"
XINGCHEN_NETWORK_MODE="public"
XINGCHEN_TARGET_VERSION="v1.20.16"
'@
    $result = Invoke-Update $fixture @('-Apply', '-NoMirror', '-NoSourceFallback') @{ TEST_BACKUP_FAIL = 'true'; TEST_PULL_SUCCESS_PREFIX = 'ghcr.io/' } $false
    Assert-True ($result.Status -ne 0) 'Online Apply continued after a database backup failure.'
    Assert-True ($result.Log -notmatch '(?m)^docker (pull|build)\b|^docker compose .*\bup\b') 'Online backup failure reached image preparation or service switching.'

    $fixture = New-TestFixture 'public-no-source-fallback'
    Write-Utf8 (Join-Path $fixture.Project '.env') @'
POSTGRES_PASSWORD="test-only"
COMPOSE_PROJECT_NAME="test-controller"
XINGCHEN_NETWORK_MODE="public"
XINGCHEN_TARGET_VERSION="v1.20.16"
XINGCHEN_SOURCE_REPOSITORIES=""
'@
    $result = Invoke-Update $fixture @('-Check', '-NoMirror') @{ XINGCHEN_SOURCE_REPOSITORIES = '' } $false
    Assert-True ($result.Status -ne 0 -and $result.Output -match '源码构建回退已关闭') "Public mode with no source repositories did not fail closed.`n$($result.Output)"
    Assert-True ($result.Log -notmatch '(?im)^docker build\b|github\.com|gitee\.com') 'Empty source repository configuration invoked an implicit public source fallback.'

    $fixture = New-TestFixture 'leading-zero-target'
    Write-Utf8 (Join-Path $fixture.Project '.env') @'
POSTGRES_PASSWORD="test-only"
COMPOSE_PROJECT_NAME="test-controller"
XINGCHEN_NETWORK_MODE="public"
XINGCHEN_TARGET_VERSION="v01.20.15"
'@
    $result = Invoke-Update $fixture @('-Check', '-NoMirror', '-NoSourceFallback') @{} $false
    Assert-True ($result.Status -ne 0) 'Controller updater accepted a leading-zero target version.'
    Assert-True ($result.Log -notmatch '(?m)^docker (pull|build)\b') 'Controller updater accessed an image source before rejecting a leading-zero version.'

    $fixture = New-TestFixture 'offline-network-mode'
    Write-Utf8 (Join-Path $fixture.Project '.env') @'
POSTGRES_PASSWORD="test-only"
COMPOSE_PROJECT_NAME="test-controller"
XINGCHEN_TARGET_VERSION="v1.20.16"
'@
    $result = Invoke-Update $fixture @('-Check', '-Offline') @{} $false
    Assert-True ($result.Status -eq 0) "CLI offline Check failed with complete local images.`n$($result.Output)"
    Assert-True ($result.Log -notmatch '(?m)^docker (pull|build)\b') 'CLI offline mode attempted a registry pull or remote build.'
    $result = Invoke-Update $fixture @('-Apply', '-Offline') @{} $false
    Assert-True ($result.Status -eq 0) "CLI offline Apply failed with complete local images.`n$($result.Output)"
    Assert-True ($result.Log -match '(?m)^docker compose .*\bup\b.*--pull never') 'CLI offline Apply did not prohibit Compose pulls.'

    $fixture = New-TestFixture 'internal-local-ghcr'
    Write-Utf8 (Join-Path $fixture.Project '.env') @'
POSTGRES_PASSWORD="test-only"
COMPOSE_PROJECT_NAME="test-controller"
XINGCHEN_NETWORK_MODE="internal"
XINGCHEN_TARGET_VERSION="v1.20.16"
XINGCHEN_POSTGRES_IMAGE="registry.internal.example/library/postgres:16-alpine"
XINGCHEN_REDIS_IMAGE="registry.internal.example/library/redis:7.4-alpine"
'@
    $result = Invoke-Update $fixture @('-Check') @{} $false
    Assert-True ($result.Status -eq 0) "internal mode rejected locally available GHCR logical images.`n$($result.Output)"
    Assert-True ($result.Log -notmatch '(?m)^docker (pull|build)\b') 'internal local-image path unexpectedly used the network.'

    $missingLogicalImages = @(
        'ghcr.io/pstarchen/monitor-for-server-setup:v1.20.16',
        'ghcr.io/pstarchen/monitor-for-server-server:v1.20.16',
        'ghcr.io/pstarchen/monitor-for-server-web:v1.20.16'
    ) -join ','
    $fixture = New-TestFixture 'internal-missing-mirror'
    Write-Utf8 (Join-Path $fixture.Project '.env') @'
POSTGRES_PASSWORD="test-only"
COMPOSE_PROJECT_NAME="test-controller"
XINGCHEN_NETWORK_MODE="internal"
XINGCHEN_TARGET_VERSION="v1.20.16"
XINGCHEN_POSTGRES_IMAGE="registry.internal.example/library/postgres:16-alpine"
XINGCHEN_REDIS_IMAGE="registry.internal.example/library/redis:7.4-alpine"
'@
    $result = Invoke-Update $fixture @('-Check') @{ TEST_MISSING_IMAGES = $missingLogicalImages } $false
    Assert-True ($result.Status -ne 0 -and $result.Output -match '未配置可用的内部镜像源') "internal mode accepted a missing GHCR image without a mirror.`n$($result.Output)"
    Assert-True ($result.Log -notmatch '(?m)^docker (pull|build)\b') 'internal missing-mirror failure occurred after a network operation.'

    $fixture = New-TestFixture 'internal-ghcr-mirror'
    Write-Utf8 (Join-Path $fixture.Project '.env') @'
POSTGRES_PASSWORD="test-only"
COMPOSE_PROJECT_NAME="test-controller"
XINGCHEN_NETWORK_MODE="internal"
XINGCHEN_TARGET_VERSION="v1.20.16"
XINGCHEN_CONTROLLER_IMAGE_MIRRORS="registry.internal.example"
XINGCHEN_POSTGRES_IMAGE="registry.internal.example/library/postgres:16-alpine"
XINGCHEN_REDIS_IMAGE="registry.internal.example/library/redis:7.4-alpine"
'@
    $result = Invoke-Update $fixture @('-Check') @{
        TEST_MISSING_IMAGES = $missingLogicalImages
        TEST_PULL_SUCCESS_PREFIX = 'registry.internal.example/'
    } $false
    Assert-True ($result.Status -eq 0) "internal mirror flow failed.`n$($result.Output)"
    foreach ($service in @('setup', 'server', 'web')) {
        $internalImage = "registry.internal.example/pstarchen/monitor-for-server-$service`:v1.20.16"
        $logicalImage = "ghcr.io/pstarchen/monitor-for-server-$service`:v1.20.16"
        Assert-True ($result.Log.Contains("docker pull $internalImage")) "internal mirror did not pull $service."
        Assert-True ($result.Log.Contains("docker tag $internalImage $logicalImage")) "internal mirror did not tag the $service logical image."
    }
    Assert-True ($result.Log -notmatch '(?m)^docker pull ghcr\.io/' -and $result.Log -notmatch '(?m)^docker build\b') 'internal mirror flow fell back to a public registry or source build.'

    foreach ($buildOption in @('-Build', '-SourceBuild')) {
        $result = Invoke-Update $fixture @('-Check', $buildOption) @{} $false
        Assert-True ($result.Status -ne 0 -and $result.Output -match 'internal 网络模式禁止') "internal Controller updater accepted $buildOption.`n$($result.Output)"
        Assert-True ($result.Log -notmatch '(?m)^docker (pull|build)\b') "internal $buildOption rejection happened after a pull/build operation."
    }

    $fixture = New-TestFixture 'internal-no-source-fallback'
    Write-Utf8 (Join-Path $fixture.Project '.env') @'
POSTGRES_PASSWORD="test-only"
COMPOSE_PROJECT_NAME="test-controller"
XINGCHEN_NETWORK_MODE="internal"
XINGCHEN_TARGET_VERSION="v1.20.16"
XINGCHEN_SETUP_IMAGE="registry.internal.example/xingchen/setup:v1.20.16"
XINGCHEN_SERVER_IMAGE="registry.internal.example/xingchen/server:v1.20.16"
XINGCHEN_WEB_IMAGE="registry.internal.example/xingchen/web:v1.20.16"
XINGCHEN_POSTGRES_IMAGE="registry.internal.example/library/postgres:16-alpine"
XINGCHEN_REDIS_IMAGE="registry.internal.example/library/redis:7.4-alpine"
'@
    $result = Invoke-Update $fixture @('-Check') @{} $false
    Assert-True ($result.Status -ne 0 -and $result.Output -match '源码构建回退已关闭') "internal Controller pull failure did not fail closed.`n$($result.Output)"
    Assert-True ($result.Log -notmatch '(?m)^docker build\b') 'internal Controller pull failure invoked source fallback.'

    $fixture = New-TestFixture 'internal-network-policy'
    Write-Utf8 (Join-Path $fixture.Project '.env') @'
POSTGRES_PASSWORD="test-only"
COMPOSE_PROJECT_NAME="test-controller"
XINGCHEN_NETWORK_MODE="internal"
XINGCHEN_SOURCE_REPOSITORIES="https://git.internal.example/monitor.git"
XINGCHEN_SETUP_IMAGE="registry.internal.example/xingchen/setup:v1.20.16"
XINGCHEN_SERVER_IMAGE="registry.internal.example/xingchen/server:v1.20.16"
XINGCHEN_WEB_IMAGE="registry.internal.example/xingchen/web:v1.20.16"
XINGCHEN_POSTGRES_IMAGE="postgres:16-alpine"
XINGCHEN_REDIS_IMAGE="registry.internal.example/library/redis:7.4-alpine"
'@
    $result = Invoke-Update $fixture @('-Check', '-NoSourceFallback') @{} $false
    Assert-True ($result.Status -ne 0 -and $result.Output -match '无 registry') "internal mode accepted a hostless PostgreSQL image.`n$($result.Output)`n$($result.Log)"
    Assert-True ($result.Log -notmatch '(?m)^docker (pull|build)\b') 'internal policy rejected a public reference only after pull/build.'

    $fixture = New-TestFixture 'gitee-opt-in'
    Write-Utf8 (Join-Path $fixture.Project '.env') @'
POSTGRES_PASSWORD="test-only"
COMPOSE_PROJECT_NAME="test-controller"
XINGCHEN_NETWORK_MODE="public"
XINGCHEN_ALLOW_GITEE="false"
XINGCHEN_SOURCE_REPOSITORIES="https://gitee.com/starchen520/monitor-for-server.git"
'@
    $result = Invoke-Update $fixture @('-Check', '-NoSourceFallback') @{} $false
    Assert-True ($result.Status -ne 0 -and $result.Output -match 'XINGCHEN_ALLOW_GITEE=true') 'Gitee was usable without explicit opt-in.'
    Assert-True ($result.Log -notmatch '(?m)^docker (pull|build)\b') 'Gitee policy was enforced only after pull/build.'

    $fixture = New-TestFixture 'internal-github-source'
    Write-Utf8 (Join-Path $fixture.Project '.env') @'
POSTGRES_PASSWORD="test-only"
COMPOSE_PROJECT_NAME="test-controller"
XINGCHEN_NETWORK_MODE="internal"
XINGCHEN_SOURCE_REPOSITORIES="https://github.com/Pstarchen/monitor-for-server.git"
XINGCHEN_SETUP_IMAGE="registry.internal.example/xingchen/setup:v1.20.16"
XINGCHEN_SERVER_IMAGE="registry.internal.example/xingchen/server:v1.20.16"
XINGCHEN_WEB_IMAGE="registry.internal.example/xingchen/web:v1.20.16"
XINGCHEN_POSTGRES_IMAGE="registry.internal.example/library/postgres:16-alpine"
XINGCHEN_REDIS_IMAGE="registry.internal.example/library/redis:7.4-alpine"
'@
    $result = Invoke-Update $fixture @('-Check', '-NoSourceFallback') @{} $false
    Assert-True ($result.Status -ne 0 -and $result.Output -match '拒绝公共 GitHub 源') 'internal mode accepted a GitHub source repository.'
    Assert-True ($result.Log -notmatch '(?m)^docker (pull|build)\b') 'GitHub source policy was enforced only after a network operation.'

    Write-Host 'update-controller.ps1 behavior tests passed.'
}
finally {
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
