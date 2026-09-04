$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$promoter = Join-Path $scriptRoot 'promote-internal-release.ps1'
$hostExecutable = (Get-Process -Id $PID).Path
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('xingchen-internal-promotion-test-' + [Guid]::NewGuid().ToString('N'))
$fakeBin = Join-Path $testRoot 'bin'
$dockerLog = Join-Path $testRoot 'docker.log'
$dockerState = Join-Path $testRoot 'docker-state.txt'
$originalPath = $env:PATH
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$componentNames = @('setup', 'server', 'web', 'agent', 'postgres', 'redis')
$digestCharacters = @('a', 'b', 'c', 'd', 'e', 'f')
$sourceRepositories = [ordered] @{
    setup = 'ghcr.io/example/xingchen-setup'
    server = 'ghcr.io/example/xingchen-server'
    web = 'ghcr.io/example/xingchen-web'
    agent = 'ghcr.io/example/xingchen-agent'
    postgres = 'docker.io/library/postgres'
    redis = 'docker.io/library/redis'
}

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Write-Utf8([string] $Path, [string] $Content) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-LowerSha256([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-TestFixture([string] $Name) {
    $root = Join-Path $testRoot $Name
    $artifacts = Join-Path $root 'artifacts'
    $output = Join-Path $root 'output'
    New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
    $versionNumber = '1.20.14'
    $names = @(
        "xingchen-agent_${versionNumber}_linux_amd64.tar.gz",
        "xingchen-agent_${versionNumber}_linux_arm64.tar.gz",
        "xingchen-agent_${versionNumber}_windows_amd64.zip",
        "xingchen-agent_${versionNumber}_windows_arm64.zip"
    )
    $checksumLines = @()
    foreach ($nameEntry in $names) {
        $path = Join-Path $artifacts $nameEntry
        Write-Utf8 $path "fixture:$nameEntry`n"
        $checksumLines += "$(Get-LowerSha256 $path)  $nameEntry"
    }
    Write-Utf8 (Join-Path $artifacts 'checksums.txt') (($checksumLines -join "`n") + "`n")

    $lock = [ordered] @{
        schemaVersion = 1
        version = 'v1.20.14'
        images = [ordered] @{}
    }
    for ($index = 0; $index -lt $componentNames.Count; $index++) {
        $component = $componentNames[$index]
        $lock.images[$component] = [ordered] @{
            source = $sourceRepositories[$component]
            digest = 'sha256:' + ($digestCharacters[$index] * 64)
        }
    }
    $lockPath = Join-Path $root 'source-images.lock.json'
    Write-Utf8 $lockPath (($lock | ConvertTo-Json -Depth 5) + "`n")
    return [pscustomobject] @{
        Root = $root
        Artifacts = $artifacts
        Output = $output
        Lock = $lockPath
        Names = $names
    }
}

function Reset-FakeDocker {
    foreach ($path in @($dockerLog, $dockerState)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

function Invoke-Promotion(
    $Fixture,
    [string[]] $AdditionalArguments = @(),
    [string] $TargetRegistry = 'registry.internal.example/xingchen',
    [string] $ArtifactBaseUrl = 'https://releases.internal.example/xingchen',
    [string] $Version = 'v1.20.14'
) {
    Reset-FakeDocker
    $arguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $promoter,
        '-Version',
        $Version,
        '-TargetRegistry',
        $TargetRegistry,
        '-ArtifactDir',
        $Fixture.Artifacts,
        '-ArtifactBaseUrl',
        $ArtifactBaseUrl,
        '-ImageLockFile',
        $Fixture.Lock,
        '-OutputDir',
        $Fixture.Output,
        '-PublishedAt',
        '2026-09-04T08:00:00+08:00'
    ) + $AdditionalArguments
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $hostExecutable @arguments 2>&1)
        $status = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    return [pscustomobject] @{
        Status = $status
        Output = [string]::Join("`n", [string[]] $output)
        Log = if (Test-Path -LiteralPath $dockerLog) { [System.IO.File]::ReadAllText($dockerLog) } else { '' }
    }
}

function Assert-Failed($Result, [string] $Pattern, [string] $Message) {
    Assert-True ($Result.Status -ne 0) "$Message`n$($Result.Output)"
    if ($Pattern) {
        Assert-True ($Result.Output -match $Pattern) "$Message（错误信息不匹配）`n$($Result.Output)"
    }
    Assert-True ($Result.Log -notmatch '(?m)^docker buildx imagetools create\b') "$Message（失败前已写 Registry）`n$($Result.Log)"
}

try {
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    $env:PROMOTION_DOCKER_LOG = $dockerLog
    $env:PROMOTION_DOCKER_STATE = $dockerState
    $fakeDocker = Join-Path $fakeBin 'fake-docker.ps1'
    Write-Utf8 $fakeDocker @'
$ErrorActionPreference = 'Stop'
$arguments = @($args)
[System.IO.File]::AppendAllText($env:PROMOTION_DOCKER_LOG, 'docker ' + ($arguments -join ' ') + "`n", [System.Text.UTF8Encoding]::new($false))
if ($arguments.Count -lt 4 -or $arguments[0] -ne 'buildx' -or $arguments[1] -ne 'imagetools') { exit 90 }

if ($arguments[2] -eq 'inspect') {
    $reference = [string] $arguments[3]
    $at = $reference.LastIndexOf('@')
    if ($at -ge 0) {
        Write-Output ('Digest: ' + $reference.Substring($at + 1))
        exit 0
    }
    if ($env:PROMOTION_DOCKER_INSPECT_ERROR_COMPONENT -and $reference.Contains('/' + $env:PROMOTION_DOCKER_INSPECT_ERROR_COMPONENT + ':')) {
        [Console]::Error.WriteLine('unauthorized')
        exit 2
    }
    if ($env:PROMOTION_DOCKER_CONFLICT_COMPONENT -and $reference.Contains('/' + $env:PROMOTION_DOCKER_CONFLICT_COMPONENT + ':')) {
        Write-Output ('Digest: sha256:' + ('f' * 64))
        exit 0
    }
    if (Test-Path -LiteralPath $env:PROMOTION_DOCKER_STATE) {
        foreach ($line in [System.IO.File]::ReadAllLines($env:PROMOTION_DOCKER_STATE)) {
            $parts = $line.Split('|')
            if ($parts.Count -eq 2 -and $parts[0] -ceq $reference) {
                Write-Output ('Digest: ' + $parts[1])
                exit 0
            }
        }
    }
    [Console]::Error.WriteLine('manifest unknown')
    exit 1
}

if ($arguments[2] -eq 'create') {
    $tagIndex = -1
    for ($index = 3; $index -lt $arguments.Count; $index++) {
        if ($arguments[$index] -ceq '--tag') { $tagIndex = $index; break }
    }
    if ($tagIndex -lt 0 -or $tagIndex + 2 -ge $arguments.Count) { exit 91 }
    $target = [string] $arguments[$tagIndex + 1]
    $source = [string] $arguments[$arguments.Count - 1]
    $at = $source.LastIndexOf('@')
    if ($at -lt 0) { exit 92 }
    $digest = $source.Substring($at + 1)
    [System.IO.File]::AppendAllText($env:PROMOTION_DOCKER_STATE, "$target|$digest`n", [System.Text.UTF8Encoding]::new($false))
    exit 0
}
exit 93
'@

    if ($isWindowsHost) {
        $wrapper = Join-Path $fakeBin 'docker.cmd'
        $escapedHost = $hostExecutable.Replace('%', '%%')
        $escapedFake = $fakeDocker.Replace('%', '%%')
        Write-Utf8 $wrapper "@echo off`r`n`"$escapedHost`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$escapedFake`" %*`r`nexit /b %ERRORLEVEL%`r`n"
    } else {
        $wrapper = Join-Path $fakeBin 'docker'
        $env:PROMOTION_TEST_PWSH = $hostExecutable
        $env:PROMOTION_TEST_FAKE_DOCKER = $fakeDocker
        Write-Utf8 $wrapper "#!/bin/sh`nexec `"`$PROMOTION_TEST_PWSH`" -NoProfile -NonInteractive -File `"`$PROMOTION_TEST_FAKE_DOCKER`" `"`$@`"`n"
        & chmod 0755 $wrapper
        if ($LASTEXITCODE -ne 0) { throw 'Unable to make fake docker executable.' }
    }
    $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$originalPath"

    $fixture = New-TestFixture 'valid'
    $result = Invoke-Promotion $fixture @('-WriteEnvExample')
    Assert-True ($result.Status -eq 0) "有效晋级流程失败。`n$($result.Output)"
    Assert-True (([regex]::Matches($result.Log, '(?m)^docker buildx imagetools create --tag ')).Count -eq 6) '未精确晋级六个镜像。'
    Assert-True ($result.Log -notmatch '(?i)(?:^|[:/@])latest(?:$|\s)') '晋级流程生成了 latest。'
    for ($index = 0; $index -lt $componentNames.Count; $index++) {
        $component = $componentNames[$index]
        $digest = 'sha256:' + ($digestCharacters[$index] * 64)
        $expectedCommand = "docker buildx imagetools create --tag registry.internal.example/xingchen/$component`:v1.20.14 $($sourceRepositories[$component])@$digest"
        Assert-True ($result.Log.Contains($expectedCommand)) "晋级命令未使用 source@digest -> target:version：$component"
    }
    foreach ($name in $fixture.Names) {
        $source = Join-Path $fixture.Artifacts $name
        $destination = Join-Path $fixture.Output $name
        Assert-True (Test-Path -LiteralPath $destination -PathType Leaf) "输出缺少制品：$name"
        Assert-True ((Get-LowerSha256 $source) -ceq (Get-LowerSha256 $destination)) "输出制品不一致：$name"
    }
    $manifest = [System.IO.File]::ReadAllText((Join-Path $fixture.Output 'manifest.json')) | ConvertFrom-Json
    Assert-True ($manifest.version -ceq 'v1.20.14' -and $manifest.assets.Count -eq 4) 'manifest.json 基本契约无效。'
    foreach ($asset in $manifest.assets) {
        Assert-True ($asset.url -ceq "https://releases.internal.example/xingchen/v1.20.14/$($asset.file)") "manifest URL 未指向内部版本目录：$($asset.url)"
        Assert-True ([int64] $asset.size -gt 0 -and [string] $asset.sha256 -cmatch '^[a-f0-9]{64}$') 'manifest 缺少 size/SHA256。'
    }
    $manifestChecksum = [System.IO.File]::ReadAllText((Join-Path $fixture.Output 'manifest.json.sha256')).Split(' ')[0]
    Assert-True ($manifestChecksum -ceq (Get-LowerSha256 (Join-Path $fixture.Output 'manifest.json'))) 'manifest.json.sha256 无效。'
    $outputLock = [System.IO.File]::ReadAllText((Join-Path $fixture.Output 'controller-images.lock.json')) | ConvertFrom-Json
    foreach ($component in $componentNames) {
        $reference = [string] $outputLock.images.PSObject.Properties[$component].Value
        Assert-True ($reference -cmatch "^registry\.internal\.example/xingchen/$component@sha256:[a-f0-9]{64}$") "输出镜像锁非不可变引用：$reference"
    }
    $envExample = [System.IO.File]::ReadAllText((Join-Path $fixture.Output 'controller-images.env.example'))
    Assert-True ($envExample -notmatch '(?i)password|token|latest|docker\.io|ghcr\.io|github' -and ([regex]::Matches($envExample, '@sha256:')).Count -eq 6) '环境变量示例包含凭据、公共 Registry、latest 或非 digest 引用。'
    foreach ($variable in @('XINGCHEN_SETUP_IMAGE', 'XINGCHEN_SERVER_IMAGE', 'XINGCHEN_WEB_IMAGE', 'XINGCHEN_AGENT_IMAGE', 'XINGCHEN_POSTGRES_IMAGE', 'XINGCHEN_REDIS_IMAGE')) {
        Assert-True ($envExample -cmatch "(?m)^$variable=registry\.internal\.example/xingchen/[a-z]+@sha256:[a-f0-9]{64}$") "环境变量示例缺少内部 digest 引用：$variable"
    }

    $fixture = New-TestFixture 'check-only'
    $result = Invoke-Promotion $fixture @('-Check')
    Assert-True ($result.Status -eq 0) "Check 失败。`n$($result.Output)"
    Assert-True ([string]::IsNullOrEmpty($result.Log)) 'Check 访问了 Docker/Registry。'
    Assert-True (-not (Test-Path -LiteralPath $fixture.Output)) 'Check 写入了 OutputDir。'

    $fixture = New-TestFixture 'dry-run'
    $result = Invoke-Promotion $fixture @('-DryRun')
    Assert-True ($result.Status -eq 0 -and ([regex]::Matches($result.Output, 'imagetools create --tag')).Count -eq 6) "DryRun 未输出完整六镜像计划。`n$($result.Output)"
    Assert-True ([string]::IsNullOrEmpty($result.Log) -and -not (Test-Path -LiteralPath $fixture.Output)) 'DryRun 访问了 Registry 或写入了 OutputDir。'

    $fixture = New-TestFixture 'missing-asset'
    Remove-Item -LiteralPath (Join-Path $fixture.Artifacts $fixture.Names[3]) -Force
    Assert-Failed (Invoke-Promotion $fixture @('-Check')) '缺少 Agent 制品' '缺失平台制品被接受。'

    $fixture = New-TestFixture 'bad-hash'
    [System.IO.File]::AppendAllText((Join-Path $fixture.Artifacts $fixture.Names[0]), 'tampered', $utf8NoBom)
    Assert-Failed (Invoke-Promotion $fixture @('-Check')) 'SHA256 校验失败' '错误制品哈希被接受。'

    $publicRegistries = @('ghcr.io/example', 'docker.io/example', 'registry.hub.docker.com/example', 'github.com/example', 'registry.gitee.com/example')
    for ($index = 0; $index -lt $publicRegistries.Count; $index++) {
        $fixture = New-TestFixture "public-registry-$index"
        Assert-Failed (Invoke-Promotion $fixture @('-Check') $publicRegistries[$index]) '内部 Registry' "公共目标 Registry 被接受：$($publicRegistries[$index])"
    }

    $fixture = New-TestFixture 'hostless-registry'
    Assert-Failed (Invoke-Promotion $fixture @('-Check') 'xingchen/release') 'hostless' 'hostless 目标 Registry 被接受。'

    $fixture = New-TestFixture 'short-registry-with-port'
    $result = Invoke-Promotion $fixture @('-Check') 'registry:5000/xingchen'
    Assert-True ($result.Status -eq 0 -and [string]::IsNullOrEmpty($result.Log)) "显式带端口的内部 Registry 被误判为 hostless。`n$($result.Output)"

    $fixture = New-TestFixture 'missing-digest'
    $lock = [System.IO.File]::ReadAllText($fixture.Lock) | ConvertFrom-Json
    $lock.images.setup.PSObject.Properties.Remove('digest')
    Write-Utf8 $fixture.Lock (($lock | ConvertTo-Json -Depth 5) + "`n")
    Assert-Failed (Invoke-Promotion $fixture @('-Check')) '缺少 digest' '缺少 digest 的镜像锁被接受。'

    $fixture = New-TestFixture 'missing-base-image'
    $lock = [System.IO.File]::ReadAllText($fixture.Lock) | ConvertFrom-Json
    $lock.images.PSObject.Properties.Remove('redis')
    Write-Utf8 $fixture.Lock (($lock | ConvertTo-Json -Depth 5) + "`n")
    Assert-Failed (Invoke-Promotion $fixture @('-Check')) 'ImageLockFile\.images 缺少 redis' '缺少 Redis 的不完整六镜像锁被接受。'

    $fixture = New-TestFixture 'latest-source'
    $lock = [System.IO.File]::ReadAllText($fixture.Lock) | ConvertFrom-Json
    $lock.images.setup.source = 'ghcr.io/example/xingchen-setup:latest'
    Write-Utf8 $fixture.Lock (($lock | ConvertTo-Json -Depth 5) + "`n")
    Assert-Failed (Invoke-Promotion $fixture @('-Check')) 'tag 或 digest|namespace/repository' 'latest 源镜像被接受。'

    $fixture = New-TestFixture 'leading-zero-version'
    Assert-Failed (Invoke-Promotion $fixture @('-Check') 'registry.internal.example/xingchen' 'https://releases.internal.example/xingchen' 'v01.20.14') '稳定语义版本' '带前导零的非规范版本被接受。'

    $fixture = New-TestFixture 'public-url'
    Assert-Failed (Invoke-Promotion $fixture @('-Check') 'registry.internal.example/xingchen' 'https://github.com/example/releases') 'GitHub/Docker 公共域名' '公共 GitHub 制品 URL 被接受。'

    $fixture = New-TestFixture 'gitee-url'
    Assert-Failed (Invoke-Promotion $fixture @('-Check') 'registry.internal.example/xingchen' 'https://artifacts.gitee.com/example/releases') 'GitHub/Docker 公共域名' 'Gitee 制品发布 URL 被接受。'

    $fixture = New-TestFixture 'inspect-failure'
    $env:PROMOTION_DOCKER_INSPECT_ERROR_COMPONENT = 'web'
    try {
        Assert-Failed (Invoke-Promotion $fixture) 'imagetools inspect 失败' '非 not-found 的 Registry 预检失败未终止晋级。'
    } finally {
        Remove-Item Env:PROMOTION_DOCKER_INSPECT_ERROR_COMPONENT -ErrorAction SilentlyContinue
    }

    $fixture = New-TestFixture 'target-conflict'
    $env:PROMOTION_DOCKER_CONFLICT_COMPONENT = 'server'
    try {
        Assert-Failed (Invoke-Promotion $fixture) '已存在且 digest 不同' '已有不同 digest 的版本 tag 被覆盖。'
    } finally {
        Remove-Item Env:PROMOTION_DOCKER_CONFLICT_COMPONENT -ErrorAction SilentlyContinue
    }

    Write-Host 'promote-internal-release.ps1 behavior tests passed.'
} finally {
    $env:PATH = $originalPath
    Remove-Item Env:PROMOTION_DOCKER_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:PROMOTION_DOCKER_STATE -ErrorAction SilentlyContinue
    Remove-Item Env:PROMOTION_TEST_PWSH -ErrorAction SilentlyContinue
    Remove-Item Env:PROMOTION_TEST_FAKE_DOCKER -ErrorAction SilentlyContinue
    Remove-Item Env:PROMOTION_DOCKER_INSPECT_ERROR_COMPONENT -ErrorAction SilentlyContinue
    Remove-Item Env:PROMOTION_DOCKER_CONFLICT_COMPONENT -ErrorAction SilentlyContinue
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedTestRoot) -like 'xingchen-internal-promotion-test-*' -and (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
