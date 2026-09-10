#!/usr/bin/env bash
set -euo pipefail

fail() { echo "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Usage: bootstrap-controller-update.sh --project-root ABS_PATH --version vX.Y.Z [--check|--apply]
       bootstrap-controller-update.sh --version vX.Y.Z [--check|--apply]  (update Runner)
       bootstrap-controller-update.sh --verify-package ABS_PATH --version vX.Y.Z
USAGE
}

project_root=""
package_to_verify=""
target_version=""
mode=apply
mode_set=false
while (($# > 0)); do
  case "$1" in
    --project-root|--verify-package|--version)
      [[ $# -ge 2 && -n "${2:-}" ]] || fail 'An option value is missing.'
      case "$1" in
        --project-root) [[ -z "${project_root}" ]] || fail 'Duplicate project root.'; project_root="$2" ;;
        --verify-package) [[ -z "${package_to_verify}" ]] || fail 'Duplicate package path.'; package_to_verify="$2" ;;
        --version) [[ -z "${target_version}" ]] || fail 'Duplicate version.'; target_version="$2" ;;
      esac
      shift 2 ;;
    --check|--apply)
      [[ "${mode_set}" == false ]] || fail 'Specify only one update mode.'
      mode="${1#--}"; mode_set=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail 'Unknown bootstrap option.' ;;
  esac
done
[[ "${target_version}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'A stable --version vX.Y.Z is required.'

absolute_directory() {
  [[ "$1" == /* && "$1" != / && "$1" != *$'\n'* && "$1" != *$'\r'* && "/${1#/}/" != */../* && "/${1#/}/" != */./* && -d "$1" ]]
}

verify_package() {
  local package="$1" entry relative metadata line digest name actual count=0
  local expected=(version docker-compose.yml deploy/update-controller.sh deploy/update-controller.ps1 deploy/bootstrap-controller-update.sh deploy/xingchen.sh)
  local -A seen=()
  while [[ "${package}" == */ ]]; do package="${package%/}"; done
  absolute_directory "${package}" && [[ ! -L "${package}" ]] || fail 'Update package must be a real absolute directory.'
  for entry in "${package}" "${package}/deploy"; do
    [[ -d "${entry}" && ! -L "${entry}" ]] || fail 'Update package contains an invalid directory.'
    metadata="$(stat -c '%a %u' -- "${entry}")" || fail 'Cannot inspect update package permissions.'
    [[ "${metadata}" == "700 ${EUID}" ]] || fail 'Update package directories must be owned by the current user with mode 700.'
  done
  shopt -s nullglob dotglob
  local entries=("${package}"/* "${package}/deploy"/*)
  shopt -u nullglob dotglob
  [[ ${#entries[@]} -eq 8 ]] || fail 'Update package must contain exactly seven files and the deploy directory.'
  for entry in "${entries[@]}"; do
    relative="${entry#"${package}/"}"
    [[ "${relative}" != deploy ]] || continue
    case "${relative}" in
      version|SHA256SUMS|docker-compose.yml|deploy/update-controller.sh|deploy/update-controller.ps1|deploy/bootstrap-controller-update.sh|deploy/xingchen.sh) ;;
      *) fail 'Update package contains an unexpected path.' ;;
    esac
    [[ -f "${entry}" && ! -L "${entry}" ]] || fail 'Update package files must be regular files, not symlinks.'
    metadata="$(stat -c '%u %h' -- "${entry}")" || fail 'Cannot inspect an update package file.'
    [[ "${metadata}" == "${EUID} 1" ]] || fail 'Update package files must belong to the current user and must not be hard links.'
  done
  [[ "$(<"${package}/version")" == "${target_version}" && "$(wc -c < "${package}/version")" -eq $((${#target_version} + 1)) ]] || fail 'Update package version does not match the requested version.'
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^([a-f0-9]{64})\ \ (.+)$ ]] || fail 'Invalid update package checksum entry.'
    digest="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    case "${name}" in
      version|docker-compose.yml|deploy/update-controller.sh|deploy/update-controller.ps1|deploy/bootstrap-controller-update.sh|deploy/xingchen.sh) ;;
      *) fail 'Update package checksum names an unexpected path.' ;;
    esac
    [[ -z "${seen[${name}]:-}" ]] || fail 'Update package checksum entries must not repeat.'
    seen["${name}"]=true
    actual="$(sha256sum -- "${package}/${name}")" || fail 'Cannot calculate an update package checksum.'
    [[ "${actual%% *}" == "${digest}" ]] || fail "Update package checksum mismatch: ${name}"
    count=$((count + 1))
  done < "${package}/SHA256SUMS"
  [[ "${count}" -eq 6 ]] || fail 'Update package checksums must cover exactly six managed files.'
  for name in "${expected[@]}"; do
    [[ "${seen[${name}]:-}" == true ]] || fail 'Update package is missing a managed checksum.'
  done
}

if [[ -n "${package_to_verify}" ]]; then
  [[ -z "${project_root}" && "${mode_set}" == false ]] || fail '--verify-package cannot be combined with an update mode or project root.'
  verify_package "${package_to_verify}"
  exit 0
fi

runner="${CONTROLLER_UPDATE_RUNNER:-false}"
if [[ "${runner}" == true ]]; then
  [[ -z "${project_root}" ]] || fail 'The update Runner uses SETUP_WORKSPACE and does not accept --project-root.'
  project_root="${SETUP_WORKSPACE:-}"
fi
absolute_directory "${project_root}" || fail 'An existing absolute project root is required.'
project_root="$(cd -- "${project_root}" && pwd -P)"
[[ "${project_root}" != / && -f "${project_root}/.env" && -f "${project_root}/docker-compose.yml" ]] || fail 'Project root must contain an existing .env and docker-compose.yml.'
for dependency in docker timeout flock stat sha256sum df awk; do
  command -v "${dependency}" >/dev/null 2>&1 || fail "Required command is unavailable: ${dependency}"
done
lock_file="${project_root}/.controller-update.lock"
[[ ! -L "${lock_file}" && ( ! -e "${lock_file}" || -f "${lock_file}" ) ]] || fail 'Controller update lock must be a regular file.'
exec 9>>"${lock_file}"
flock -n 9 || { echo 'Another Controller update is already running.' >&2; exit 75; }

read_setting() {
  local key="$1" fallback="$2" line candidate raw first last suffix value="" found=false
  if [[ -n "${!key:-}" ]]; then printf '%s' "${!key}"; return; fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    candidate="${line%$'\r'}"
    while [[ "${candidate}" == ' '* || "${candidate}" == $'\t'* ]]; do candidate="${candidate:1}"; done
    [[ -z "${candidate}" || "${candidate}" == \#* ]] && continue
    if [[ "${candidate}" == "${key}="* ]]; then
      [[ "${found}" == false ]] || fail "Duplicate deployment setting: ${key}"
      found=true
      raw="${candidate#"${key}="}"
      first="${raw:0:1}"; last="${raw: -1}"
      if [[ "${first}" == '"' || "${first}" == "'" || "${last}" == '"' || "${last}" == "'" ]]; then
        [[ ${#raw} -ge 2 && "${first}" == "${last}" && ( "${first}" == '"' || "${first}" == "'" ) ]] || fail "Invalid deployment setting: ${key}"
        raw="${raw:1:${#raw}-2}"
      fi
      [[ "${raw}" != *'"'* && "${raw}" != *"'"* ]] || fail "Invalid deployment setting: ${key}"
      value="${raw}"
    elif [[ "${candidate}" == "${key}"* ]]; then
      suffix="${candidate#"${key}"}"
      [[ -n "${suffix}" && "${suffix:0:1}" =~ [A-Za-z0-9_] ]] || fail "Invalid deployment setting: ${key}"
    elif [[ "${candidate}" == export[[:space:]]"${key}"* ]]; then
      fail "Invalid deployment setting: ${key}"
    fi
  done < "${project_root}/.env"
  if [[ "${found}" == true ]]; then printf '%s' "${value}"; else printf '%s' "${fallback}"; fi
}

network_mode="$(read_setting XINGCHEN_NETWORK_MODE public)"
allow_gitee="$(read_setting XINGCHEN_ALLOW_GITEE false)"
setup_image="$(read_setting XINGCHEN_SETUP_IMAGE '')"
pull_timeout="$(read_setting XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS 180)"
minimum_free_bytes="$(read_setting XINGCHEN_UPDATE_MIN_FREE_BYTES 1073741824)"
network_mode="${network_mode,,}"; allow_gitee="${allow_gitee,,}"
[[ "${network_mode}" == public || "${network_mode}" == internal || "${network_mode}" == offline ]] || fail 'Invalid Controller network mode.'
[[ "${allow_gitee}" == true || "${allow_gitee}" == false ]] || fail 'Invalid XINGCHEN_ALLOW_GITEE setting.'
[[ "${network_mode}" != offline ]] || fail 'Online bootstrap is unavailable in offline network mode; use an offline update bundle.'
[[ "${pull_timeout}" =~ ^[1-9][0-9]*$ ]] || fail 'Update pull timeout must be a positive number of seconds.'
[[ "${minimum_free_bytes}" =~ ^[1-9][0-9]*$ ]] || fail 'XINGCHEN_UPDATE_MIN_FREE_BYTES must be a positive number of bytes.'
if [[ -z "${setup_image}" ]]; then
  [[ "${network_mode}" != internal ]] || fail 'Internal network mode requires a configured internal Setup image.'
  setup_image="ghcr.io/pstarchen/monitor-for-server-setup:${target_version}"
fi
repository_pattern='[a-z0-9][a-z0-9.-]*(:[0-9]+)?/[a-z0-9]+([._/-][a-z0-9]+)*'
digest_pattern='sha256:[a-f0-9]{64}'
[[ "${setup_image}" =~ ^${repository_pattern}(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?(@${digest_pattern})?$ ]] || fail 'Setup image must use a valid fully qualified registry reference.'
registry_host="${setup_image%%/*}"
registry_host="${registry_host%%:*}"
registry_host="${registry_host%.}"
host_matches() { [[ "$1" == "$2" || "$1" == *."$2" ]]; }
if host_matches "${registry_host}" gitee.com && [[ "${allow_gitee}" != true ]]; then
  fail 'Gitee Registry requires XINGCHEN_ALLOW_GITEE=true.'
fi
if [[ "${network_mode}" == internal ]]; then
  [[ "${registry_host}" == *.* || "${registry_host}" == localhost || "${setup_image%%/*}" == *:* ]] || fail 'Internal Setup image requires an explicit registry host.'
  for forbidden_host in github.com githubusercontent.com githubassets.com ghcr.io docker.io docker.com ghcr.1ms.run ghcr.nju.edu.cn ghcr.m.daocloud.io; do
    host_matches "${registry_host}" "${forbidden_host}" && fail 'Internal network mode rejects the configured public Setup registry.'
  done
fi
if [[ "${setup_image}" != *@* ]]; then
  if [[ "${setup_image##*/}" == *:* ]]; then setup_image="${setup_image%:*}"; fi
  setup_image="${setup_image}:${target_version}"
fi

check_free_space() {
  local path="$1" available_kb
  available_kb="$(df -Pk "${path}" 2>/dev/null | awk 'NR == 2 { print $4; exit }')" || fail 'Cannot inspect free space for Controller update.'
  [[ "${available_kb}" =~ ^[0-9]+$ ]] || fail 'Cannot determine free space for Controller update.'
  awk -v available="${available_kb}" -v required="${minimum_free_bytes}" 'BEGIN { exit (available * 1024 >= required ? 0 : 1) }' \
    || fail "Insufficient free space at ${path}; at least ${minimum_free_bytes} bytes are required."
}
check_free_space "${project_root}"
docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
if [[ -n "${docker_root}" && -d "${docker_root}" && -r "${docker_root}" && "${docker_root}" != "${project_root}" ]]; then
  check_free_space "${docker_root}"
fi
daemon_platform="$(docker info --format '{{.OSType}}/{{.Architecture}}' 2>/dev/null)" || fail 'Cannot read Docker daemon platform.'
case "${daemon_platform}" in
  linux/amd64|linux/x86_64) daemon_platform=linux/amd64 ;;
  linux/arm64|linux/aarch64) daemon_platform=linux/arm64 ;;
  *) fail 'Controller bootstrap requires a Linux amd64 or arm64 Docker daemon.' ;;
esac
timeout_args=()
if [[ "$(timeout --help 2>&1 || true)" == *--foreground* ]]; then timeout_args+=(--foreground); fi
timeout ${timeout_args[@]+"${timeout_args[@]}"} -s TERM -k 10 "${pull_timeout}" docker pull "${setup_image}" >/dev/null 2>&1 || fail 'Cannot pull the target Setup image within the configured timeout.'
image_metadata="$(docker image inspect --format '{{.Id}}|{{index .Config.Labels "org.opencontainers.image.version"}}|{{.Os}}/{{.Architecture}}' "${setup_image}" 2>/dev/null)" || fail 'Cannot inspect the target Setup image.'
IFS='|' read -r image_id image_version image_platform extra_metadata <<< "${image_metadata}"
[[ "${image_metadata}" != *$'\n'* && "${image_id}" =~ ^${digest_pattern}$ && -z "${extra_metadata}" ]] || fail 'Setup image metadata is invalid.'
[[ "${image_version}" == "${target_version}" ]] || fail 'Setup image version label does not match the requested version.'
[[ "${image_platform}" == "${daemon_platform}" ]] || fail 'Setup image platform does not match the Docker daemon.'

stage=""
container_id=""
container_name=""
updater_running=false
signal_exit() {
  local child_status=$?
  # Bash defers this trap while the foreground updater completes its rollback.
  if [[ "${updater_running}" == true && ( "${child_status}" == 10 || "${child_status}" == 11 ) ]]; then
    exit "${child_status}"
  fi
  exit "$1"
}
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "${container_name}" =~ ^xingchen-update-extract-[a-zA-Z0-9]{6}-[0-9]+$ ]]; then
    timeout ${timeout_args[@]+"${timeout_args[@]}"} -s TERM -k 5 30 docker rm -f "${container_name}" >/dev/null 2>&1 || true
  fi
  [[ -z "${stage}" ]] || rm -rf -- "${stage}" || true
  exit "${status}"
}
trap cleanup EXIT
trap 'signal_exit 129' HUP
trap 'signal_exit 130' INT
trap 'signal_exit 143' TERM
umask 077
stage="$(mktemp -d "${project_root}/.controller-update-package.XXXXXX")" || fail 'Cannot create an update package staging directory.'
container_name="xingchen-update-extract-${stage##*.}-${BASHPID}"
container_id="$(docker create --name "${container_name}" "${image_id}" 2>/dev/null)" || fail 'Cannot create the Setup extraction container.'
[[ "${container_id}" =~ ^[a-f0-9]{64}$ ]] || fail 'Docker returned an invalid extraction container ID.'
docker cp "${container_id}:/usr/local/share/xingchen/controller-update/." "${stage}/" >/dev/null 2>&1 || fail 'Cannot extract the Controller update package from Setup.'
[[ -d "${stage}/deploy" && ! -L "${stage}/deploy" ]] || fail 'Extracted package deploy directory is invalid.'
chmod 700 -- "${stage}" "${stage}/deploy"
verify_package "${stage}"
updater_args=("--${mode}" --online-release "${stage}")
[[ "${runner}" == true ]] || updater_args+=(--project-root "${project_root}")
updater_running=true
XINGCHEN_TARGET_VERSION="${target_version}" bash "${stage}/deploy/update-controller.sh" "${updater_args[@]}"
