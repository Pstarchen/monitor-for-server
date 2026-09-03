#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "${script_dir}/.." && pwd)"
packager="${script_dir}/package-offline-bundle.sh"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT
assets_dir="${temp_dir}/assets"
output_dir="${temp_dir}/output"
mkdir -p "${assets_dir}" "${output_dir}"

version=v1.20.11
version_number="${version#v}"
assets=(
  "xingchen-agent_${version_number}_linux_amd64.tar.gz"
  "xingchen-agent_${version_number}_linux_arm64.tar.gz"
  "xingchen-agent_${version_number}_windows_amd64.zip"
  "xingchen-agent_${version_number}_windows_arm64.zip"
)
for asset in "${assets[@]}"; do
  printf 'test artifact %s\n' "${asset}" > "${assets_dir}/${asset}"
done
(
  cd "${assets_dir}"
  sha256sum "${assets[@]}" > checksums.txt
)
(
  cd "${project_root}/setup"
  go run ./cmd/release-manifest -version "${version}" -assets "${assets_dir}" -output "${assets_dir}/manifest.json" -minimum-controller v1.20.0 -published-at 2026-09-04T00:00:00Z
)
printf 'test image archive\n' > "${temp_dir}/images.tar"

archive="$(bash "${packager}" "${version}" "${assets_dir}" "${temp_dir}/images.tar" "${output_dir}" amd64 | tail -n 1)"
[[ -s "${archive}" && -s "${archive}.sha256" ]]
grep -E "^[a-f0-9]{64}  $(basename "${archive}")$" "${archive}.sha256" >/dev/null
(
  cd "${output_dir}"
  sha256sum -c "$(basename "${archive}.sha256")"
  tar -xzf "$(basename "${archive}")"
  cd "xingchen-monitor-offline-${version}-amd64"
  sha256sum -c SHA256SUMS
  grep -F 'XINGCHEN_TARGET_VERSION="v1.20.11"' install-offline.sh >/dev/null
  grep -F "\$env:XINGCHEN_TARGET_VERSION = 'v1.20.11'" install-offline.ps1 >/dev/null
  grep -F 'docker image inspect "${image}"' import-images.sh >/dev/null
  grep -F '"postgres:16-alpine"' import-images.sh >/dev/null
  grep -F '"redis:7.4-alpine"' import-images.sh >/dev/null
  grep -F "'postgres:16-alpine'" import-images.ps1 >/dev/null
  grep -F "'redis:7.4-alpine'" import-images.ps1 >/dev/null
  grep -F 'XINGCHEN_POSTGRES_IMAGE="postgres:16-alpine"' install-offline.sh >/dev/null
  grep -F "\$env:XINGCHEN_REDIS_IMAGE = 'redis:7.4-alpine'" install-offline.ps1 >/dev/null
  grep -F 'XINGCHEN_RELEASE_MANIFEST_PATH="/workspace/release/manifest.json"' install-offline.sh >/dev/null
  grep -F "\$env:XINGCHEN_AGENT_OFFLINE_DIR = '/workspace/release/assets'" install-offline.ps1 >/dev/null
)

mv "${assets_dir}/${assets[3]}" "${assets_dir}/${assets[3]}.missing"
if bash "${packager}" "${version}" "${assets_dir}" "${temp_dir}/images.tar" "${output_dir}" arm64 >/dev/null 2>&1; then
  echo 'Offline packager accepted a missing Windows arm64 Agent asset.' >&2
  exit 1
fi
mv "${assets_dir}/${assets[3]}.missing" "${assets_dir}/${assets[3]}"
printf 'tampered\n' >> "${assets_dir}/${assets[0]}"
if bash "${packager}" "${version}" "${assets_dir}" "${temp_dir}/images.tar" "${output_dir}" amd64 >/dev/null 2>&1; then
  echo 'Offline packager accepted a checksum mismatch.' >&2
  exit 1
fi

echo 'offline bundle packaging tests passed.'
