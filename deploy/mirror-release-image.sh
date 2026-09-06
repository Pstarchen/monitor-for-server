#!/usr/bin/env bash
set -euo pipefail

source_image="${1:-}"
target_image="${2:-}"
expected_digest="${3:-}"
copy_timeout="${XINGCHEN_MIRROR_TIMEOUT_SECONDS:-9000}"
retry_delay="${XINGCHEN_MIRROR_RETRY_DELAY_SECONDS:-15}"

fail() { echo "$*" >&2; exit 1; }
[[ "$#" -ge 2 && "$#" -le 3 ]] || fail 'Usage: mirror-release-image.sh SOURCE TARGET [SOURCE_DIGEST]'
repository_pattern='[a-z0-9][a-z0-9.-]*(:[0-9]+)?/[a-z0-9]+([._/-][a-z0-9]+)*'
digest_pattern='sha256:[a-f0-9]{64}'
[[ "${source_image}" =~ ^${repository_pattern}(:[A-Za-z0-9_][A-Za-z0-9_.-]*|@${digest_pattern})$ ]] || fail 'Invalid source image reference.'
[[ "${target_image}" =~ ^${repository_pattern}:(v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)|sha-[a-f0-9]{7,40})$ ]] || fail 'Target must use a stable version or commit tag.'
[[ -z "${expected_digest}" || "${expected_digest}" =~ ^${digest_pattern}$ ]] || fail 'Invalid expected source digest.'
[[ "${copy_timeout}" =~ ^[1-9][0-9]*$ && "${retry_delay}" =~ ^[0-9]+$ ]] || fail 'Invalid mirror timeout or retry delay.'
for dependency in skopeo jq timeout; do
  command -v "${dependency}" >/dev/null 2>&1 || fail "Required command is unavailable: ${dependency}"
done

auth_args=()
auth_file="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"
[[ ! -f "${auth_file}" ]] || auth_args=(--authfile "${auth_file}")
temp_dir="$(mktemp -d)"
trap 'rm -rf -- "${temp_dir}"' EXIT

read_manifest() {
  timeout --signal=TERM --kill-after=10s 120s \
    skopeo inspect "${auth_args[@]}" --raw "docker://$1" > "$2" 2> "${temp_dir}/inspect-error"
}

verify_platforms() {
  jq -e '
    .schemaVersion == 2 and
    ([.manifests[]?.platform
      | select(.os == "linux" and (.architecture == "amd64" or .architecture == "arm64"))
      | .architecture] | sort == ["amd64", "arm64"])
  ' "$1" >/dev/null 2>&1
}

source_repository="${source_image%@*}"
[[ "${source_repository##*/}" != *:* ]] || source_repository="${source_repository%:*}"
# Build output digests are authoritative even if another job moves the source tag.
source_reference="${source_image}"
[[ -z "${expected_digest}" ]] || source_reference="${source_repository}@${expected_digest}"
read_manifest "${source_reference}" "${temp_dir}/source.json" || fail 'Cannot read source image manifest.'
source_digest="$(skopeo manifest-digest "${temp_dir}/source.json")"
[[ "${source_digest}" =~ ^${digest_pattern}$ ]] || fail 'Source registry returned an invalid digest.'
[[ -z "${expected_digest}" || "${source_digest}" == "${expected_digest}" ]] || fail 'Source digest does not match the build output.'
if [[ "${source_image}" == *@* ]]; then
  [[ "${source_digest}" == "${source_image##*@}" ]] || fail 'Source digest does not match the requested image.'
fi
verify_platforms "${temp_dir}/source.json" || fail 'Source must contain exactly one linux/amd64 and one linux/arm64 manifest.'
locked_source="${source_repository}@${source_digest}"

# A completed copy needs no retransmission when a draft workflow is retried.
if read_manifest "${target_image}" "${temp_dir}/target.json"; then
  if [[ "$(skopeo manifest-digest "${temp_dir}/target.json")" == "${source_digest}" ]]; then
    verify_platforms "${temp_dir}/target.json" || fail 'Target image is missing a required platform.'
    printf '%s\n' "${source_digest}"
    exit 0
  fi
fi

for attempt in 1 2; do
  echo "Copying ${locked_source} to ${target_image} (attempt ${attempt}/2)." >&2
  if timeout --signal=TERM --kill-after=30s "${copy_timeout}s" \
    skopeo copy --all --preserve-digests --retry-times 5 "${auth_args[@]}" \
      "docker://${locked_source}" "docker://${target_image}" >&2; then
    read_manifest "${target_image}" "${temp_dir}/target.json" || fail 'Cannot verify copied target image.'
    [[ "$(skopeo manifest-digest "${temp_dir}/target.json")" == "${source_digest}" ]] || fail 'Target digest differs from the source after copying.'
    verify_platforms "${temp_dir}/target.json" || fail 'Target image is missing a required platform.'
    printf '%s\n' "${source_digest}"
    exit 0
  fi
  [[ "${attempt}" -eq 2 ]] || sleep "${retry_delay}"
done
fail 'Image mirror failed after 2 attempts.'
