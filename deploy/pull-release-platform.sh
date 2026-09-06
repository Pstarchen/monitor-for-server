#!/usr/bin/env bash
set -euo pipefail

source_reference="${1:-}"
architecture="${2:-}"
target_tag="${3:-}"

fail() { echo "$*" >&2; exit 1; }
[[ "$#" -eq 3 ]] || fail 'Usage: pull-release-platform.sh SOURCE_INDEX_REFERENCE ARCH TARGET_TAG'
repository_pattern='[a-z0-9][a-z0-9.-]*(:[0-9]+)?/[a-z0-9]+([._/-][a-z0-9]+)*'
short_repository_pattern='[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*'
digest_pattern='sha256:[a-f0-9]{64}'
[[ "${source_reference}" =~ ^${repository_pattern}@${digest_pattern}$ ]] || fail 'Source must be a repository pinned to a valid sha256 digest.'
[[ "${architecture}" == amd64 || "${architecture}" == arm64 ]] || fail 'Architecture must be amd64 or arm64.'
[[ "${target_tag}" =~ ^(${repository_pattern}|${short_repository_pattern}):[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || fail 'Target must be a valid image tag.'
for dependency in docker jq; do
  command -v "${dependency}" >/dev/null 2>&1 || fail "Required command is unavailable: ${dependency}"
done

index_manifest="$(docker buildx imagetools inspect --raw "${source_reference}")" || fail 'Cannot inspect the source image index.'
child_digest="$(jq -er --arg architecture "${architecture}" '
  if .schemaVersion == 2 and (.manifests | type) == "array" then
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $architecture)]
    | if length == 1 then .[0].digest else error("Expected exactly one matching platform manifest") end
    | if type == "string" and test("^sha256:[a-f0-9]{64}$") then . else error("Invalid platform digest") end
  else error("Expected a version 2 image index") end
' <<< "${index_manifest}")" || fail "Source must contain exactly one valid linux/${architecture} manifest."
[[ "${child_digest}" =~ ^${digest_pattern}$ ]] || fail 'Source index returned an invalid platform digest.'
child_reference="${source_reference%@*}@${child_digest}"
platform="linux/${architecture}"

# Pin the child manifest so classic Docker stores cannot reuse another platform under the index digest.
docker pull --platform "${platform}" "${child_reference}" || fail 'Cannot pull the requested platform image.'
local_platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${child_reference}")" || fail 'Cannot inspect the pulled platform image.'
[[ "${local_platform}" == "${platform}" ]] || fail "Pulled image platform does not match ${platform}."
docker tag "${child_reference}" "${target_tag}" || fail 'Cannot tag the verified platform image.'
