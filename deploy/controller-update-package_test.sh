#!/usr/bin/env bash
set -euo pipefail
umask 077

fail() { echo "$*" >&2; exit 1; }
if [[ -z "${BASE_SETUP_IMAGE:-}" ]]; then
  echo 'SKIP: set BASE_SETUP_IMAGE to an existing local Setup image ID or reference.'
  exit 0
fi
[[ $# -eq 0 ]] || fail 'Usage: BASE_SETUP_IMAGE=LOCAL_IMAGE bash deploy/controller-update-package_test.sh'
[[ "$(uname -s)" == Linux && -d /proc/self/fd ]] || fail 'This integration test requires native Linux with /proc mounted.'
for dependency in docker bash flock stat sha256sum mktemp; do
  command -v "${dependency}" >/dev/null 2>&1 || fail "Required command is unavailable: ${dependency}"
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd -- "${script_dir}/.." && pwd -P)"
base_image_id="$(docker image inspect --format '{{.Id}}' "${BASE_SETUP_IMAGE}")" || fail 'BASE_SETUP_IMAGE must already exist locally; this test never pulls images.'
[[ "${base_image_id}" =~ ^sha256:[a-f0-9]{64}$ ]] || fail 'The local base image ID is invalid.'
[[ "$(docker image inspect --format '{{.Os}}' "${base_image_id}")" == linux ]] || fail 'The local Setup image must be a Linux image.'

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/xingchen-controller-update-package-test.XXXXXXXXXX")"
temp_dir="$(cd -- "${temp_dir}" && pwd -P)"
run_id="${temp_dir##*.}-${BASHPID}"
owner_label=io.xingchen.controller-update-package-test
test_image="xingchen-controller-update-package-test:${run_id,,}"
extract_container="xingchen-update-package-extract-${run_id}"
runtime_container="xingchen-update-package-runtime-${run_id}"
cleanup() {
  local status=$? container image_id pass remaining
  local owned_images=()
  trap - EXIT
  for container in "${runtime_container}" "${extract_container}"; do
    if [[ "$(docker container inspect --format "{{index .Config.Labels \"${owner_label}\"}}" "${container}" 2>/dev/null || true)" == "${run_id}" ]]; then
      docker rm -f "${container}" >/dev/null 2>&1 || { echo "Cannot remove test container: ${container}" >&2; status=1; }
    fi
  done
  if [[ "$(docker image inspect --format "{{index .Config.Labels \"${owner_label}\"}}" "${test_image}" 2>/dev/null || true)" == "${run_id}" ]]; then
    docker image rm --no-prune "${test_image}" >/dev/null 2>&1 || true
  fi
  # Classic-builder intermediate images inherit this unique label; preserve the base image and unrelated cache.
  mapfile -t owned_images < <(docker image ls --all --quiet --no-trunc --filter "label=${owner_label}=${run_id}" 2>/dev/null)
  for ((pass = 0; pass < ${#owned_images[@]}; pass++)); do
    for image_id in "${owned_images[@]}"; do
      [[ "${image_id}" =~ ^sha256:[a-f0-9]{64}$ && "${image_id}" != "${base_image_id}" ]] || continue
      docker image rm --no-prune "${image_id}" >/dev/null 2>&1 || true
    done
  done
  remaining="$(docker image ls --all --quiet --filter "label=${owner_label}=${run_id}" 2>/dev/null)" || status=1
  if [[ -n "${remaining}" ]]; then
    echo "Cannot remove all test images with label ${owner_label}=${run_id}." >&2
    status=1
  fi
  docker image inspect "${base_image_id}" >/dev/null 2>&1 || { echo 'The base image is no longer available after cleanup.' >&2; status=1; }
  rm -rf -- "${temp_dir}" || status=1
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for container in "${extract_container}" "${runtime_container}"; do
  if docker container inspect "${container}" >/dev/null 2>&1; then fail 'A generated test container name is already in use.'; fi
done
if docker image inspect "${test_image}" >/dev/null 2>&1; then fail 'A generated test image tag is already in use.'; fi

context="${temp_dir}/context"
extracted_package="${temp_dir}/extracted"
mkdir -p "${context}/deploy" "${extracted_package}"
cp "${project_root}/docker-compose.yml" "${context}/docker-compose.yml"
for deploy_script in update-controller.sh update-controller.ps1 bootstrap-controller-update.sh xingchen.sh; do
  cp "${script_dir}/${deploy_script}" "${context}/deploy/${deploy_script}"
done
cat > "${context}/Dockerfile" <<'DOCKERFILE'
ARG BASE_SETUP_IMAGE
FROM ${BASE_SETUP_IMAGE}
ARG TEST_RUN_ID
LABEL io.xingchen.controller-update-package-test=${TEST_RUN_ID} org.opencontainers.image.version="v99.0.0"
USER root
COPY docker-compose.yml /usr/local/share/xingchen/controller-update/docker-compose.yml
COPY deploy/ /usr/local/share/xingchen/controller-update/deploy/
RUN set -eu; \
    cd /usr/local/share/xingchen/controller-update; \
    printf 'v99.0.0\n' > version; \
    sha256sum version docker-compose.yml deploy/update-controller.sh deploy/update-controller.ps1 deploy/bootstrap-controller-update.sh deploy/xingchen.sh > SHA256SUMS; \
    chmod 700 . deploy
DOCKERFILE

echo "Building an isolated package fixture from local image ${base_image_id}."
DOCKER_BUILDKIT=0 docker build --network none --pull=false --force-rm \
  --build-arg "BASE_SETUP_IMAGE=${base_image_id}" --build-arg "TEST_RUN_ID=${run_id}" \
  --tag "${test_image}" "${context}"
test_image_id="$(docker image inspect --format '{{.Id}}' "${test_image}")"
[[ "${test_image_id}" =~ ^sha256:[a-f0-9]{64}$ && "${test_image_id}" != "${base_image_id}" ]] || fail 'The derived test image ID is invalid.'
[[ "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${test_image_id}")" == v99.0.0 ]] || fail 'The derived test image has an incorrect version label.'

docker create --pull=never --network none --name "${extract_container}" \
  --label "${owner_label}=${run_id}" --entrypoint bash "${test_image_id}" -c true >/dev/null
docker cp "${extract_container}:/usr/local/share/xingchen/controller-update/." "${extracted_package}/"
chmod 700 "${extracted_package}" "${extracted_package}/deploy"
bash "${script_dir}/bootstrap-controller-update.sh" --verify-package "${extracted_package}" --version v99.0.0
[[ "$(wc -l < "${extracted_package}/SHA256SUMS")" -eq 6 ]] || fail 'The package must have exactly six checksum entries.'
for packaged_file in docker-compose.yml deploy/update-controller.sh deploy/update-controller.ps1 deploy/bootstrap-controller-update.sh deploy/xingchen.sh; do
  cmp -s "${context}/${packaged_file}" "${extracted_package}/${packaged_file}" || fail "Extracted file differs from the source fixture: ${packaged_file}"
done
[[ "$(docker container inspect --format '{{.State.Status}}' "${extract_container}")" == created ]] || fail 'The extraction container must never start.'
echo 'PASS: extracted package matches the source files and passes the bootstrap verifier.'

docker run --rm --pull=never --network none --name "${runtime_container}" \
  --label "${owner_label}=${run_id}" --entrypoint bash --user 0:0 "${test_image_id}" -c '
set -euo pipefail
package=/usr/local/share/xingchen/controller-update
timeout_args=()
if [[ "$(timeout --help 2>&1 || true)" == *--foreground* ]]; then timeout_args+=(--foreground); fi
timeout "${timeout_args[@]}" -s TERM -k 1 5 bash -c true
timeout_status=0
timeout "${timeout_args[@]}" -s TERM -k 1 1 sleep 5 || timeout_status=$?
case "${timeout_status}" in
  124|137|143) ;;
  *) echo "Unexpected timeout exit status: ${timeout_status}" >&2; exit 1 ;;
esac
cd "${package}"
sha256sum -c SHA256SUMS
bash deploy/bootstrap-controller-update.sh --verify-package "${package}" --version v99.0.0
echo "PASS: image runtime supports the timeout profile and validates the packaged files."
'

(
  lock_file="${temp_dir}/inheritance.lock"
  exec 9>>"${lock_file}"
  flock -n 9
  lock_parent_pid="${BASHPID}"
  lock_inode="$(stat -Lc '%d:%i' -- "/proc/${lock_parent_pid}/fd/9")"
  bash -c '
set -euo pipefail
[[ "$(stat -Lc "%d:%i" -- "/proc/$$/fd/9")" == "$1" ]]
[[ "$(stat -Lc "%d:%i" -- "$2")" == "$1" ]]
flock -n 9
independent_status=0
(
  exec 9>&-
  exec 8>>"$2"
  flock -n 8
) || independent_status=$?
[[ "${independent_status}" -eq 1 ]] || { echo "An independent lock acquisition did not report contention." >&2; exit 1; }
' bash "${lock_inode}" "${lock_file}"
)
echo 'PASS: inherited FD 9 holds the same inode and rejects an independent lock acquisition.'
echo 'Controller update package integration tests passed.'
