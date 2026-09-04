#!/usr/bin/env bash
set -euo pipefail

repository="${1:-${GITHUB_REPOSITORY:-}}"
tag="${2:-${GITHUB_REF_NAME:-}}"

if [[ -z "${repository}" || "${repository}" != */* || "${repository#*/}" == */* ]]; then
  echo 'GitHub repository must use the owner/name form.' >&2
  exit 2
fi
if [[ -z "${tag}" ]]; then
  echo 'GitHub release tag must not be empty.' >&2
  exit 2
fi
if ! command -v gh >/dev/null 2>&1; then
  echo 'GitHub CLI is required to verify release mutability.' >&2
  exit 1
fi

owner="${repository%%/*}"
name="${repository#*/}"
query='query($owner: String!, $name: String!, $tag: String!) {
  repository(owner: $owner, name: $name) {
    nameWithOwner
    release(tagName: $tag) { isDraft }
  }
}'

if ! state="$(gh api graphql \
  -f "owner=${owner}" \
  -f "name=${name}" \
  -f "tag=${tag}" \
  -f "query=${query}" \
  --jq 'if .data.repository == null then "repository-unavailable" elif .data.repository.release == null then "missing" elif .data.repository.release.isDraft == true then "draft" elif .data.repository.release.isDraft == false then "published" else "invalid-response" end')"; then
  echo "Unable to verify GitHub Release state for ${repository}@${tag}; refusing to publish." >&2
  exit 1
fi

case "${state}" in
  missing|draft)
    printf '%s\n' "${state}"
    ;;
  published)
    echo "GitHub Release ${repository}@${tag} is already public; refusing to overwrite it." >&2
    exit 1
    ;;
  repository-unavailable)
    echo "GitHub repository ${repository} is unavailable to the current token; refusing to publish." >&2
    exit 1
    ;;
  *)
    echo "GitHub returned an unexpected Release state for ${repository}@${tag}; refusing to publish." >&2
    exit 1
    ;;
esac
