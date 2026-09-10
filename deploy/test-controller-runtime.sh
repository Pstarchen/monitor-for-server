#!/usr/bin/env bash
set -euo pipefail

# Exercise the new updater with the immutable v1.20.20 Setup userspace.
runtime_digest=sha256:cd293599ca4a6150786a4203a423d51366eff631e3d8dd2d348a914f91d88677
runtime_image="${XINGCHEN_RUNTIME_TEST_IMAGE:-ghcr.io/pstarchen/monitor-for-server-setup@${runtime_digest}}"
# Explicit immutable overrides also allow checking a deployed older Setup image
# by its local image ID. Mutable tags are never accepted as test dependencies.
if [[ ! "${runtime_image}" =~ ^sha256:[a-f0-9]{64}$ &&
      ! "${runtime_image}" =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]+)?/[a-z0-9]+([._/-][a-z0-9]+)*@sha256:[a-f0-9]{64}$ ]]; then
  echo 'Runtime test image must be a fully qualified digest reference or a local sha256 image ID.' >&2
  exit 2
fi
if [[ "${runtime_image}" != sha256:* ]]; then
  runtime_registry="${runtime_image%%/*}"
  [[ "${runtime_registry}" == *.* || "${runtime_registry}" == *:* || "${runtime_registry}" == localhost ]] \
    || { echo 'Runtime image references must include an explicit registry host.' >&2; exit 2; }
fi
[[ $# -eq 0 ]] || { echo 'Usage: [XINGCHEN_RUNTIME_TEST_IMAGE=PINNED_IMAGE] bash deploy/test-controller-runtime.sh' >&2; exit 2; }
[[ "$(uname -s)" == Linux ]] || { echo 'This runtime integration test requires a local Linux Docker daemon.' >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo 'Docker is required.' >&2; exit 2; }
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd -- "${script_dir}/.." && pwd -P)"
[[ "${project_root}" != *','* ]] || { echo 'Docker mount paths cannot contain commas.' >&2; exit 2; }

if ! docker image inspect "${runtime_image}" >/dev/null 2>&1; then
  [[ "${runtime_image}" != sha256:* ]] || { echo 'The requested local Setup image ID is unavailable.' >&2; exit 1; }
  docker pull "${runtime_image}"
fi
runtime_version="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${runtime_image}")"
[[ "${runtime_version}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || { echo 'The runtime image does not identify a stable Setup release.' >&2; exit 1; }
[[ "$(docker image inspect --format '{{.Os}}' "${runtime_image}")" == linux ]] \
  || { echo 'The pinned image is not a Linux image.' >&2; exit 1; }

run_id="${BASHPID}-${RANDOM}-${RANDOM}"
container_name="xingchen-controller-runtime-test-${run_id}"
owner_label=io.xingchen.controller-runtime-test
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$(docker container inspect --format "{{index .Config.Labels \"${owner_label}\"}}" "${container_name}" 2>/dev/null || true)" == "${run_id}" ]]; then
    docker rm -f "${container_name}" >/dev/null 2>&1 || status=1
  fi
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Testing the candidate updater in Setup %s (%s).\n' "${runtime_version}" "${runtime_image}"
docker run --rm --pull=never --name "${container_name}" --label "${owner_label}=${run_id}" \
  --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 128 --memory 256m --user 0:0 --workdir /tmp \
  --tmpfs /tmp:rw,exec,nosuid,nodev,size=128m \
  --mount "type=bind,src=${project_root},dst=/source,readonly" \
  --env XINGCHEN_RUNTIME_TEST_SANDBOX=1 --entrypoint bash "${runtime_image}" \
  /source/deploy/controller-update-runtime_test.sh
