#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf -- "${temp_dir}"' EXIT
mkdir -p "${temp_dir}/bin"
command -v jq >/dev/null || { echo 'jq is required for mirror tests.' >&2; exit 1; }
export MIRROR_TEST_DIR="${temp_dir}"
export XINGCHEN_MIRROR_RETRY_DELAY_SECONDS=0
export PATH="${temp_dir}/bin:${PATH}"
source_image='ghcr.io/example/monitor-setup:v1.20.18'
target_image='ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-setup:v1.20.18'
printf '%s' '{"schemaVersion":2,"manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}}]}' > "${temp_dir}/source.json"
source_digest="sha256:$(sha256sum "${temp_dir}/source.json" | awk '{print $1}')"
export MIRROR_TEST_DIGEST="${source_digest}"

cat > "${temp_dir}/bin/skopeo" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MIRROR_TEST_DIR}/calls"
case "$1" in
  inspect)
    case "${*: -1}" in
      docker://ghcr.io/*)
        case "${MIRROR_TEST_SCENARIO}" in
          source-error) exit 1 ;;
          missing-platform) printf '%s' '{"schemaVersion":2,"manifests":[{"platform":{"os":"linux","architecture":"amd64"}}]}' ;;
          invalid-json) printf 'invalid' ;;
          *) cat "${MIRROR_TEST_DIR}/source.json" ;;
        esac ;;
      *)
        if [[ "${MIRROR_TEST_SCENARIO}" == existing ]]; then
          cat "${MIRROR_TEST_DIR}/source.json"
        elif [[ -f "${MIRROR_TEST_DIR}/copied" ]]; then
          [[ "${MIRROR_TEST_SCENARIO}" != target-error ]] || exit 1
          if [[ "${MIRROR_TEST_SCENARIO}" == target-mismatch ]]; then
            printf '%s' '{"schemaVersion":2,"manifests":[]}'
          else
            cat "${MIRROR_TEST_DIR}/source.json"
          fi
        else
          exit 1
        fi ;;
    esac ;;
  manifest-digest) printf 'sha256:%s\n' "$(sha256sum "$2" | awk '{print $1}')" ;;
  copy)
    [[ "$*" == *'--all --preserve-digests --retry-times 5'* ]] || exit 98
    [[ "${*: -2:1}" == "docker://ghcr.io/example/monitor-setup@${MIRROR_TEST_DIGEST}" ]] || exit 99
    case "${MIRROR_TEST_SCENARIO}" in
      copy-error) exit 1 ;;
      retry) if [[ ! -f "${MIRROR_TEST_DIR}/first-attempt" ]]; then touch "${MIRROR_TEST_DIR}/first-attempt"; exit 1; fi ;;
    esac
    touch "${MIRROR_TEST_DIR}/copied" ;;
  *) exit 97 ;;
esac
MOCK
chmod +x "${temp_dir}/bin/skopeo"

run_case() {
  local scenario="$1" expected_status="$2" expected_copies="$3"
  shift 3
  rm -f "${temp_dir}/calls" "${temp_dir}/copied" "${temp_dir}/first-attempt"
  local status=0
  MIRROR_TEST_SCENARIO="${scenario}" bash "${script_dir}/mirror-release-image.sh" "$@" > "${temp_dir}/output" 2> "${temp_dir}/error" || status=$?
  if [[ "${expected_status}" == pass ]]; then
    [[ "${status}" == 0 && "$(cat "${temp_dir}/output")" == "${source_digest}" ]] || { cat "${temp_dir}/error" >&2; echo "Failed case: ${scenario}" >&2; exit 1; }
  else
    [[ "${status}" != 0 ]] || { echo "Unexpected success: ${scenario}" >&2; exit 1; }
  fi
  local copies=0
  [[ ! -f "${temp_dir}/calls" ]] || copies="$(awk '/^copy / { count++ } END { print count+0 }' "${temp_dir}/calls")"
  [[ "${copies}" == "${expected_copies}" ]] || { echo "Unexpected copy count for ${scenario}: ${copies}" >&2; exit 1; }
}

run_case success pass 1 "${source_image}" "${target_image}"
run_case pinned pass 1 "${source_image}" "${target_image}" "${source_digest}"
grep '^inspect ' "${temp_dir}/calls" | grep -F "docker://ghcr.io/example/monitor-setup@${source_digest}" >/dev/null
if grep '^inspect ' "${temp_dir}/calls" | grep -F "docker://${source_image}" >/dev/null; then
  echo 'Build digest must be inspected without resolving its mutable tag.' >&2
  exit 1
fi
run_case existing pass 0 "${source_image}" "${target_image}" "${source_digest}"
run_case retry pass 2 "${source_image}" "${target_image}"
run_case copy-error fail 2 "${source_image}" "${target_image}"
run_case target-error fail 1 "${source_image}" "${target_image}"
run_case target-mismatch fail 1 "${source_image}" "${target_image}"
run_case source-error fail 0 "${source_image}" "${target_image}"
run_case invalid-json fail 0 "${source_image}" "${target_image}"
run_case missing-platform fail 0 "${source_image}" "${target_image}"
run_case digest-mismatch fail 0 "${source_image}" "${target_image}" "sha256:$(printf 'a%.0s' {1..64})"
run_case invalid-target fail 0 "${source_image}" "${target_image%:*}:latest"
run_case invalid-source fail 0 'https://example.com/private' "${target_image}"
run_case invalid-digest fail 0 "${source_image}" "${target_image}" 'sha256:invalid'
echo 'Release image mirroring tests passed (14 cases).'
