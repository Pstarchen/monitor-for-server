#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: package-offline-bundle.sh VERSION ASSETS_DIR IMAGES_TAR OUTPUT_DIR amd64|arm64" >&2
}

[[ $# -eq 5 ]] || { usage; exit 2; }
version="${1}"
assets_dir="$(cd -- "${2}" && pwd)"
images_tar="$(cd -- "$(dirname -- "${3}")" && pwd)/$(basename -- "${3}")"
output_dir="${4}"
image_arch="${5}"
[[ "${version}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo "VERSION 必须是稳定语义版本。" >&2; exit 2; }
[[ "${image_arch}" == amd64 || "${image_arch}" == arm64 ]] || { echo "镜像架构必须是 amd64 或 arm64。" >&2; exit 2; }
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "${script_dir}/.." && pwd)"
integrity_helper="${script_dir}/offline-bundle-integrity.sh"
[[ -f "${integrity_helper}" ]] || { echo "缺少离线 bundle 完整性校验器。" >&2; exit 1; }
# shellcheck source=offline-bundle-integrity.sh
source "${integrity_helper}"
[[ -f "${assets_dir}/manifest.json" ]] || { echo "缺少 manifest.json。" >&2; exit 1; }
[[ -f "${assets_dir}/checksums.txt" ]] || { echo "缺少 checksums.txt。" >&2; exit 1; }
[[ -s "${images_tar}" ]] || { echo "缺少 OCI 镜像 tar，拒绝生成不完整离线包。" >&2; exit 1; }

version_number="${version#v}"
agent_assets=(
  "xingchen-agent_${version_number}_linux_amd64.tar.gz"
  "xingchen-agent_${version_number}_linux_arm64.tar.gz"
  "xingchen-agent_${version_number}_windows_amd64.zip"
  "xingchen-agent_${version_number}_windows_arm64.zip"
)
for asset in "${agent_assets[@]}"; do
  [[ -s "${assets_dir}/${asset}" ]] || { echo "缺少 Agent 制品：${asset}" >&2; exit 1; }
done
offline_verify_agent_release "${assets_dir}/manifest.json" "${assets_dir}" "${assets_dir}/checksums.txt" "${version}"
offline_verify_controller_image_archive "${images_tar}" "${version}"
bundle_name="xingchen-monitor-offline-${version}-${image_arch}"
stage="${output_dir}/${bundle_name}"
archive="${output_dir}/${bundle_name}.tar.gz"
rm -rf -- "${stage}" "${archive}"
mkdir -p "${stage}/deploy" "${stage}/release/assets" "${stage}/images"

cp "${project_root}/docker-compose.yml" "${stage}/docker-compose.yml"
cp "${project_root}/deploy/install-controller.sh" "${project_root}/deploy/update-controller.sh" "${project_root}/deploy/install-agent.sh" "${stage}/deploy/"
cp "${project_root}/deploy/install-controller.ps1" "${project_root}/deploy/update-controller.ps1" "${project_root}/deploy/install-agent.ps1" "${stage}/deploy/"
cp "${integrity_helper}" "${stage}/deploy/offline-bundle-integrity.sh"
cp "${assets_dir}/manifest.json" "${stage}/release/manifest.json"
cp "${assets_dir}/checksums.txt" "${stage}/release/assets/checksums.txt"
for asset in "${agent_assets[@]}"; do
  cp "${assets_dir}/${asset}" "${stage}/release/assets/${asset}"
done
cp "${images_tar}" "${stage}/images/controller-images.tar"
printf 'schema=1\nversion=%s\narchitecture=%s\n' "${version}" "${image_arch}" > "${stage}/bundle-metadata.txt"

cat > "${stage}/import-images.sh" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
root="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)"
docker load --input "\${root}/images/controller-images.tar"
images=(
  "ghcr.io/pstarchen/monitor-for-server-setup:${version}"
  "ghcr.io/pstarchen/monitor-for-server-server:${version}"
  "ghcr.io/pstarchen/monitor-for-server-web:${version}"
  "ghcr.io/pstarchen/monitor-for-server-agent:${version}"
  "postgres:16-alpine"
  "redis:7.4-alpine"
)
for image in "\${images[@]}"; do
  docker image inspect "\${image}" >/dev/null 2>&1 || { echo "离线镜像导入后仍缺失：\${image}" >&2; exit 1; }
done
SCRIPT

printf '\357\273\277' > "${stage}/import-images.ps1"
cat >> "${stage}/import-images.ps1" <<'SCRIPT'
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
& docker load --input (Join-Path $root 'images/controller-images.tar')
if ($LASTEXITCODE -ne 0) { throw '离线总控镜像导入失败。' }
$images = @(
    'ghcr.io/pstarchen/monitor-for-server-setup:@VERSION@',
    'ghcr.io/pstarchen/monitor-for-server-server:@VERSION@',
    'ghcr.io/pstarchen/monitor-for-server-web:@VERSION@',
    'ghcr.io/pstarchen/monitor-for-server-agent:@VERSION@',
    'postgres:16-alpine',
    'redis:7.4-alpine'
)
foreach ($image in $images) {
    & docker image inspect $image *> $null
    if ($LASTEXITCODE -ne 0) { throw "离线镜像导入后仍缺失：$image" }
}
SCRIPT

cat > "${stage}/install-offline.sh" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
root="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)"
(
  cd "\${root}"
  sha256sum -c SHA256SUMS
)
"\${root}/import-images.sh"
export XINGCHEN_RELEASE_MANIFEST_SHA256="\$(sha256sum "\${root}/release/manifest.json" | awk '{print \$1}')"
export XINGCHEN_RELEASE_MANIFEST_PATH="/workspace/release/manifest.json"
export XINGCHEN_AGENT_OFFLINE_DIR="/workspace/release/assets"
export XINGCHEN_TARGET_VERSION="${version}"
export XINGCHEN_SETUP_IMAGE="ghcr.io/pstarchen/monitor-for-server-setup:${version}"
export XINGCHEN_SERVER_IMAGE="ghcr.io/pstarchen/monitor-for-server-server:${version}"
export XINGCHEN_WEB_IMAGE="ghcr.io/pstarchen/monitor-for-server-web:${version}"
export XINGCHEN_AGENT_IMAGE="ghcr.io/pstarchen/monitor-for-server-agent:${version}"
export XINGCHEN_POSTGRES_IMAGE="postgres:16-alpine"
export XINGCHEN_REDIS_IMAGE="redis:7.4-alpine"
export XINGCHEN_NETWORK_MODE="offline"
export XINGCHEN_ALLOW_GITEE="false"
exec bash "\${root}/deploy/install-controller.sh" --offline --no-source-fallback
SCRIPT

printf '\357\273\277' > "${stage}/install-offline.ps1"
cat >> "${stage}/install-offline.ps1" <<'SCRIPT'
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootPrefix = [System.IO.Path]::GetFullPath($root + [System.IO.Path]::DirectorySeparatorChar)
foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $root 'SHA256SUMS'))) {
    if ($line -notmatch '^([a-fA-F0-9]{64})  (.+)$') { throw "离线校验清单格式无效：$line" }
    $relative = $Matches[2]
    if ([System.IO.Path]::IsPathRooted($relative)) { throw "离线校验路径必须是相对路径：$relative" }
    $path = [System.IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $path.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "离线校验路径越界：$relative" }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "离线文件缺失：$relative" }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Matches[1].ToLowerInvariant()) { throw "离线文件校验失败：$relative" }
}
& (Join-Path $root 'import-images.ps1')
$manifestHostPath = Join-Path $root 'release/manifest.json'
$env:XINGCHEN_RELEASE_MANIFEST_SHA256 = (Get-FileHash -LiteralPath $manifestHostPath -Algorithm SHA256).Hash.ToLowerInvariant()
$env:XINGCHEN_RELEASE_MANIFEST_PATH = '/workspace/release/manifest.json'
$env:XINGCHEN_AGENT_OFFLINE_DIR = '/workspace/release/assets'
$env:XINGCHEN_TARGET_VERSION = '@VERSION@'
$env:XINGCHEN_SETUP_IMAGE = 'ghcr.io/pstarchen/monitor-for-server-setup:@VERSION@'
$env:XINGCHEN_SERVER_IMAGE = 'ghcr.io/pstarchen/monitor-for-server-server:@VERSION@'
$env:XINGCHEN_WEB_IMAGE = 'ghcr.io/pstarchen/monitor-for-server-web:@VERSION@'
$env:XINGCHEN_AGENT_IMAGE = 'ghcr.io/pstarchen/monitor-for-server-agent:@VERSION@'
$env:XINGCHEN_POSTGRES_IMAGE = 'postgres:16-alpine'
$env:XINGCHEN_REDIS_IMAGE = 'redis:7.4-alpine'
$env:XINGCHEN_NETWORK_MODE = 'offline'
$env:XINGCHEN_ALLOW_GITEE = 'false'
& (Join-Path $root 'deploy/install-controller.ps1') -Offline -NoSourceFallback
SCRIPT
sed -i "s/@VERSION@/${version}/g" "${stage}/import-images.ps1" "${stage}/install-offline.ps1"

cat > "${stage}/upgrade-offline.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: upgrade-offline.sh --project-root ABSOLUTE_PATH [--check|--apply]" >&2
}

project_root=""
mode=--check
mode_selected=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      [[ $# -ge 2 && -n "${2:-}" ]] || { usage; exit 2; }
      project_root="$2"
      shift 2
      ;;
    --check|--apply)
      if [[ "${mode_selected}" == true && "${mode}" != "$1" ]]; then
        echo "--check 与 --apply 不能同时使用。" >&2
        exit 2
      fi
      mode="$1"
      mode_selected=true
      shift
      ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "${project_root}" && "${project_root}" == /* && -d "${project_root}" ]] \
  || { echo "--project-root 必须是已存在的绝对目录。" >&2; exit 2; }
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "${root}/deploy/update-controller.sh" "${mode}" --offline --no-source-fallback \
  --project-root "${project_root}" --offline-bundle "${root}"
SCRIPT

printf '\357\273\277' > "${stage}/upgrade-offline.ps1"
cat >> "${stage}/upgrade-offline.ps1" <<'SCRIPT'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ProjectRoot,
    [switch] $Check,
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
if ($Check -and $Apply) { throw '-Check 与 -Apply 不能同时使用。' }
$isFullyQualified = [System.IO.Path]::IsPathRooted($ProjectRoot)
if ($isFullyQualified -and [System.IO.Path]::DirectorySeparatorChar -eq [char] 92) {
    $isFullyQualified = $ProjectRoot -match '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))'
}
if (-not $isFullyQualified -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw '-ProjectRoot 必须是已存在的绝对目录。'
}
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectPath = [System.IO.Path]::GetFullPath($ProjectRoot)
$bundlePath = [System.IO.Path]::GetFullPath($root)
if ($Apply) {
    & (Join-Path $root 'deploy/update-controller.ps1') -Apply -Offline -NoSourceFallback -ProjectRoot $projectPath -OfflineBundle $bundlePath
} else {
    & (Join-Path $root 'deploy/update-controller.ps1') -Check -Offline -NoSourceFallback -ProjectRoot $projectPath -OfflineBundle $bundlePath
}
SCRIPT

chmod 0755 "${stage}/import-images.sh" "${stage}/install-offline.sh" "${stage}/upgrade-offline.sh" "${stage}/deploy/"*.sh
(
  cd "${stage}"
  find deploy images release -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum --text > SHA256SUMS
  sha256sum --text bundle-metadata.txt docker-compose.yml import-images.sh import-images.ps1 install-offline.sh install-offline.ps1 upgrade-offline.sh upgrade-offline.ps1 >> SHA256SUMS
)
tar -C "${output_dir}" -czf "${archive}" "${bundle_name}"
(
  cd "$(dirname -- "${archive}")"
  archive_name="$(basename -- "${archive}")"
  archive_sha256="$(sha256sum --text "${archive_name}" | awk '{print $1}')"
  printf '%s  %s\n' "${archive_sha256}" "${archive_name}" > "${archive_name}.sha256"
)
echo "${archive}"
