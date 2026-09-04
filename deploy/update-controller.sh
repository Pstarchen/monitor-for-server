#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: update-controller.sh [--check|--apply|--auto] [--build|--source-build] [--offline] [--no-mirror] [--no-source-fallback]
                            [--project-root PATH --offline-bundle PATH]

  --check       pull candidate images and report that an update is ready.
  --apply       pull images and restart the controller services.
  --auto        enable the controller's daily 04:00 automatic update.
  --build       build from local source instead of pulling images.
  --source-build  build Docker images from Gitee/GitHub source repositories.
  --offline     use only images that are already loaded in the local Docker engine.
  --no-mirror   skip configured mainland-China mirror registries.
  --no-source-fallback  fail instead of building from source when all image registries are unavailable.
  --project-root  operate on an existing deployment at the absolute PATH.
  --offline-bundle  verify and apply the extracted offline bundle at PATH.
USAGE
}

mode=check
build=false
source_build=false
source_fallback=true
use_mirror=true
offline=false
project_root_override=""
offline_bundle=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) mode=check; shift ;;
    --apply) mode=apply; shift ;;
    --auto) mode=auto; shift ;;
    --build) build=true; shift ;;
    --source-build) source_build=true; shift ;;
    --offline) offline=true; shift ;;
    --no-mirror) use_mirror=false; shift ;;
    --no-source-fallback) source_fallback=false; shift ;;
    --project-root)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--project-root 需要绝对路径。" >&2; exit 2; }
      project_root_override="$2"
      shift 2
      ;;
    --offline-bundle)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--offline-bundle 需要绝对路径。" >&2; exit 2; }
      offline_bundle="$2"
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "${offline_bundle}" ]]; then
  offline=true
  source_fallback=false
  if [[ -z "${project_root_override}" ]]; then
    echo "--offline-bundle 必须与 --project-root 一起使用。" >&2
    exit 2
  fi
fi
if [[ "${offline}" == true && ( "${build}" == true || "${source_build}" == true || "${mode}" == auto ) ]]; then
  echo "--offline 不能与 --build、--source-build 或 --auto 同时使用。" >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${CONTROLLER_UPDATE_RUNNER:-false}" == true ]]; then
  if [[ -n "${project_root_override}" || -n "${offline_bundle}" ]]; then
    echo "更新 Runner 不接受外部项目根或离线 bundle 参数。" >&2
    exit 2
  fi
  if [[ -z "${SETUP_WORKSPACE:-}" || "${SETUP_WORKSPACE}" != /* ]]; then
    echo "更新 Runner 要求 SETUP_WORKSPACE 为绝对路径。" >&2
    exit 2
  fi
  if [[ ! -d "${SETUP_WORKSPACE}" || ! -f "${SETUP_WORKSPACE}/docker-compose.yml" || ! -f "${SETUP_WORKSPACE}/.env" ]]; then
    echo "更新 Runner 的 SETUP_WORKSPACE 缺少现有部署目录、docker-compose.yml 或 .env。" >&2
    exit 2
  fi
  project_root="$(cd -- "${SETUP_WORKSPACE}" && pwd -P)"
elif [[ -n "${project_root_override}" ]]; then
  if [[ "${project_root_override}" != /* || ! -d "${project_root_override}" ]]; then
    echo "--project-root 必须是已存在的绝对目录。" >&2
    exit 2
  fi
  project_root="$(cd -- "${project_root_override}" && pwd -P)"
  if [[ "${project_root}" == / || ! -f "${project_root}/docker-compose.yml" || ! -f "${project_root}/.env" ]]; then
    echo "--project-root 必须指向包含 docker-compose.yml 和 .env 的既有部署，且不能是根目录。" >&2
    exit 2
  fi
else
  project_root="$(cd -- "${script_dir}/.." && pwd)"
fi
if [[ -n "${offline_bundle}" ]]; then
  if [[ "${offline_bundle}" != /* || ! -d "${offline_bundle}" ]]; then
    echo "--offline-bundle 必须是已解压的绝对目录。" >&2
    exit 2
  fi
  offline_bundle="$(cd -- "${offline_bundle}" && pwd -P)"
  if [[ "${offline_bundle}" == "${project_root}" ]]; then
    echo "离线 bundle 目录不能与既有部署目录相同。" >&2
    exit 2
  fi
fi
cd "${project_root}"

read_env_value() {
  local key="$1" value
  value="$(awk -v key="${key}" 'index($0, key "=") == 1 {value=substr($0, length(key) + 2); gsub(/^"|"$/, "", value); print value; exit}' .env 2>/dev/null || true)"
  printf '%s' "${value}"
}

network_mode="${XINGCHEN_NETWORK_MODE:-$(read_env_value XINGCHEN_NETWORK_MODE)}"
network_mode="${network_mode,,}"
network_mode="${network_mode:-public}"
allow_gitee="${XINGCHEN_ALLOW_GITEE:-$(read_env_value XINGCHEN_ALLOW_GITEE)}"
allow_gitee="${allow_gitee,,}"
allow_gitee="${allow_gitee:-false}"
[[ "${network_mode}" == public || "${network_mode}" == internal || "${network_mode}" == offline ]] \
  || { echo "XINGCHEN_NETWORK_MODE 必须是 public、internal 或 offline。" >&2; exit 2; }
[[ "${allow_gitee}" == true || "${allow_gitee}" == false ]] \
  || { echo "XINGCHEN_ALLOW_GITEE 必须是 true 或 false。" >&2; exit 2; }
if [[ "${offline}" == true ]]; then
  network_mode=offline
elif [[ "${network_mode}" == offline ]]; then
  offline=true
  source_fallback=false
  if [[ "${build}" == true || "${source_build}" == true || "${mode}" == auto ]]; then
    echo "offline 网络模式不能与 --build、--source-build 或 --auto 同时使用。" >&2
    exit 2
  fi
fi
if [[ "${network_mode}" == internal ]]; then
  source_fallback=false
  if [[ "${build}" == true || "${source_build}" == true ]]; then
    echo "internal 网络模式禁止 --build 和 --source-build；请使用已导入镜像或内部 Registry。" >&2
    exit 2
  fi
fi

host_matches() {
  local host="${1,,}" suffix="${2,,}"
  host="${host%.}"
  suffix="${suffix%.}"
  [[ "${host}" == "${suffix}" || "${host}" == *."${suffix}" ]]
}

host_is_forbidden_public() {
  local host="$1"
  host_matches "${host}" github.com \
    || host_matches "${host}" githubusercontent.com \
    || host_matches "${host}" githubassets.com \
    || host_matches "${host}" ghcr.io \
    || host_matches "${host}" docker.io \
    || host_matches "${host}" docker.com \
    || host_matches "${host}" ghcr.1ms.run \
    || host_matches "${host}" ghcr.nju.edu.cn \
    || host_matches "${host}" ghcr.m.daocloud.io
}

validate_internal_image_reference() {
  local image="$1" name first lower_first registry_host
  if [[ "${image}" == *://* || "${image}" == *[[:space:]]* ]]; then
    [[ "${network_mode}" == internal ]] || return 0
    echo "internal 网络模式拒绝无效镜像引用：${image}" >&2
    return 1
  fi
  name="${image%%@*}"
  if [[ "${name}" != */* ]]; then
    [[ "${network_mode}" == internal ]] || return 0
    echo "internal 网络模式拒绝无 registry 主机的镜像：${image}" >&2
    return 1
  fi
  first="${name%%/*}"
  lower_first="${first,,}"
  if [[ "${first}" != *.* && "${first}" != *:* && "${lower_first}" != localhost ]]; then
    [[ "${network_mode}" == internal ]] || return 0
    echo "internal 网络模式拒绝 Docker Hub/无主机镜像：${image}" >&2
    return 1
  fi
  registry_host="${lower_first%%:*}"
  registry_host="${registry_host%.}"
  if host_matches "${registry_host}" gitee.com && [[ "${allow_gitee}" != true ]]; then
    echo "Gitee Registry 仅在 XINGCHEN_ALLOW_GITEE=true 时允许：${image}" >&2
    return 1
  fi
  [[ "${network_mode}" == internal ]] || return 0
  if host_is_forbidden_public "${registry_host}"; then
    echo "internal 网络模式拒绝公共镜像源：${image}" >&2
    return 1
  fi
}

source_repository_host() {
  local value="${1,,}" authority
  if [[ "${value}" == *://* ]]; then
    authority="${value#*://}"
    authority="${authority%%/*}"
    authority="${authority##*@}"
    printf '%s' "${authority%%:*}"
  elif [[ "${value}" == *@*:* ]]; then
    authority="${value#*@}"
    printf '%s' "${authority%%:*}"
  fi
}

validate_source_repository_policy() {
  local repository="$1" host
  host="$(source_repository_host "${repository}")"
  host="${host%.}"
  if host_matches "${host}" gitee.com && [[ "${allow_gitee}" != true ]]; then
    echo "Gitee 源仅在 XINGCHEN_ALLOW_GITEE=true 时允许：${repository}" >&2
    return 1
  fi
  if [[ "${network_mode}" == internal ]] && host_is_forbidden_public "${host}"; then
    echo "internal 网络模式拒绝 GitHub 源码地址或其他公共源码地址：${repository}" >&2
    return 1
  fi
}

# Registry downloads can legitimately take several minutes on a constrained link.
# Keep the timeout finite, configurable, and aligned with the Windows updater.
pull_timeout_seconds="${XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS:-$(read_env_value XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS)}"
pull_timeout_seconds="${pull_timeout_seconds:-180}"
mirror_timeout_seconds="${XINGCHEN_UPDATE_MIRROR_TIMEOUT_SECONDS:-$(read_env_value XINGCHEN_UPDATE_MIRROR_TIMEOUT_SECONDS)}"
mirror_timeout_seconds="${mirror_timeout_seconds:-45}"
compose_timeout_seconds="${XINGCHEN_UPDATE_COMPOSE_TIMEOUT_SECONDS:-$(read_env_value XINGCHEN_UPDATE_COMPOSE_TIMEOUT_SECONDS)}"
compose_timeout_seconds="${compose_timeout_seconds:-900}"
minimum_free_bytes="${XINGCHEN_UPDATE_MIN_FREE_BYTES:-$(read_env_value XINGCHEN_UPDATE_MIN_FREE_BYTES)}"
minimum_free_bytes="${minimum_free_bytes:-1073741824}"
if [[ ! "${pull_timeout_seconds}" =~ ^[1-9][0-9]*$ || ! "${mirror_timeout_seconds}" =~ ^[1-9][0-9]*$ || ! "${compose_timeout_seconds}" =~ ^[1-9][0-9]*$ ]]; then
  echo "更新超时必须是正整数秒数。" >&2
  exit 2
fi
if [[ ! "${minimum_free_bytes}" =~ ^[1-9][0-9]*$ ]]; then
  echo "XINGCHEN_UPDATE_MIN_FREE_BYTES 必须是正整数。" >&2
  exit 2
fi

run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    if timeout "${seconds}s" "$@"; then
      return 0
    else
      status=$?
      if [[ "${status}" -eq 124 ]]; then
        echo "Docker 命令超过 ${seconds} 秒，已终止：$*" >&2
      fi
      return "${status}"
    fi
  fi
  "$@"
}

if ! run_with_timeout "${pull_timeout_seconds}" docker compose version >/dev/null 2>&1; then
  echo "Docker Engine and Docker Compose v2 are required." >&2
  exit 1
fi

check_free_space() {
  local path="$1" available_kb available_bytes
  available_kb="$(df -Pk "${path}" 2>/dev/null | awk 'NR == 2 { print $4; exit }')"
  if [[ ! "${available_kb}" =~ ^[0-9]+$ ]]; then
    echo "无法确认 ${path} 的可用磁盘空间。" >&2
    return 1
  fi
  available_bytes=$((available_kb * 1024))
  if ((available_bytes < minimum_free_bytes)); then
    echo "可用磁盘空间不足：${path} 需要至少 ${minimum_free_bytes} 字节，当前约 ${available_bytes} 字节。" >&2
    return 1
  fi
}

check_free_space "${project_root}"
docker_root="$(run_with_timeout "${pull_timeout_seconds}" docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
if [[ -n "${docker_root}" && -d "${docker_root}" && "${docker_root}" != "${project_root}" ]]; then
  check_free_space "${docker_root}"
fi

lock_file="${project_root}/.controller-update.lock"
if [[ -z "${offline_bundle}" || "${mode}" != check ]]; then
  if ! command -v flock >/dev/null 2>&1; then
    echo "总控更新需要 flock 提供跨进程互斥；请先安装 util-linux。" >&2
    exit 1
  fi
  exec 9>"${lock_file}"
  if ! flock -n 9; then
    echo "已有总控更新任务正在执行，请稍后重试。" >&2
    exit 75
  fi
fi

bundle_version=""
bundle_arch=""
declare -A bundle_verified=()
verify_offline_bundle() {
  local checksum_file="${offline_bundle}/SHA256SUMS" line expected relative path resolved actual
  local required
  command -v sha256sum >/dev/null 2>&1 || { echo "离线升级需要 sha256sum。" >&2; return 1; }
  command -v realpath >/dev/null 2>&1 || { echo "离线升级需要 realpath。" >&2; return 1; }
  [[ -f "${checksum_file}" && ! -L "${checksum_file}" ]] || { echo "离线 bundle 缺少可信 SHA256SUMS。" >&2; return 1; }
  bundle_verified=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^([a-fA-F0-9]{64})[[:space:]]([[:space:]]|\*)(.+)$ ]] || { echo "离线校验清单格式无效。" >&2; return 1; }
    expected="${BASH_REMATCH[1],,}"
    relative="${BASH_REMATCH[3]}"
    if [[ ! "${relative}" =~ ^[A-Za-z0-9._+@/-]+$ || "${relative}" == /* || "${relative}" == *//* || "${relative}" == . || "${relative}" == ./* || "${relative}" == */./* || "${relative}" == */. || "${relative}" == .. || "${relative}" == ../* || "${relative}" == */../* || "${relative}" == */.. ]]; then
      echo "离线校验路径不安全：${relative}" >&2
      return 1
    fi
    [[ -z "${bundle_verified[${relative}]:-}" ]] || { echo "离线校验清单包含重复路径：${relative}" >&2; return 1; }
    path="${offline_bundle}/${relative}"
    [[ -f "${path}" && ! -L "${path}" ]] || { echo "离线文件缺失或不是普通文件：${relative}" >&2; return 1; }
    resolved="$(realpath -e -- "${path}")"
    [[ "${resolved}" == "${offline_bundle}/"* ]] || { echo "离线校验路径越界：${relative}" >&2; return 1; }
    actual="$(sha256sum "${path}" | awk '{print $1}')"
    [[ "${actual}" == "${expected}" ]] || { echo "离线文件校验失败：${relative}" >&2; return 1; }
    bundle_verified["${relative}"]=true
  done < "${checksum_file}"
  for required in bundle-metadata.txt docker-compose.yml deploy/offline-bundle-integrity.sh deploy/update-controller.sh deploy/update-controller.ps1 images/controller-images.tar release/manifest.json release/assets/checksums.txt upgrade-offline.sh upgrade-offline.ps1; do
    [[ "${bundle_verified[${required}]:-}" == true ]] || { echo "离线校验清单缺少必要文件：${required}" >&2; return 1; }
  done
  while IFS= read -r -d '' path; do
    [[ "${path}" == "${checksum_file}" ]] && continue
    relative="${path#"${offline_bundle}/"}"
    [[ ! -L "${path}" ]] || { echo "离线 bundle 不允许符号链接：${relative}" >&2; return 1; }
    [[ "${bundle_verified[${relative}]:-}" == true ]] || { echo "离线 bundle 包含未列入校验清单的文件：${relative}" >&2; return 1; }
  done < <(find "${offline_bundle}" \( -type f -o -type l \) -print0)

  local schema="" key value schema_seen=false version_seen=false arch_seen=false
  while IFS='=' read -r key value || [[ -n "${key}${value}" ]]; do
    case "${key}" in
      schema) [[ "${schema_seen}" == false ]] || { echo "离线 bundle 元数据字段重复：schema" >&2; return 1; }; schema_seen=true; schema="${value}" ;;
      version) [[ "${version_seen}" == false ]] || { echo "离线 bundle 元数据字段重复：version" >&2; return 1; }; version_seen=true; bundle_version="${value}" ;;
      architecture) [[ "${arch_seen}" == false ]] || { echo "离线 bundle 元数据字段重复：architecture" >&2; return 1; }; arch_seen=true; bundle_arch="${value}" ;;
      *) echo "离线 bundle 元数据字段无效：${key}" >&2; return 1 ;;
    esac
  done < "${offline_bundle}/bundle-metadata.txt"
  [[ "${schema}" == 1 && "${bundle_version}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ && ( "${bundle_arch}" == amd64 || "${bundle_arch}" == arm64 ) ]] \
    || { echo "离线 bundle 元数据无效。" >&2; return 1; }
  local host_arch
  case "$(uname -m)" in
    x86_64|amd64) host_arch=amd64 ;;
    aarch64|arm64) host_arch=arm64 ;;
    *) echo "当前主机架构不受离线 bundle 支持。" >&2; return 1 ;;
  esac
  [[ "${host_arch}" == "${bundle_arch}" ]] || { echo "离线 bundle 架构 ${bundle_arch} 与主机 ${host_arch} 不匹配。" >&2; return 1; }
  # shellcheck source=offline-bundle-integrity.sh
  source "${offline_bundle}/deploy/offline-bundle-integrity.sh"
  offline_verify_controller_image_archive "${offline_bundle}/images/controller-images.tar" "${bundle_version}"
  offline_verify_agent_release "${offline_bundle}/release/manifest.json" "${offline_bundle}/release/assets" \
    "${offline_bundle}/release/assets/checksums.txt" "${bundle_version}"
}

if [[ -n "${offline_bundle}" ]]; then
  verify_offline_bundle
fi

if [[ -n "${offline_bundle}" ]]; then
  target_version="${bundle_version}"
else
  target_version="${XINGCHEN_TARGET_VERSION:-$(read_env_value XINGCHEN_TARGET_VERSION)}"
fi
if [[ -n "${target_version}" ]]; then
  if [[ "${target_version}" =~ ^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    target_version="v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  else
    echo "XINGCHEN_TARGET_VERSION 必须是稳定语义版本，例如 v1.20.5。" >&2
    exit 2
  fi
  source_ref="${target_version}"
else
  source_ref="${XINGCHEN_SOURCE_REF:-$(read_env_value XINGCHEN_SOURCE_REF)}"
  source_ref="${source_ref:-main}"
fi
if [[ "${offline}" == true && -z "${target_version}" ]]; then
  echo "离线模式要求通过 XINGCHEN_TARGET_VERSION 指定稳定版本。" >&2
  exit 2
fi
source_build_timeout_seconds="${XINGCHEN_SOURCE_BUILD_TIMEOUT_SECONDS:-$(read_env_value XINGCHEN_SOURCE_BUILD_TIMEOUT_SECONDS)}"
source_build_timeout_seconds="${source_build_timeout_seconds:-1200}"
source_repository_list="${XINGCHEN_SOURCE_REPOSITORIES:-$(read_env_value XINGCHEN_SOURCE_REPOSITORIES)}"
source_repositories=()
if [[ -n "${source_repository_list}" ]]; then
  IFS=',' read -r -a source_repositories <<< "${source_repository_list}"
fi
if [[ ! "${source_build_timeout_seconds}" =~ ^[1-9][0-9]*$ ]]; then
  echo "XINGCHEN_SOURCE_BUILD_TIMEOUT_SECONDS 必须是正整数秒数。" >&2
  exit 2
fi
if [[ -z "${source_ref}" || "${source_ref}" == -* || "${source_ref}" == *..* || ! "${source_ref}" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
  echo "总控源码仓库列表或 Git ref 无效。" >&2
  exit 2
fi
if [[ "${source_build}" == true && ${#source_repositories[@]} -eq 0 ]]; then
  echo "源码构建要求显式配置允许访问的 XINGCHEN_SOURCE_REPOSITORIES。" >&2
  exit 2
fi
if [[ "${source_fallback}" == true && ${#source_repositories[@]} -eq 0 ]]; then
  source_fallback=false
fi
for source_repository in "${source_repositories[@]}"; do
  if [[ -z "${source_repository}" ]]; then
    echo "总控源码仓库地址不能为空。" >&2
    exit 2
  fi
done

compose_args=()
controller_agent_enabled="${CONTROLLER_AGENT_ENABLED:-}"
if [[ -z "${controller_agent_enabled}" && -f .env ]]; then
  controller_agent_enabled="$(read_env_value CONTROLLER_AGENT_ENABLED)"
fi
if [[ "$(uname -s)" == "Linux" && "${controller_agent_enabled,,}" == "true" ]]; then
  compose_args+=(--profile host-monitoring)
fi
compose_project_root="${XINGCHEN_HOST_PROJECT_ROOT:-${project_root}}"
compose_args+=(-f "${project_root}/docker-compose.yml" --project-directory "${compose_project_root}" --env-file "${project_root}/.env")
services=(setup server web)
source_contexts=(. server web)
source_dockerfiles=(setup/Dockerfile '' '')
if [[ "$(uname -s)" == "Linux" && "${controller_agent_enabled,,}" == "true" ]]; then
  services+=(controller-agent)
  source_contexts+=(agent)
  source_dockerfiles+=('')
fi

image_value() {
  local name="$1" default="$2" value
  value="${!name:-}"
  if [[ -z "${value}" && -f .env ]]; then
    value="$(read_env_value "${name}")"
  fi
  printf '%s' "${value:-${default}}"
}

image_keys=(XINGCHEN_SETUP_IMAGE XINGCHEN_SERVER_IMAGE XINGCHEN_WEB_IMAGE)
source_images=(
  "$(image_value XINGCHEN_SETUP_IMAGE ghcr.io/pstarchen/monitor-for-server-setup:v1.20.15)"
  "$(image_value XINGCHEN_SERVER_IMAGE ghcr.io/pstarchen/monitor-for-server-server:v1.20.15)"
  "$(image_value XINGCHEN_WEB_IMAGE ghcr.io/pstarchen/monitor-for-server-web:v1.20.15)"
)
if [[ "$(uname -s)" == "Linux" && "${controller_agent_enabled,,}" == "true" ]]; then
  image_keys+=(XINGCHEN_AGENT_IMAGE)
  source_images+=("$(image_value XINGCHEN_AGENT_IMAGE ghcr.io/pstarchen/monitor-for-server-agent:v1.20.15)")
fi
dependency_images=(
  "$(image_value XINGCHEN_POSTGRES_IMAGE postgres:16-alpine)"
  "$(image_value XINGCHEN_REDIS_IMAGE redis:7.4-alpine)"
)

verify_image_version() {
  local image="$1" actual
  [[ -z "${target_version}" ]] && return 0
  actual="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${image}" 2>/dev/null || true)"
  if [[ "${actual#v}" != "${target_version#v}" ]]; then
    echo "镜像版本不匹配：${image} 标记为 ${actual:-unknown}，期望 ${target_version}。" >&2
    return 1
  fi
}

versioned_reference() {
  local image="$1"
  local leaf="${image##*/}"
  if [[ -z "${target_version}" || "${image}" == *@* ]]; then
    printf '%s' "${image}"
    return
  fi
  if [[ "${leaf}" == *:* ]]; then
    printf '%s:%s' "${image%:*}" "${target_version}"
  else
    printf '%s:%s' "${image}" "${target_version}"
  fi
}

candidate_images=()
if [[ -n "${offline_bundle}" ]]; then
  candidate_images=(
    "ghcr.io/pstarchen/monitor-for-server-setup:${bundle_version}"
    "ghcr.io/pstarchen/monitor-for-server-server:${bundle_version}"
    "ghcr.io/pstarchen/monitor-for-server-web:${bundle_version}"
  )
  if [[ "$(uname -s)" == "Linux" && "${controller_agent_enabled,,}" == "true" ]]; then
    candidate_images+=("ghcr.io/pstarchen/monitor-for-server-agent:${bundle_version}")
  fi
  dependency_images=(postgres:16-alpine redis:7.4-alpine)
else
  for source_image in "${source_images[@]}"; do
    candidate_images+=("$(versioned_reference "${source_image}")")
  done
fi

controller_image_mirror_list() {
  local value="${XINGCHEN_CONTROLLER_IMAGE_MIRRORS:-}"
  if [[ -z "${value}" && -f .env ]]; then
    value="$(read_env_value XINGCHEN_CONTROLLER_IMAGE_MIRRORS)"
  fi
  printf '%s' "${value}"
}

validate_internal_candidate_reference() {
  local image="$1" suffix mirror_list prefix candidate found=false
  [[ "${network_mode}" == internal ]] || return 0
  if [[ "${image,,}" != ghcr.io/* ]]; then
    validate_internal_image_reference "${image}"
    return
  fi
  if [[ "${use_mirror}" != true ]]; then
    echo "internal 网络模式下的 GHCR 逻辑镜像必须启用并配置内部镜像源：${image}" >&2
    return 1
  fi
  suffix="${image#*/}"
  mirror_list="$(controller_image_mirror_list)"
  IFS=',' read -r -a prefixes <<< "${mirror_list}"
  for prefix in "${prefixes[@]}"; do
    prefix="${prefix%/}"
    [[ -z "${prefix}" ]] && continue
    candidate="${prefix}/${suffix}"
    validate_internal_image_reference "${candidate}" || return 1
    found=true
  done
  if [[ "${found}" != true ]]; then
    echo "internal 网络模式缺少可用的内部总控镜像源：${image}" >&2
    return 1
  fi
}

if [[ "${network_mode}" == internal ]]; then
  for image in "${candidate_images[@]}"; do
    validate_internal_candidate_reference "${image}"
  done
  for image in "${dependency_images[@]}"; do
    validate_internal_image_reference "${image}"
  done
fi
if [[ "${offline}" != true && ( "${network_mode}" == internal || "${source_build}" == true || ( "${build}" != true && "${source_fallback}" == true ) ) ]]; then
  for source_repository in "${source_repositories[@]}"; do
    validate_source_repository_policy "${source_repository}"
  done
fi

version_less() {
  local left="${1#v}" right="${2#v}" l1 l2 l3 r1 r2 r3
  IFS=. read -r l1 l2 l3 <<< "${left}"
  IFS=. read -r r1 r2 r3 <<< "${right}"
  ((10#${l1} < 10#${r1} ||
    (10#${l1} == 10#${r1} && 10#${l2} < 10#${r2}) ||
    (10#${l1} == 10#${r1} && 10#${l2} == 10#${r2} && 10#${l3} < 10#${r3})))
}

running_service_version() {
  local service="$1" container_id actual normalized
  container_id="$(docker compose "${compose_args[@]}" ps -q "${service}" 2>/dev/null || true)"
  [[ -n "${container_id}" ]] || return 1
  actual="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${container_id}" 2>/dev/null || true)"
  normalized="${actual#v}"
  [[ "${normalized}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf 'v%s' "${normalized}"
}

guard_target_version() {
  [[ -n "${target_version}" ]] || return 0
  local current_version service service_version all_current=true
  current_version="$(running_service_version server || true)"
  if [[ -n "${current_version}" ]] && version_less "${target_version}" "${current_version}"; then
    echo "拒绝将总控从 ${current_version} 降级到 ${target_version}。" >&2
    exit 2
  fi
  [[ "${mode}" == apply ]] || return 0
  for service in "${services[@]}"; do
    service_version="$(running_service_version "${service}" || true)"
    if [[ "${service_version}" != "${target_version}" ]]; then
      all_current=false
      break
    fi
  done
  if [[ "${all_current}" == true ]]; then
    echo "总控所有组件已是 ${target_version}，无需重复更新。"
    exit 0
  fi
}

guard_target_version

if [[ -n "${offline_bundle}" && "${mode}" == check ]]; then
  echo "离线 bundle 校验完成：${bundle_version} (${bundle_arch})；未加载镜像或修改现有部署。"
  exit 0
fi

pull_one() {
  local image="$1"
  local suffix prefix candidate mirror_list
  if [[ "${use_mirror}" == true && "${image}" == ghcr.io/* ]]; then
    suffix="${image#ghcr.io/}"
    mirror_list="$(controller_image_mirror_list)"
    IFS=',' read -r -a prefixes <<< "${mirror_list}"
    for prefix in "${prefixes[@]}"; do
      prefix="${prefix%/}"
      [[ -z "${prefix}" ]] && continue
      candidate="${prefix}/${suffix}"
      validate_internal_image_reference "${candidate}" || return 1
      echo "尝试国内镜像源：${candidate}"
      if run_with_timeout "${mirror_timeout_seconds}" docker pull "${candidate}" >/dev/null && verify_image_version "${candidate}" && run_with_timeout "${mirror_timeout_seconds}" docker tag "${candidate}" "${image}"; then
        return 0
      fi
    done
    if [[ "${network_mode}" == internal ]]; then
      echo "所有已配置的内部总控镜像源均不可用：${image}" >&2
      return 1
    fi
  fi
  validate_internal_image_reference "${image}" || return 1
  echo "尝试官方镜像源：${image}"
  if ! run_with_timeout "${pull_timeout_seconds}" docker pull "${image}" || ! verify_image_version "${image}"; then
    return 1
  fi
}

pull_images() {
  local image failed=false
  for image in "${candidate_images[@]}"; do
    if ! pull_one "${image}"; then
      failed=true
    fi
  done
  [[ "${failed}" == false ]]
}

prepare_dependency_images() {
  local image
  for image in "${dependency_images[@]}"; do
    validate_internal_image_reference "${image}" || return 1
    if docker image inspect "${image}" >/dev/null 2>&1; then
      continue
    fi
    if [[ "${offline}" == true ]]; then
      echo "离线基础镜像缺失：${image}" >&2
      return 1
    fi
    echo "正在准备总控基础镜像：${image}"
    if ! run_with_timeout "${pull_timeout_seconds}" docker pull "${image}"; then
      echo "总控基础镜像不可用：${image}；请配置内部镜像引用或使用完整离线包。" >&2
      return 1
    fi
  done
}

remove_source_build_images() {
  local temporary_image
  for temporary_image in "$@"; do
    docker image rm -f "${temporary_image}" >/dev/null 2>&1 || true
  done
}

build_images_from_repositories() {
  local repository context dockerfile temporary_image
  local index success
  local build_prefix="xingchen-controller-source-$$-${RANDOM}"
  local temporary_images=() build_command=()
  for image in "${candidate_images[@]}"; do
    if [[ "${image}" == *@* ]]; then
      echo "固定摘要镜像无法使用源码构建回退：${image}" >&2
      return 1
    fi
  done
  for repository in "${source_repositories[@]}"; do
    validate_source_repository_policy "${repository}" || return 1
    temporary_images=()
    success=true
    echo "正在尝试总控源码仓库：${repository} (${source_ref})"
    for ((index = 0; index < ${#source_contexts[@]}; index++)); do
      if [[ "${source_contexts[index]}" == . ]]; then
        context="${repository}#${source_ref}"
      else
        context="${repository}#${source_ref}:${source_contexts[index]}"
      fi
      dockerfile="${source_dockerfiles[index]}"
      temporary_image="${build_prefix}-${index}:candidate"
      temporary_images+=("${temporary_image}")
      build_command=(docker build)
      [[ "${network_mode}" == public ]] && build_command+=(--pull)
      [[ -n "${dockerfile}" ]] && build_command+=(--file "${dockerfile}")
      build_command+=(--build-arg "VERSION=${target_version:-dev}" --tag "${temporary_image}" "${context}")
      if ! run_with_timeout "${source_build_timeout_seconds}" "${build_command[@]}" || ! verify_image_version "${temporary_image}"; then
        success=false
        break
      fi
    done
    if [[ "${success}" == true ]]; then
      for ((index = 0; index < ${#candidate_images[@]}; index++)); do
        docker tag "${temporary_images[index]}" "${candidate_images[index]}"
      done
      remove_source_build_images "${temporary_images[@]}"
      return 0
    fi
    remove_source_build_images "${temporary_images[@]}"
  done
  echo "GitHub 与 Gitee 总控源码均无法完成 Docker 构建。" >&2
  return 1
}

verify_local_images() {
  local image failed=false
  for image in "${candidate_images[@]}"; do
    if ! docker image inspect "${image}" >/dev/null 2>&1 || ! verify_image_version "${image}"; then
      echo "离线镜像缺失或版本不匹配：${image}" >&2
      failed=true
    fi
  done
  for image in "${dependency_images[@]}"; do
    if ! docker image inspect "${image}" >/dev/null 2>&1; then
      echo "离线基础镜像缺失：${image}" >&2
      failed=true
    fi
  done
  [[ "${failed}" == false ]]
}

verify_prepared_images() {
  [[ -n "${target_version}" ]] || return 0
  local image failed=false
  for image in "${candidate_images[@]}"; do
    if ! verify_image_version "${image}"; then
      failed=true
    fi
  done
  [[ "${failed}" == false ]]
}

set_env_values() {
  if (($# == 0 || $# % 2 != 0)); then
    echo "内部错误：环境设置必须成对提供。" >&2
    return 1
  fi
  local key value temporary payload="" count=0
  while (($# > 0)); do
    key="$1"
    value="$2"
    shift 2
    if [[ ! "${key}" =~ ^[A-Z][A-Z0-9_]*$ || "${value}" == *$'\n'* || "${value}" == *$'\r'* || "${value}" == *'"'* ]]; then
      echo "拒绝写入无效的环境设置：${key}" >&2
      return 1
    fi
    payload+="${key}"$'\n'"${value}"$'\n'
    ((count += 1))
  done
  temporary="$(mktemp "${project_root}/.env.controller-update.XXXXXX")"
  awk -v payload="${payload}" -v count="${count}" '
    BEGIN {
      split(payload, values, "\n")
      for (i = 1; i <= count; i++) {
        keys[i] = values[i * 2 - 1]
        replacements[i] = values[i * 2]
        found[i] = 0
      }
    }
    {
      for (i = 1; i <= count; i++) {
        if (index($0, keys[i] "=") == 1) {
          if (!found[i]) print keys[i] "=\"" replacements[i] "\""
          found[i] = 1
          next
        }
      }
      print
    }
    END {
      for (i = 1; i <= count; i++) {
        if (!found[i]) print keys[i] "=\"" replacements[i] "\""
      }
    }
  ' "${project_root}/.env" > "${temporary}"
  chmod 600 "${temporary}"
  mv "${temporary}" "${project_root}/.env"
}

set_env_value() {
  set_env_values "$1" "$2"
}

ensure_compose_project_name() {
  if [[ ! -f "${project_root}/.env" ]]; then
    return 0
  fi
  local configured database
  configured="$(read_env_value COMPOSE_PROJECT_NAME)"
  [[ -n "${configured}" ]] && return
  database="$(read_env_value POSTGRES_DB)"
  if [[ "${database}" == "guanlan_monitor" ]] || docker volume inspect guanlan-monitor_postgres-data >/dev/null 2>&1; then
    set_env_value COMPOSE_PROJECT_NAME "guanlan-monitor"
  else
    set_env_value COMPOSE_PROJECT_NAME "xingchen-monitor"
  fi
}

bundle_snapshot_dir=""
bundle_release_stage=""
bundle_release_target=""
bundle_release_created=false
bundle_transaction_active=false
bundle_transaction_committed=false
bundle_image_mutation_started=false
bundle_candidate_attempted=false
bundle_database_backup=""
bundle_env_mode=""
bundle_compose_mode=""
bundle_updater_sh_mode=""
bundle_updater_ps1_mode=""
bundle_updater_sh_existed=false
bundle_updater_ps1_existed=false
bundle_process_keys=(
  XINGCHEN_TARGET_VERSION
  XINGCHEN_SETUP_IMAGE XINGCHEN_SERVER_IMAGE XINGCHEN_WEB_IMAGE XINGCHEN_AGENT_IMAGE
  XINGCHEN_POSTGRES_IMAGE XINGCHEN_REDIS_IMAGE
  XINGCHEN_RELEASE_MANIFEST_PATH XINGCHEN_RELEASE_MANIFEST_SHA256 XINGCHEN_AGENT_OFFLINE_DIR
  XINGCHEN_RELEASE_MANIFEST_URLS XINGCHEN_AGENT_RELEASE_BASE_URLS XINGCHEN_CONTROLLER_ALLOW_GITHUB_API
  XINGCHEN_NETWORK_MODE XINGCHEN_ALLOW_GITEE
)
bundle_process_was_set=()
bundle_process_values=()

assert_safe_deployment_path() {
  local path="$1" label="${2:-部署路径}" relative current component resolved
  local components=()
  case "${path}" in
    "${project_root}") relative="" ;;
    "${project_root}/"*) relative="${path#"${project_root}/"}" ;;
    *) echo "${label} 超出项目根，拒绝访问：${path}" >&2; return 1 ;;
  esac

  current="${project_root}"
  if [[ -L "${current}" ]]; then
    echo "${label} 的项目根不能是符号链接：${current}" >&2
    return 1
  fi
  resolved="$(realpath -e -- "${current}")" || { echo "无法解析 ${label} 的项目根：${current}" >&2; return 1; }
  [[ "${resolved}" == "${project_root}" ]] || { echo "${label} 的项目根解析结果不一致：${current}" >&2; return 1; }
  [[ -n "${relative}" ]] || return 0

  IFS='/' read -r -a components <<< "${relative}"
  for component in "${components[@]}"; do
    if [[ -z "${component}" || "${component}" == . || "${component}" == .. ]]; then
      echo "${label} 包含不安全路径组件：${path}" >&2
      return 1
    fi
    current="${current}/${component}"
    if [[ -L "${current}" ]]; then
      echo "${label} 的祖先路径不能是符号链接：${current}" >&2
      return 1
    fi
    if [[ -e "${current}" ]]; then
      resolved="$(realpath -e -- "${current}")" || { echo "无法解析 ${label}：${current}" >&2; return 1; }
      case "${resolved}" in
        "${project_root}"|"${project_root}/"*) ;;
        *) echo "${label} 解析后超出项目根：${current}" >&2; return 1 ;;
      esac
    fi
  done
}

begin_bundle_transaction() {
  local key index path
  for path in \
    "${project_root}/.env" \
    "${project_root}/docker-compose.yml" \
    "${project_root}/deploy" \
    "${project_root}/deploy/update-controller.sh" \
    "${project_root}/deploy/update-controller.ps1" \
    "${project_root}/release" \
    "${project_root}/release/versions" \
    "${project_root}/backups"; do
    assert_safe_deployment_path "${path}" "离线升级目标" || return 1
  done
  [[ -f "${project_root}/.env" && ! -L "${project_root}/.env" ]] || { echo "离线升级要求现有 .env 为普通文件。" >&2; return 1; }
  [[ -f "${project_root}/docker-compose.yml" && ! -L "${project_root}/docker-compose.yml" ]] || { echo "离线升级要求现有 docker-compose.yml 为普通文件。" >&2; return 1; }
  bundle_snapshot_dir="$(mktemp -d "${project_root}/.controller-update-snapshot.XXXXXX")" || return 1
  chmod 700 "${bundle_snapshot_dir}" || return 1
  bundle_env_mode="$(stat -c '%a' "${project_root}/.env")" || return 1
  bundle_compose_mode="$(stat -c '%a' "${project_root}/docker-compose.yml")" || return 1
  cp -- "${project_root}/.env" "${bundle_snapshot_dir}/env" || return 1
  chmod 600 "${bundle_snapshot_dir}/env" || return 1
  cp -- "${project_root}/docker-compose.yml" "${bundle_snapshot_dir}/docker-compose.yml" || return 1

  if [[ -e "${project_root}/deploy/update-controller.sh" ]]; then
    [[ -f "${project_root}/deploy/update-controller.sh" && ! -L "${project_root}/deploy/update-controller.sh" ]] || { echo "现有 Bash 更新器不是普通文件。" >&2; return 1; }
    bundle_updater_sh_existed=true
    bundle_updater_sh_mode="$(stat -c '%a' "${project_root}/deploy/update-controller.sh")" || return 1
    cp -- "${project_root}/deploy/update-controller.sh" "${bundle_snapshot_dir}/update-controller.sh" || return 1
  fi
  if [[ -e "${project_root}/deploy/update-controller.ps1" ]]; then
    [[ -f "${project_root}/deploy/update-controller.ps1" && ! -L "${project_root}/deploy/update-controller.ps1" ]] || { echo "现有 PowerShell 更新器不是普通文件。" >&2; return 1; }
    bundle_updater_ps1_existed=true
    bundle_updater_ps1_mode="$(stat -c '%a' "${project_root}/deploy/update-controller.ps1")" || return 1
    cp -- "${project_root}/deploy/update-controller.ps1" "${bundle_snapshot_dir}/update-controller.ps1" || return 1
  fi

  bundle_process_was_set=()
  bundle_process_values=()
  for ((index = 0; index < ${#bundle_process_keys[@]}; index++)); do
    key="${bundle_process_keys[index]}"
    if [[ -v "${key}" ]]; then
      bundle_process_was_set+=(true)
      bundle_process_values+=("${!key}")
    else
      bundle_process_was_set+=(false)
      bundle_process_values+=("")
    fi
  done
  bundle_transaction_active=true
  trap bundle_exit_handler EXIT
}

restore_snapshot_file() {
  local snapshot="$1" target="$2" mode_value="$3" temporary
  assert_safe_deployment_path "${target}" "离线升级恢复目标" || return 1
  temporary="$(mktemp "${target}.restore.XXXXXX")" || return 1
  assert_safe_deployment_path "${temporary}" "离线升级恢复临时文件" || { rm -f -- "${temporary}"; return 1; }
  if ! cp -- "${snapshot}" "${temporary}" || ! chmod "${mode_value}" "${temporary}" || ! mv -f -- "${temporary}" "${target}"; then
    rm -f -- "${temporary}"
    return 1
  fi
}

restore_original_process_environment() {
  local index key
  for ((index = 0; index < ${#bundle_process_keys[@]}; index++)); do
    key="${bundle_process_keys[index]}"
    if [[ "${bundle_process_was_set[index]}" == true ]]; then
      printf -v "${key}" '%s' "${bundle_process_values[index]}"
      export "${key}"
    else
      unset "${key}"
    fi
  done
}

restore_bundle_files() {
  local failed=false
  restore_snapshot_file "${bundle_snapshot_dir}/env" "${project_root}/.env" "${bundle_env_mode}" || failed=true
  restore_snapshot_file "${bundle_snapshot_dir}/docker-compose.yml" "${project_root}/docker-compose.yml" "${bundle_compose_mode}" || failed=true
  if [[ "${bundle_updater_sh_existed}" == true ]]; then
    restore_snapshot_file "${bundle_snapshot_dir}/update-controller.sh" "${project_root}/deploy/update-controller.sh" "${bundle_updater_sh_mode}" || failed=true
  else
    if assert_safe_deployment_path "${project_root}/deploy/update-controller.sh" "Bash 更新器清理目标"; then
      rm -f -- "${project_root}/deploy/update-controller.sh" || failed=true
    else
      failed=true
    fi
  fi
  if [[ "${bundle_updater_ps1_existed}" == true ]]; then
    restore_snapshot_file "${bundle_snapshot_dir}/update-controller.ps1" "${project_root}/deploy/update-controller.ps1" "${bundle_updater_ps1_mode}" || failed=true
  else
    if assert_safe_deployment_path "${project_root}/deploy/update-controller.ps1" "PowerShell 更新器清理目标"; then
      rm -f -- "${project_root}/deploy/update-controller.ps1" || failed=true
    else
      failed=true
    fi
  fi
  if [[ "${bundle_release_created}" == true && -n "${bundle_release_target}" ]]; then
    case "${bundle_release_target}" in
      "${project_root}/release/versions/"v*)
        if assert_safe_deployment_path "${bundle_release_target}" "离线发布清理目标"; then
          rm -rf -- "${bundle_release_target}" || failed=true
        else
          failed=true
        fi
        ;;
      *) echo "拒绝清理范围外的离线发布目录：${bundle_release_target}" >&2; failed=true ;;
    esac
  fi
  [[ "${failed}" == false ]]
}

cleanup_bundle_snapshot() {
  if [[ -n "${bundle_release_stage}" && -d "${bundle_release_stage}" ]]; then
    case "${bundle_release_stage}" in
      "${project_root}/release/versions/."v*)
        assert_safe_deployment_path "${bundle_release_stage}" "离线发布暂存清理目标" \
          && rm -rf -- "${bundle_release_stage}"
        ;;
    esac
  fi
  if [[ -n "${bundle_snapshot_dir}" && -d "${bundle_snapshot_dir}" ]]; then
    case "${bundle_snapshot_dir}" in
      "${project_root}/.controller-update-snapshot."*)
        assert_safe_deployment_path "${bundle_snapshot_dir}" "离线升级快照清理目标" \
          && rm -rf -- "${bundle_snapshot_dir}"
        ;;
    esac
  fi
}

restore_previous_image_tags_for_bundle() {
  local index failed=false image
  for ((index = 0; index < ${#source_images[@]}; index++)); do
    image="${source_images[index]}"
    [[ "${image}" == *@* ]] && continue
    if ! docker tag "${previous_image_ids[index]}" "${image}"; then
      echo "恢复 ${services[index]} 旧镜像标签失败。" >&2
      failed=true
    fi
  done
  [[ "${failed}" == false ]]
}

bundle_exit_handler() {
  local status=$? rollback_failed=false
  trap - EXIT
  if [[ "${bundle_transaction_active}" == true && "${bundle_transaction_committed}" != true ]]; then
    set +e
    echo "离线升级未完成，正在恢复原始配置。数据库不会自动回退。" >&2
    restore_bundle_files || rollback_failed=true
    restore_original_process_environment
    if [[ "${bundle_image_mutation_started}" == true ]]; then
      restore_previous_image_tags_for_bundle || rollback_failed=true
    fi
    if [[ "${bundle_candidate_attempted}" == true ]]; then
      compose_apply || rollback_failed=true
      if [[ "${rollback_failed}" == true ]]; then
        status=11
        echo "离线升级失败，且旧版本健康检查未通过，需要人工处理。" >&2
      else
        status=10
        echo "离线升级失败，旧配置和旧镜像已恢复并通过健康检查。" >&2
      fi
    elif [[ "${rollback_failed}" == true ]]; then
      status=11
    fi
    if [[ -n "${bundle_database_backup}" ]]; then
      echo "升级前数据库备份已保留：${bundle_database_backup}；仅在评估迁移兼容性后人工恢复。" >&2
    fi
  fi
  cleanup_bundle_snapshot
  exit "${status}"
}

create_bundle_database_backup() {
  local backup_dir="${project_root}/backups" timestamp backup_path backup_temporary container_id container_temporary
  assert_safe_deployment_path "${backup_dir}" "数据库备份目录" || return 1
  if [[ -e "${backup_dir}" ]]; then
    [[ -d "${backup_dir}" && ! -L "${backup_dir}" ]] || { echo "数据库备份路径不是安全目录：${backup_dir}" >&2; return 1; }
  else
    mkdir -p -- "${backup_dir}" || return 1
    chmod 700 "${backup_dir}" || return 1
  fi
  assert_safe_deployment_path "${backup_dir}" "数据库备份目录" || return 1
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_path="${backup_dir}/xingchen-monitor-${timestamp}.sql"
  assert_safe_deployment_path "${backup_path}" "数据库备份文件" || return 1
  [[ ! -e "${backup_path}" ]] || { echo "数据库备份文件已存在，拒绝覆盖：${backup_path}" >&2; return 1; }
  backup_temporary="$(mktemp "${backup_dir}/.controller-update-backup.XXXXXX")" || return 1
  assert_safe_deployment_path "${backup_temporary}" "数据库备份临时文件" || { rm -f -- "${backup_temporary}"; return 1; }
  chmod 600 "${backup_temporary}" || { rm -f -- "${backup_temporary}"; return 1; }
  container_id="$(docker compose "${compose_args[@]}" ps -q postgres 2>/dev/null || true)"
  if [[ -z "${container_id}" ]]; then
    rm -f -- "${backup_temporary}"
    echo "未找到运行中的 PostgreSQL 容器，离线升级已停止。" >&2
    return 1
  fi
  container_temporary="/tmp/xingchen-controller-update-${timestamp}-${$}.sql"
  if ! run_with_timeout "${compose_timeout_seconds}" docker compose "${compose_args[@]}" exec -T postgres sh -ec \
    'export PGPASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}"; pg_dump --format=plain --no-owner --no-privileges --username="${POSTGRES_USER:-xingchen}" --dbname="${POSTGRES_DB:-xingchen_monitor}" --file="$1"' sh "${container_temporary}"; then
    docker compose "${compose_args[@]}" exec -T postgres rm -f -- "${container_temporary}" >/dev/null 2>&1 || true
    rm -f -- "${backup_temporary}"
    echo "升级前 PostgreSQL 备份失败，未加载任何新镜像。" >&2
    return 1
  fi
  if ! run_with_timeout "${compose_timeout_seconds}" docker cp "${container_id}:${container_temporary}" "${backup_temporary}"; then
    docker compose "${compose_args[@]}" exec -T postgres rm -f -- "${container_temporary}" >/dev/null 2>&1 || true
    rm -f -- "${backup_temporary}"
    echo "无法从 PostgreSQL 容器复制升级前备份，未加载任何新镜像。" >&2
    return 1
  fi
  docker compose "${compose_args[@]}" exec -T postgres rm -f -- "${container_temporary}" >/dev/null 2>&1 \
    || echo "警告：无法清理 PostgreSQL 容器内的临时备份 ${container_temporary}。" >&2
  if ! chmod 600 "${backup_temporary}" || [[ ! -s "${backup_temporary}" ]]; then
    rm -f -- "${backup_temporary}"
    echo "PostgreSQL 升级前备份为空，离线升级已停止。" >&2
    return 1
  fi
  mv -- "${backup_temporary}" "${backup_path}" || { rm -f -- "${backup_temporary}"; return 1; }
  bundle_database_backup="${backup_path}"
  echo "升级前数据库备份已创建：${bundle_database_backup}"
}

verify_loaded_bundle_images() {
  local image actual_arch
  local release_images=(
    "ghcr.io/pstarchen/monitor-for-server-setup:${bundle_version}"
    "ghcr.io/pstarchen/monitor-for-server-server:${bundle_version}"
    "ghcr.io/pstarchen/monitor-for-server-web:${bundle_version}"
    "ghcr.io/pstarchen/monitor-for-server-agent:${bundle_version}"
  )
  for image in "${release_images[@]}"; do
    actual_arch="$(docker image inspect --format '{{.Architecture}}' "${image}" 2>/dev/null || true)"
    if [[ "${actual_arch}" != "${bundle_arch}" ]] || ! verify_image_version "${image}"; then
      echo "离线 bundle 导入后镜像缺失或版本不匹配：${image}" >&2
      return 1
    fi
  done
  for image in postgres:16-alpine redis:7.4-alpine; do
    actual_arch="$(docker image inspect --format '{{.Architecture}}' "${image}" 2>/dev/null || true)"
    if [[ "${actual_arch}" != "${bundle_arch}" ]]; then
      echo "离线 bundle 导入后基础镜像缺失：${image}" >&2
      return 1
    fi
  done
}

bundle_release_matches() {
  local relative source_path target_path existing
  [[ -d "${bundle_release_target}" && ! -L "${bundle_release_target}" ]] || return 1
  for relative in "${!bundle_verified[@]}"; do
    [[ "${relative}" == release/* ]] || continue
    source_path="${offline_bundle}/${relative}"
    target_path="${bundle_release_target}/${relative#release/}"
    [[ -f "${target_path}" && ! -L "${target_path}" ]] || return 1
    cmp -s -- "${source_path}" "${target_path}" || return 1
  done
  while IFS= read -r -d '' existing; do
    [[ ! -L "${existing}" ]] || return 1
    relative="release/${existing#"${bundle_release_target}/"}"
    [[ "${bundle_verified[${relative}]:-}" == true ]] || return 1
  done < <(find "${bundle_release_target}" \( -type f -o -type l \) -print0)
}

stage_bundle_release() {
  local release_root="${project_root}/release/versions" relative destination copied=0
  assert_safe_deployment_path "${release_root}" "版本化发布目录" || return 1
  mkdir -p -- "${release_root}" || return 1
  assert_safe_deployment_path "${release_root}" "版本化发布目录" || return 1
  [[ -d "${release_root}" && ! -L "${release_root}" ]] || { echo "版本化发布路径不是安全目录：${release_root}" >&2; return 1; }
  bundle_release_target="${release_root}/${bundle_version}"
  assert_safe_deployment_path "${bundle_release_target}" "版本化发布目标" || return 1
  if [[ -e "${bundle_release_target}" ]]; then
    bundle_release_matches || { echo "现有版本化发布目录与受校验 bundle 不一致：${bundle_release_target}" >&2; return 1; }
    return 0
  fi
  bundle_release_stage="$(mktemp -d "${release_root}/.${bundle_version}.XXXXXX")" || return 1
  assert_safe_deployment_path "${bundle_release_stage}" "版本化发布暂存目录" || return 1
  chmod 755 "${bundle_release_stage}" || return 1
  for relative in "${!bundle_verified[@]}"; do
    [[ "${relative}" == release/* ]] || continue
    destination="${bundle_release_stage}/${relative#release/}"
    assert_safe_deployment_path "${destination}" "版本化发布制品" || return 1
    mkdir -p -- "$(dirname -- "${destination}")" || return 1
    assert_safe_deployment_path "$(dirname -- "${destination}")" "版本化发布制品目录" || return 1
    cp -- "${offline_bundle}/${relative}" "${destination}" || return 1
    chmod 644 "${destination}" || return 1
    ((copied += 1))
  done
  ((copied > 0)) || { echo "离线 bundle 未包含发布制品。" >&2; return 1; }
  mv -- "${bundle_release_stage}" "${bundle_release_target}" || return 1
  bundle_release_stage=""
  bundle_release_created=true
}

install_bundle_file() {
  local source="$1" target="$2" mode_value="$3" temporary
  assert_safe_deployment_path "${target}" "离线升级文件目标" || return 1
  mkdir -p -- "$(dirname -- "${target}")" || return 1
  assert_safe_deployment_path "$(dirname -- "${target}")" "离线升级文件目录" || return 1
  temporary="$(mktemp "${target}.new.XXXXXX")" || return 1
  assert_safe_deployment_path "${temporary}" "离线升级临时文件" || { rm -f -- "${temporary}"; return 1; }
  if ! cp -- "${source}" "${temporary}" || ! chmod "${mode_value}" "${temporary}" || ! mv -f -- "${temporary}" "${target}"; then
    rm -f -- "${temporary}"
    return 1
  fi
}

switch_bundle_files() {
  stage_bundle_release || return 1
  install_bundle_file "${offline_bundle}/docker-compose.yml" "${project_root}/docker-compose.yml" 644 || return 1
  install_bundle_file "${offline_bundle}/deploy/update-controller.sh" "${project_root}/deploy/update-controller.sh" 755 || return 1
  install_bundle_file "${offline_bundle}/deploy/update-controller.ps1" "${project_root}/deploy/update-controller.ps1" 644 || return 1
}

persist_bundle_settings() {
  local manifest_hash manifest_path offline_path index key
  local setting_keys=(
    XINGCHEN_TARGET_VERSION
    XINGCHEN_SETUP_IMAGE XINGCHEN_SERVER_IMAGE XINGCHEN_WEB_IMAGE XINGCHEN_AGENT_IMAGE
    XINGCHEN_POSTGRES_IMAGE XINGCHEN_REDIS_IMAGE
    XINGCHEN_RELEASE_MANIFEST_PATH XINGCHEN_RELEASE_MANIFEST_SHA256 XINGCHEN_AGENT_OFFLINE_DIR
    XINGCHEN_RELEASE_MANIFEST_URLS XINGCHEN_AGENT_RELEASE_BASE_URLS XINGCHEN_CONTROLLER_ALLOW_GITHUB_API
    XINGCHEN_NETWORK_MODE XINGCHEN_ALLOW_GITEE
  )
  manifest_hash="$(sha256sum "${offline_bundle}/release/manifest.json" | awk '{print $1}')" || return 1
  manifest_path="/workspace/release/versions/${bundle_version}/manifest.json"
  offline_path="/workspace/release/versions/${bundle_version}/assets"
  local setting_values=(
    "${bundle_version}"
    "ghcr.io/pstarchen/monitor-for-server-setup:${bundle_version}"
    "ghcr.io/pstarchen/monitor-for-server-server:${bundle_version}"
    "ghcr.io/pstarchen/monitor-for-server-web:${bundle_version}"
    "ghcr.io/pstarchen/monitor-for-server-agent:${bundle_version}"
    postgres:16-alpine redis:7.4-alpine
    "${manifest_path}" "${manifest_hash}" "${offline_path}"
    "" "" false
    offline false
  )
  local settings=()
  for ((index = 0; index < ${#setting_keys[@]}; index++)); do
    settings+=("${setting_keys[index]}" "${setting_values[index]}")
  done
  set_env_values "${settings[@]}" || return 1
  for ((index = 0; index < ${#setting_keys[@]}; index++)); do
    key="${setting_keys[index]}"
    printf -v "${key}" '%s' "${setting_values[index]}"
    export "${key}"
  done
}

finish_bundle_transaction() {
  bundle_transaction_committed=true
  bundle_transaction_active=false
  trap - EXIT
  cleanup_bundle_snapshot
}

configure_auto_update() {
  if [[ ! -f "${project_root}/.env" ]]; then
    echo "Controller .env is missing; complete installation first." >&2
    exit 1
  fi
  set_env_value CONTROLLER_AUTO_UPDATE true
  if [[ "$(uname -s)" == "Linux" && "${EUID}" -eq 0 ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now xingchen-controller-update.timer >/dev/null 2>&1 || true
    systemctl disable --now guanlan-controller-update.timer >/dev/null 2>&1 || true
  fi
  run_with_timeout "${compose_timeout_seconds}" docker compose "${compose_args[@]}" up -d --no-deps --wait --wait-timeout 300 setup
  echo "总控自动更新已启用：每天 04:00 按 APP_TIMEZONE 执行。"
}

if [[ "${mode}" == auto ]]; then
  ensure_compose_project_name
  configure_auto_update
  exit 0
fi

if [[ -n "${offline_bundle}" ]]; then
  if ! begin_bundle_transaction; then
    cleanup_bundle_snapshot
    exit 1
  fi
fi
ensure_compose_project_name

previous_image_ids=()
previous_target_setting="$(read_env_value XINGCHEN_TARGET_VERSION)"
snapshot_previous_images() {
  local index container_id image_id
  previous_image_ids=()
  for ((index = 0; index < ${#services[@]}; index++)); do
    container_id="$(docker compose "${compose_args[@]}" ps -q "${services[index]}" 2>/dev/null || true)"
    image_id=""
    if [[ -n "${container_id}" ]]; then
      image_id="$(docker inspect --format '{{.Image}}' "${container_id}" 2>/dev/null || true)"
    fi
    if [[ -z "${image_id}" ]]; then
      image_id="$(docker image inspect --format '{{.Id}}' "${source_images[index]}" 2>/dev/null || true)"
    fi
    if [[ -z "${image_id}" ]]; then
      echo "无法记录 ${services[index]} 的旧镜像，更新未开始。" >&2
      return 1
    fi
    previous_image_ids+=("${image_id}")
  done
}

persist_images() {
  local include_target="$1" target_setting="$2" index key image
  shift 2
  local images=("$@") settings=()
  if ((${#images[@]} != ${#image_keys[@]})); then
    echo "内部错误：镜像设置数量不匹配。" >&2
    return 1
  fi
  for ((index = 0; index < ${#image_keys[@]}; index++)); do
    key="${image_keys[index]}"
    image="${images[index]}"
    settings+=("${key}" "${image}")
  done
  if [[ "${include_target}" == true ]]; then
    settings+=(XINGCHEN_TARGET_VERSION "${target_setting}")
  fi
  set_env_values "${settings[@]}"
  for ((index = 0; index < ${#image_keys[@]}; index++)); do
    key="${image_keys[index]}"
    image="${images[index]}"
    printf -v "${key}" '%s' "${image}"
    export "${key}"
  done
  if [[ "${include_target}" == true ]]; then
    XINGCHEN_TARGET_VERSION="${target_setting}"
    export XINGCHEN_TARGET_VERSION
  fi
}

compose_apply() {
  local args=(up -d --force-recreate --wait --wait-timeout 300)
  if [[ "${offline}" == true ]]; then
    args+=(--pull never)
  fi
  if [[ "${CONTROLLER_UPDATE_RUNNER:-false}" != true ]]; then
    args+=(--remove-orphans)
  fi
  run_with_timeout "${compose_timeout_seconds}" docker compose "${compose_args[@]}" "${args[@]}" "${services[@]}"
}

restore_previous_images() {
  local index failed=false image rollback_image
  local rollback_images=()
  for ((index = 0; index < ${#source_images[@]}; index++)); do
    image="${source_images[index]}"
    rollback_image="${image}"
    if [[ "${image}" == *@* ]]; then
      rollback_image="xingchen-controller-rollback-${services[index]}:${$}"
    fi
    rollback_images+=("${rollback_image}")
    if ! docker tag "${previous_image_ids[index]}" "${rollback_image}"; then
      echo "恢复 ${services[index]} 旧镜像标签失败。" >&2
      failed=true
    fi
  done
  [[ "${failed}" == false ]] || return 1
  persist_images true "${previous_target_setting}" "${rollback_images[@]}"
  compose_apply
}

if [[ "${mode}" == apply ]]; then
  snapshot_previous_images
fi

if [[ -n "${offline_bundle}" ]]; then
  create_bundle_database_backup
  bundle_image_mutation_started=true
  if ! run_with_timeout "${compose_timeout_seconds}" docker load --input "${offline_bundle}/images/controller-images.tar"; then
    echo "离线总控镜像导入失败。" >&2
    exit 1
  fi
  verify_loaded_bundle_images
  switch_bundle_files
  persist_bundle_settings
  bundle_candidate_attempted=true
  if ! compose_apply; then
    echo "离线总控候选版本健康检查失败。" >&2
    exit 1
  fi
  finish_bundle_transaction
  echo "总控已从离线 bundle 更新到 ${bundle_version}；数据库备份保留在 ${bundle_database_backup}。"
  exit 0
fi

if [[ "${offline}" == true ]]; then
  verify_local_images
elif [[ "${build}" == true && "${source_build}" == true ]]; then
  echo "--build 与 --source-build 不能同时使用。" >&2
  exit 2
elif [[ "${build}" == true ]]; then
  prepare_dependency_images
  echo "使用本地源码构建总控镜像..."
  compose_build_args=(build)
  [[ "${network_mode}" == public ]] && compose_build_args+=(--pull)
  compose_build_args+=("${services[@]}")
  run_with_timeout "${compose_timeout_seconds}" docker compose "${compose_args[@]}" "${compose_build_args[@]}"
elif [[ "${source_build}" == true ]]; then
  prepare_dependency_images
  build_images_from_repositories
else
  prepare_dependency_images
  if ! pull_images; then
    if [[ "${source_fallback}" != true ]]; then
      echo "总控镜像拉取失败，且源码构建回退已关闭。" >&2
      exit 1
    fi
    echo "所有总控镜像源均不可用，开始从已配置的源码仓库构建 Docker 镜像。"
    build_images_from_repositories
  fi
fi

verify_prepared_images

if [[ "${mode}" == check ]]; then
  echo "总控镜像检查完成；如需使新镜像生效，请运行：sudo $0 --apply"
  exit 0
fi

if [[ -n "${target_version}" ]]; then
  persist_images true "${target_version}" "${candidate_images[@]}"
else
  persist_images false "" "${candidate_images[@]}"
fi

if ! compose_apply; then
  echo "总控健康检查失败，正在恢复更新前镜像。数据库不会自动回退。" >&2
  if restore_previous_images; then
    echo "总控镜像已恢复并通过健康检查；如新版本执行过数据库迁移，请人工确认数据库兼容性。" >&2
    exit 10
  fi
  echo "总控镜像自动恢复失败，需要人工处理；不要在未评估迁移兼容性前恢复数据库备份。" >&2
  exit 11
fi
echo "总控服务已更新并重启。"
