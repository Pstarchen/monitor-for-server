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

create_image_archive() {
  local output="$1" release_version="$2" omitted_component="${3:-}" extra_component="${4:-}" component image config layer separator=""
  local image_root="${temp_dir}/image-archive-$RANDOM"
  local archive_files=()
  local components=(setup server web agent postgres redis)
  [[ -z "${extra_component}" ]] || components+=("${extra_component}")
  mkdir -p "${image_root}"
  printf '[' > "${image_root}/manifest.json"
  for component in "${components[@]}"; do
    [[ "${component}" != "${omitted_component}" ]] || continue
    case "${component}" in
      setup|server|web|agent) image="ghcr.io/pstarchen/monitor-for-server-${component}:${release_version}" ;;
      postgres) image='postgres:16-alpine' ;;
      redis) image='redis:7.4-alpine' ;;
      *) image="registry.internal.example/xingchen/${component}:${release_version}" ;;
    esac
    config="${component}.json"
    layer="${component}/layer.tar"
    mkdir -p "${image_root}/${component}"
    printf '{"architecture":"amd64"}\n' > "${image_root}/${config}"
    printf 'layer for %s\n' "${component}" > "${image_root}/${layer}"
    printf '%s{"Config":"%s","RepoTags":["%s"],"Layers":["%s"]}' \
      "${separator}" "${config}" "${image}" "${layer}" >> "${image_root}/manifest.json"
    separator=,
    archive_files+=("${config}" "${layer}")
  done
  printf ']\n' >> "${image_root}/manifest.json"
  tar -C "${image_root}" -cf "${output}" manifest.json "${archive_files[@]}"
}

create_image_archive "${temp_dir}/images.tar" "${version}"

archive="$(bash "${packager}" "${version}" "${assets_dir}" "${temp_dir}/images.tar" "${output_dir}" amd64 | tail -n 1)"
[[ -s "${archive}" && -s "${archive}.sha256" ]]
grep -E "^[a-f0-9]{64}  $(basename "${archive}")$" "${archive}.sha256" >/dev/null
(
  trap 'status=$?; echo "package-offline-bundle_test.sh valid bundle check failed at line ${LINENO}." >&2; exit "${status}"' ERR
  cd "${output_dir}"
  sha256sum -c "$(basename "${archive}.sha256")"
  tar -xzf "$(basename "${archive}")"
  cd "xingchen-monitor-offline-${version}-amd64"
  sha256sum -c SHA256SUMS
  grep -Fx 'schema=1' bundle-metadata.txt >/dev/null
  grep -Fx 'version=v1.20.11' bundle-metadata.txt >/dev/null
  grep -Fx 'architecture=amd64' bundle-metadata.txt >/dev/null
  grep -E '^[a-f0-9]{64}  bundle-metadata\.txt$' SHA256SUMS >/dev/null
  grep -E '^[a-f0-9]{64}  upgrade-offline\.sh$' SHA256SUMS >/dev/null
  grep -E '^[a-f0-9]{64}  upgrade-offline\.ps1$' SHA256SUMS >/dev/null
  for ps_script in import-images.ps1 install-offline.ps1 upgrade-offline.ps1; do
    if [[ "$(od -An -tx1 -N3 "${ps_script}" | tr -d '[:space:]')" != efbbbf ]]; then
      echo "Generated PowerShell entry point is missing its UTF-8 BOM: ${ps_script}" >&2
      exit 1
    fi
  done
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
  grep -F 'XINGCHEN_NETWORK_MODE="offline"' install-offline.sh >/dev/null
  grep -F "\$env:XINGCHEN_NETWORK_MODE = 'offline'" install-offline.ps1 >/dev/null
  grep -F 'deploy/update-controller.sh' upgrade-offline.sh >/dev/null
  grep -F -- '--offline --no-source-fallback' upgrade-offline.sh >/dev/null
  grep -F 'deploy/update-controller.ps1' upgrade-offline.ps1 >/dev/null
  grep -F -- '-Offline -NoSourceFallback' upgrade-offline.ps1 >/dev/null
  if grep -F 'install-controller' upgrade-offline.sh upgrade-offline.ps1 >/dev/null; then
    echo 'Offline upgrade wrapper invokes a fresh installer.' >&2
    exit 1
  fi

  bundle_root="$(pwd)"
  existing_root="${temp_dir}/existing-controller"
  fake_bin="${temp_dir}/wrapper-bin"
  wrapper_log="${temp_dir}/wrapper.log"
  mkdir -p "${existing_root}" "${fake_bin}"
  cat > "${fake_bin}/bash" <<'SCRIPT'
#!/usr/bin/bash
printf '%s\n' "$@" > "${WRAPPER_LOG}"
SCRIPT
  chmod 755 "${fake_bin}/bash"

  normalize_wrapper_path() {
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*) cygpath -u "$1" ;;
      *) printf '%s\n' "$1" ;;
    esac
  }

  assert_wrapper_args() {
    local expected_mode="$1" index actual
    local expected_args=(
      "${bundle_root}/deploy/update-controller.sh"
      "${expected_mode}"
      --offline
      --no-source-fallback
      --project-root
      "${existing_root}"
      --offline-bundle
      "${bundle_root}"
    )
    local wrapper_args=()
    mapfile -t wrapper_args < "${wrapper_log}"
    [[ "${#wrapper_args[@]}" -eq "${#expected_args[@]}" ]] || return 1
    for index in "${!expected_args[@]}"; do
      actual="${wrapper_args[index]}"
      case "${index}" in
        0|5|7) actual="$(normalize_wrapper_path "${actual}")" ;;
      esac
      [[ "${actual}" == "${expected_args[index]}" ]] || return 1
    done
  }

  PATH="${fake_bin}:${PATH}" WRAPPER_LOG="${wrapper_log}" /usr/bin/bash "${bundle_root}/upgrade-offline.sh" --project-root "${existing_root}"
  assert_wrapper_args --check
  PATH="${fake_bin}:${PATH}" WRAPPER_LOG="${wrapper_log}" /usr/bin/bash "${bundle_root}/upgrade-offline.sh" --project-root "${existing_root}" --apply
  assert_wrapper_args --apply
  if PATH="${fake_bin}:${PATH}" WRAPPER_LOG="${wrapper_log}" /usr/bin/bash "${bundle_root}/upgrade-offline.sh" --apply >/dev/null 2>&1; then
    echo 'Bash upgrade wrapper accepted apply without --project-root.' >&2
    exit 1
  fi

  ps_commands=()
  command -v powershell.exe >/dev/null 2>&1 && ps_commands+=(powershell.exe)
  command -v pwsh >/dev/null 2>&1 && ps_commands+=(pwsh)
  if (( ${#ps_commands[@]} > 0 )); then
    ps_wrapper_root="${temp_dir}/ps-wrapper"
    mkdir -p "${ps_wrapper_root}/deploy"
    cp upgrade-offline.ps1 "${ps_wrapper_root}/upgrade-offline.ps1"
    cat > "${ps_wrapper_root}/deploy/update-controller.ps1" <<'SCRIPT'
param(
    [switch] $Check,
    [switch] $Apply,
    [switch] $Offline,
    [switch] $NoSourceFallback,
    [string] $ProjectRoot,
    [string] $OfflineBundle
)
"$Check|$Apply|$Offline|$NoSourceFallback|$ProjectRoot|$OfflineBundle" | Set-Content -LiteralPath $env:WRAPPER_LOG -NoNewline
SCRIPT
    ps_wrapper_path="${ps_wrapper_root}/upgrade-offline.ps1"
    ps_project_root="${existing_root}"
    ps_log_path="${wrapper_log}"
    if [[ "$(uname -s)" == MINGW* ]]; then
      ps_wrapper_path="$(cygpath -w "${ps_wrapper_path}")"
      ps_project_root="$(cygpath -w "${ps_project_root}")"
      ps_log_path="$(cygpath -w "${ps_log_path}")"
    fi
    for ps_command in "${ps_commands[@]}"; do
      WRAPPER_LOG="${ps_log_path}" "${ps_command}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${ps_wrapper_path}" -ProjectRoot "${ps_project_root}"
      grep -F 'True|False|True|True|' "${wrapper_log}" >/dev/null
      WRAPPER_LOG="${ps_log_path}" "${ps_command}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${ps_wrapper_path}" -ProjectRoot "${ps_project_root}" -Apply
      grep -F 'False|True|True|True|' "${wrapper_log}" >/dev/null
      if WRAPPER_LOG="${ps_log_path}" "${ps_command}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${ps_wrapper_path}" -ProjectRoot . >/dev/null 2>&1; then
        echo "PowerShell upgrade wrapper accepted a relative project root with ${ps_command}." >&2
        exit 1
      fi
    done
  fi
)

if bash "${packager}" "${version}" "${assets_dir}" "${temp_dir}/images.tar" "${output_dir}" >/dev/null 2>&1; then
  echo 'Offline packager accepted a bundle without an explicit architecture.' >&2
  exit 1
fi

leading_zero_output="$(bash "${packager}" v01.20.11 "${assets_dir}" "${temp_dir}/images.tar" "${output_dir}" amd64 2>&1 || true)"
if [[ "${leading_zero_output}" != *'VERSION 必须是稳定语义版本。'* ]]; then
  echo 'Offline packager did not reject a leading-zero version at version validation.' >&2
  exit 1
fi

create_image_archive "${temp_dir}/images-missing-redis.tar" "${version}" redis
if bash "${packager}" "${version}" "${assets_dir}" "${temp_dir}/images-missing-redis.tar" "${output_dir}" amd64 >/dev/null 2>&1; then
  echo 'Offline packager accepted an image archive without Redis.' >&2
  exit 1
fi

create_image_archive "${temp_dir}/images-with-extra.tar" "${version}" '' unexpected
if bash "${packager}" "${version}" "${assets_dir}" "${temp_dir}/images-with-extra.tar" "${output_dir}" amd64 >/dev/null 2>&1; then
  echo 'Offline packager accepted an image archive with an unexpected seventh image.' >&2
  exit 1
fi

bad_manifest_dir="${temp_dir}/bad-manifest-assets"
cp -R "${assets_dir}" "${bad_manifest_dir}"
awk 'BEGIN { changed = 0 } !changed && /"size": [0-9]+/ { sub(/"size": [0-9]+/, "\"size\": 999999"); changed = 1 } { print }' \
  "${assets_dir}/manifest.json" > "${bad_manifest_dir}/manifest.json"
if bash "${packager}" "${version}" "${bad_manifest_dir}" "${temp_dir}/images.tar" "${output_dir}" amd64 >/dev/null 2>&1; then
  echo 'Offline packager accepted an Agent manifest with an incorrect size.' >&2
  exit 1
fi

bad_checksums_dir="${temp_dir}/bad-checksums-assets"
cp -R "${assets_dir}" "${bad_checksums_dir}"
sed '$d' "${assets_dir}/checksums.txt" > "${bad_checksums_dir}/checksums.txt"
if bash "${packager}" "${version}" "${bad_checksums_dir}" "${temp_dir}/images.tar" "${output_dir}" amd64 >/dev/null 2>&1; then
  echo 'Offline packager accepted checksums.txt without all four Agent assets.' >&2
  exit 1
fi

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
