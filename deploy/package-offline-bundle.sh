#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: package-offline-bundle.sh VERSION ASSETS_DIR IMAGES_TAR OUTPUT_DIR [amd64|arm64]" >&2
}

[[ $# -eq 4 || $# -eq 5 ]] || { usage; exit 2; }
version="${1}"
assets_dir="$(cd -- "${2}" && pwd)"
images_tar="$(cd -- "$(dirname -- "${3}")" && pwd)/$(basename -- "${3}")"
output_dir="${4}"
image_arch="${5:-}"
[[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION 必须是稳定语义版本。" >&2; exit 2; }
[[ -z "${image_arch}" || "${image_arch}" == amd64 || "${image_arch}" == arm64 ]] || { echo "镜像架构必须是 amd64 或 arm64。" >&2; exit 2; }
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
(
  cd "${assets_dir}"
  sha256sum -c checksums.txt
)

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "${script_dir}/.." && pwd)"
bundle_name="xingchen-monitor-offline-${version}${image_arch:+-${image_arch}}"
stage="${output_dir}/${bundle_name}"
archive="${output_dir}/${bundle_name}.tar.gz"
rm -rf -- "${stage}" "${archive}"
mkdir -p "${stage}/deploy" "${stage}/release/assets" "${stage}/images"

cp "${project_root}/docker-compose.yml" "${stage}/docker-compose.yml"
cp "${project_root}/deploy/install-controller.sh" "${project_root}/deploy/update-controller.sh" "${project_root}/deploy/install-agent.sh" "${stage}/deploy/"
cp "${project_root}/deploy/install-controller.ps1" "${project_root}/deploy/update-controller.ps1" "${project_root}/deploy/install-agent.ps1" "${stage}/deploy/"
cp "${assets_dir}/manifest.json" "${stage}/release/manifest.json"
cp "${assets_dir}/checksums.txt" "${stage}/release/assets/checksums.txt"
for asset in "${agent_assets[@]}"; do
  cp "${assets_dir}/${asset}" "${stage}/release/assets/${asset}"
done
cp "${images_tar}" "${stage}/images/controller-images.tar"

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

cat > "${stage}/import-images.ps1" <<'SCRIPT'
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
exec bash "\${root}/deploy/install-controller.sh" --offline --no-source-fallback
SCRIPT

cat > "${stage}/install-offline.ps1" <<'SCRIPT'
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
& (Join-Path $root 'deploy/install-controller.ps1') -Offline -NoSourceFallback
SCRIPT
sed -i "s/@VERSION@/${version}/g" "${stage}/import-images.ps1" "${stage}/install-offline.ps1"

chmod 0755 "${stage}/import-images.sh" "${stage}/install-offline.sh" "${stage}/deploy/"*.sh
(
  cd "${stage}"
  find deploy images release -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS
  sha256sum docker-compose.yml import-images.sh import-images.ps1 install-offline.sh install-offline.ps1 >> SHA256SUMS
)
tar -C "${output_dir}" -czf "${archive}" "${bundle_name}"
(
  cd "$(dirname -- "${archive}")"
  archive_name="$(basename -- "${archive}")"
  archive_sha256="$(sha256sum "${archive_name}" | awk '{print $1}')"
  printf '%s  %s\n' "${archive_sha256}" "${archive_name}" > "${archive_name}.sha256"
)
echo "${archive}"
