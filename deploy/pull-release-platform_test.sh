#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf -- "${temp_dir}"' EXIT
mkdir -p "${temp_dir}/bin"
command -v jq >/dev/null || { echo 'jq is required for platform pull tests.' >&2; exit 1; }
export PLATFORM_TEST_DIR="${temp_dir}"
export PATH="${temp_dir}/bin:${PATH}"
source_repository='ghcr.io/example/monitor-setup'
index_digest="sha256:$(printf 'a%.0s' {1..64})"
amd64_digest="sha256:$(printf 'b%.0s' {1..64})"
arm64_digest="sha256:$(printf 'c%.0s' {1..64})"
source_reference="${source_repository}@${index_digest}"
target_tag="${source_repository}:v1.20.18"
export PLATFORM_TEST_AMD64_DIGEST="${amd64_digest}"
export PLATFORM_TEST_ARM64_DIGEST="${arm64_digest}"
jq -n --arg amd64 "${amd64_digest}" --arg arm64 "${arm64_digest}" '{
  schemaVersion: 2,
  manifests: [
    {digest: $amd64, platform: {os: "linux", architecture: "amd64"}},
    {digest: $arm64, platform: {os: "linux", architecture: "arm64"}},
    {digest: "sha256:attestation", platform: {os: "unknown", architecture: "unknown"}}
  ]
}' > "${temp_dir}/index.json"

cat > "${temp_dir}/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${PLATFORM_TEST_DIR}/calls"
case "$1" in
  buildx)
    [[ "${2:-}" == imagetools && "${3:-}" == inspect && "${4:-}" == --raw && "$#" -eq 5 ]] || exit 98
    case "${PLATFORM_TEST_SCENARIO}" in
      index-inspect-error) exit 1 ;;
      invalid-json) printf 'invalid' ;;
      missing-architecture) jq '.manifests |= map(select(.platform.architecture != "amd64"))' "${PLATFORM_TEST_DIR}/index.json" ;;
      wrong-os) jq '.manifests[0].platform.os = "windows"' "${PLATFORM_TEST_DIR}/index.json" ;;
      duplicate-architecture) jq '.manifests += [.manifests[0]]' "${PLATFORM_TEST_DIR}/index.json" ;;
      invalid-child-digest) jq '.manifests[0].digest = "sha256:invalid"' "${PLATFORM_TEST_DIR}/index.json" ;;
      missing-child-digest) jq 'del(.manifests[0].digest)' "${PLATFORM_TEST_DIR}/index.json" ;;
      invalid-schema) jq '.schemaVersion = 1' "${PLATFORM_TEST_DIR}/index.json" ;;
      missing-manifests) jq 'del(.manifests)' "${PLATFORM_TEST_DIR}/index.json" ;;
      *) cat "${PLATFORM_TEST_DIR}/index.json" ;;
    esac ;;
  pull)
    [[ "${2:-}" == --platform && "$#" -eq 4 ]] || exit 98
    [[ "${PLATFORM_TEST_SCENARIO}" != pull-error ]] || exit 1 ;;
  image)
    [[ "${2:-}" == inspect && "${3:-}" == --format && "${4:-}" == '{{.Os}}/{{.Architecture}}' && "$#" -eq 5 ]] || exit 98
    [[ "${PLATFORM_TEST_SCENARIO}" != local-inspect-error ]] || exit 1
    if [[ "${PLATFORM_TEST_SCENARIO}" == wrong-local-architecture ]]; then
      printf 'linux/arm64\n'
    elif [[ "${PLATFORM_TEST_SCENARIO}" == wrong-local-os ]]; then
      printf 'windows/amd64\n'
    elif [[ "${5:-}" == *"@${PLATFORM_TEST_AMD64_DIGEST}" ]]; then
      printf 'linux/amd64\n'
    elif [[ "${5:-}" == *"@${PLATFORM_TEST_ARM64_DIGEST}" ]]; then
      printf 'linux/arm64\n'
    else
      exit 99
    fi ;;
  tag)
    [[ "$#" -eq 3 ]] || exit 98
    [[ "${PLATFORM_TEST_SCENARIO}" != tag-error ]] || exit 1 ;;
  *) exit 97 ;;
esac
MOCK
chmod +x "${temp_dir}/bin/docker"

case_count=0
run_case() {
  local scenario="$1" expected_status="$2" expected_pulls="$3" expected_inspects="$4" expected_tags="$5"
  shift 5
  : > "${temp_dir}/calls"
  local status=0
  PLATFORM_TEST_SCENARIO="${scenario}" bash "${script_dir}/pull-release-platform.sh" "$@" > "${temp_dir}/output" 2> "${temp_dir}/error" || status=$?
  if [[ "${expected_status}" == pass ]]; then
    [[ "${status}" == 0 ]] || { cat "${temp_dir}/error" >&2; echo "Failed case: ${scenario}" >&2; exit 1; }
  else
    [[ "${status}" != 0 ]] || { echo "Unexpected success: ${scenario}" >&2; exit 1; }
  fi
  local pulls inspects tags
  pulls="$(awk '/^pull / { count++ } END { print count+0 }' "${temp_dir}/calls")"
  inspects="$(awk '/^image inspect / { count++ } END { print count+0 }' "${temp_dir}/calls")"
  tags="$(awk '/^tag / { count++ } END { print count+0 }' "${temp_dir}/calls")"
  [[ "${pulls}/${inspects}/${tags}" == "${expected_pulls}/${expected_inspects}/${expected_tags}" ]] || {
    echo "Unexpected pull/inspect/tag count for ${scenario}: ${pulls}/${inspects}/${tags}" >&2
    exit 1
  }
  if grep '^pull ' "${temp_dir}/calls" | grep -F "${source_reference}" >/dev/null; then
    echo "Pulled the multi-platform index instead of its child: ${scenario}" >&2
    exit 1
  fi
  case_count=$((case_count + 1))
}

for architecture in amd64 arm64; do
  if [[ "${architecture}" == amd64 ]]; then child_digest="${amd64_digest}"; else child_digest="${arm64_digest}"; fi
  run_case "success-${architecture}" pass 1 1 1 "${source_reference}" "${architecture}" "${target_tag}"
  printf '%s\n' \
    "buildx imagetools inspect --raw ${source_reference}" \
    "pull --platform linux/${architecture} ${source_repository}@${child_digest}" \
    "image inspect --format {{.Os}}/{{.Architecture}} ${source_repository}@${child_digest}" \
    "tag ${source_repository}@${child_digest} ${target_tag}" > "${temp_dir}/expected-calls"
  diff -u "${temp_dir}/expected-calls" "${temp_dir}/calls"
done

for dependency in postgres redis; do
  if [[ "${dependency}" == postgres ]]; then base_tag='16-alpine'; else base_tag='7.4-alpine'; fi
  base_repository="ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-${dependency}"
  run_case "short-${dependency}" pass 1 1 1 "${base_repository}@${index_digest}" arm64 "${dependency}:${base_tag}"
  printf '%s\n' \
    "buildx imagetools inspect --raw ${base_repository}@${index_digest}" \
    "pull --platform linux/arm64 ${base_repository}@${arm64_digest}" \
    "image inspect --format {{.Os}}/{{.Architecture}} ${base_repository}@${arm64_digest}" \
    "tag ${base_repository}@${arm64_digest} ${dependency}:${base_tag}" > "${temp_dir}/expected-calls"
  diff -u "${temp_dir}/expected-calls" "${temp_dir}/calls"
done

for scenario in index-inspect-error invalid-json missing-architecture wrong-os duplicate-architecture invalid-child-digest missing-child-digest invalid-schema missing-manifests; do
  run_case "${scenario}" fail 0 0 0 "${source_reference}" amd64 "${target_tag}"
done
run_case pull-error fail 1 0 0 "${source_reference}" amd64 "${target_tag}"
for scenario in local-inspect-error wrong-local-architecture wrong-local-os; do
  run_case "${scenario}" fail 1 1 0 "${source_reference}" amd64 "${target_tag}"
done
run_case tag-error fail 1 1 1 "${source_reference}" amd64 "${target_tag}"
run_case invalid-source-digest fail 0 0 0 "${source_repository}@sha256:invalid" amd64 "${target_tag}"
run_case mutable-source fail 0 0 0 "${source_repository}:v1.20.18" amd64 "${target_tag}"
run_case invalid-architecture fail 0 0 0 "${source_reference}" riscv64 "${target_tag}"
run_case invalid-target fail 0 0 0 "${source_reference}" amd64 "${source_reference}"
run_case missing-argument fail 0 0 0 "${source_reference}" amd64
run_case extra-argument fail 0 0 0 "${source_reference}" amd64 "${target_tag}" extra

echo "Release platform pull tests passed (${case_count} cases)."
