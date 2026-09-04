#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
guard="${script_dir}/check-github-release-mutable.sh"
shell_command="${BASH:-bash}"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT
fake_bin="${temp_dir}/bin"
mkdir -p "${fake_bin}"

cat > "${fake_bin}/gh" <<'MOCK'
#!/usr/bin/env sh
set -eu

if [ "${1:-}" != api ] || [ "${2:-}" != graphql ]; then
  echo 'Unexpected gh command.' >&2
  exit 97
fi
for expected in 'owner=example' 'name=monitor' 'tag=v1.20.15'; do
  found=false
  for argument in "$@"; do
    if [ "${argument}" = "${expected}" ]; then
      found=true
      break
    fi
  done
  if [ "${found}" != true ]; then
    echo "Missing GraphQL argument: ${expected}" >&2
    exit 98
  fi
done

case "${GH_MOCK_SCENARIO:-}" in
  missing) printf 'missing\n' ;;
  draft) printf 'draft\n' ;;
  published) printf 'published\n' ;;
  repository-unavailable) printf 'repository-unavailable\n' ;;
  unexpected) printf 'invalid-response\n' ;;
  api-error)
    echo 'mock API failure' >&2
    exit 1
    ;;
  *)
    echo 'Missing mock scenario.' >&2
    exit 99
    ;;
esac
MOCK
if command -v chmod >/dev/null 2>&1; then
  chmod 755 "${fake_bin}/gh"
fi

run_allowed_case() {
  local scenario="$1" expected="$2" output
  output="$(PATH="${fake_bin}:${PATH}" GH_MOCK_SCENARIO="${scenario}" "${shell_command}" "${guard}" example/monitor v1.20.15)"
  [[ "${output}" == "${expected}" ]] || {
    echo "Expected ${scenario} to return ${expected}, got ${output:-<empty>}." >&2
    exit 1
  }
}

run_rejected_case() {
  local scenario="$1" expected_message="$2" output
  if output="$(PATH="${fake_bin}:${PATH}" GH_MOCK_SCENARIO="${scenario}" "${shell_command}" "${guard}" example/monitor v1.20.15 2>&1)"; then
    echo "Expected ${scenario} to be rejected." >&2
    exit 1
  fi
  grep -F -- "${expected_message}" <<<"${output}" >/dev/null || {
    echo "Unexpected ${scenario} error: ${output}" >&2
    exit 1
  }
}

run_allowed_case missing missing
run_allowed_case draft draft
run_rejected_case published 'is already public'
run_rejected_case api-error 'refusing to publish'
run_rejected_case repository-unavailable 'is unavailable to the current token'
run_rejected_case unexpected 'unexpected Release state'

echo 'GitHub Release mutability guard tests passed.'
