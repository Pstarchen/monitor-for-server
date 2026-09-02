#!/usr/bin/env bash
set -euo pipefail

# XINGCHEN_* is the public configuration namespace. Read the old namespace
# once for compatibility with existing .env files and command invocations.
for suffix in UPDATE_PULL_TIMEOUT_SECONDS UPDATE_MIRROR_TIMEOUT_SECONDS UPDATE_COMPOSE_TIMEOUT_SECONDS TARGET_VERSION SOURCE_REF SOURCE_BUILD_TIMEOUT_SECONDS SOURCE_REPOSITORIES HOST_PROJECT_ROOT SETUP_IMAGE SERVER_IMAGE WEB_IMAGE AGENT_IMAGE CONTROLLER_IMAGE_MIRRORS; do
  primary="XINGCHEN_${suffix}"
  legacy="GUANLAN_${suffix}"
  if [[ -z "${!primary:-}" && -n "${!legacy:-}" ]]; then
    export "${primary}=${!legacy}"
  fi
done

usage() {
  cat <<'USAGE'
Usage: update-controller.sh [--check|--apply|--auto] [--build|--source-build] [--no-mirror] [--no-source-fallback]

  --check       pull candidate images and report that an update is ready.
  --apply       pull images and restart the controller services.
  --auto        enable the controller's daily 04:00 automatic update.
  --build       build from local source instead of pulling images.
  --source-build  build Docker images from Gitee/GitHub source repositories.
  --no-mirror   skip configured mainland-China mirror registries.
  --no-source-fallback  fail instead of building from source when all image registries are unavailable.
USAGE
}

mode=check
build=false
source_build=false
source_fallback=true
use_mirror=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) mode=check; shift ;;
    --apply) mode=apply; shift ;;
    --auto) mode=auto; shift ;;
    --build) build=true; shift ;;
    --source-build) source_build=true; shift ;;
    --no-mirror) use_mirror=false; shift ;;
    --no-source-fallback) source_fallback=false; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "${script_dir}/.." && pwd)"
cd "${project_root}"

read_env_value() {
  local key="$1" value legacy
  value="$(awk -v key="${key}" 'index($0, key "=") == 1 {value=substr($0, length(key) + 2); gsub(/^"|"$/, "", value); print value; exit}' .env 2>/dev/null || true)"
  if [[ -n "${value}" ]]; then
    printf '%s' "${value}"
    return
  fi
  if [[ "${key}" == XINGCHEN_* ]]; then
    legacy="GUANLAN_${key#XINGCHEN_}"
    awk -v key="${legacy}" 'index($0, key "=") == 1 {value=substr($0, length(key) + 2); gsub(/^"|"$/, "", value); print value; exit}' .env 2>/dev/null || true
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
if [[ ! "${pull_timeout_seconds}" =~ ^[1-9][0-9]*$ || ! "${mirror_timeout_seconds}" =~ ^[1-9][0-9]*$ || ! "${compose_timeout_seconds}" =~ ^[1-9][0-9]*$ ]]; then
  echo "更新超时必须是正整数秒数。" >&2
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

lock_file="${project_root}/.controller-update.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"${lock_file}"
  if ! flock -n 9; then
    echo "已有总控更新任务正在执行，请稍后重试。" >&2
    exit 75
  fi
fi

target_version="${XINGCHEN_TARGET_VERSION:-$(read_env_value XINGCHEN_TARGET_VERSION)}"
if [[ -n "${target_version}" ]]; then
  if [[ "${target_version}" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
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
source_build_timeout_seconds="${XINGCHEN_SOURCE_BUILD_TIMEOUT_SECONDS:-$(read_env_value XINGCHEN_SOURCE_BUILD_TIMEOUT_SECONDS)}"
source_build_timeout_seconds="${source_build_timeout_seconds:-1200}"
source_repository_list="${XINGCHEN_SOURCE_REPOSITORIES:-$(read_env_value XINGCHEN_SOURCE_REPOSITORIES)}"
IFS=',' read -r -a source_repositories <<< "${source_repository_list:-https://gitee.com/starchen520/monitor-for-server.git,https://github.com/Pstarchen/monitor-for-server.git}"
if [[ ! "${source_build_timeout_seconds}" =~ ^[1-9][0-9]*$ ]]; then
  echo "XINGCHEN_SOURCE_BUILD_TIMEOUT_SECONDS 必须是正整数秒数。" >&2
  exit 2
fi
if ((${#source_repositories[@]} == 0)) || [[ -z "${source_ref}" || "${source_ref}" == -* || "${source_ref}" == *..* || ! "${source_ref}" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
  echo "总控源码仓库列表或 Git ref 无效。" >&2
  exit 2
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
source_contexts=(setup server web)
if [[ "$(uname -s)" == "Linux" && "${controller_agent_enabled,,}" == "true" ]]; then
  services+=(controller-agent)
  source_contexts+=(agent)
fi

image_value() {
  local name="$1" default="$2" value
  value="${!name:-}"
  if [[ -z "${value}" && -f .env ]]; then
    value="$(read_env_value "${name}")"
  fi
  printf '%s' "${value:-${default}}"
}

source_images=(
  "$(image_value XINGCHEN_SETUP_IMAGE ghcr.io/pstarchen/monitor-for-server-setup:latest)"
  "$(image_value XINGCHEN_SERVER_IMAGE ghcr.io/pstarchen/monitor-for-server-server:latest)"
  "$(image_value XINGCHEN_WEB_IMAGE ghcr.io/pstarchen/monitor-for-server-web:latest)"
)
if [[ "$(uname -s)" == "Linux" && "${controller_agent_enabled,,}" == "true" ]]; then
  source_images+=("$(image_value XINGCHEN_AGENT_IMAGE ghcr.io/pstarchen/monitor-for-server-agent:latest)")
fi

verify_image_version() {
  local image="$1" actual
  [[ -z "${target_version}" ]] && return 0
  actual="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${image}" 2>/dev/null || true)"
  if [[ "${actual#v}" != "${target_version#v}" ]]; then
    echo "镜像版本不匹配：${image} 标记为 ${actual:-unknown}，期望 ${target_version}。" >&2
    return 1
  fi
}

pull_reference() {
  local image="$1"
  if [[ -n "${target_version}" && "${image}" =~ ^ghcr\.io/pstarchen/monitor-for-server-(setup|server|web|agent):latest$ ]]; then
    printf '%s:%s' "${image%:latest}" "${target_version}"
    return
  fi
  printf '%s' "${image}"
}

pull_one() {
  local destination="$1" image
  local suffix prefix candidate
  image="$(pull_reference "${destination}")"
  if [[ "${use_mirror}" == true && "${image}" == ghcr.io/* ]]; then
    suffix="${image#ghcr.io/}"
    local mirror_list="${XINGCHEN_CONTROLLER_IMAGE_MIRRORS:-}"
    if [[ -z "${mirror_list}" && -f .env ]]; then
      mirror_list="$(read_env_value XINGCHEN_CONTROLLER_IMAGE_MIRRORS)"
    fi
    IFS=',' read -r -a prefixes <<< "${mirror_list:-ghcr.1ms.run,ghcr.nju.edu.cn}"
    for prefix in "${prefixes[@]}"; do
      prefix="${prefix%/}"
      [[ -z "${prefix}" ]] && continue
      candidate="${prefix}/${suffix}"
      echo "尝试国内镜像源：${candidate}"
      if run_with_timeout "${mirror_timeout_seconds}" docker pull "${candidate}" >/dev/null && verify_image_version "${candidate}" && run_with_timeout "${mirror_timeout_seconds}" docker tag "${candidate}" "${destination}"; then
        return 0
      fi
    done
  fi
  echo "尝试官方镜像源：${image}"
  if ! run_with_timeout "${pull_timeout_seconds}" docker pull "${image}" || ! verify_image_version "${image}"; then
    return 1
  fi
  if [[ "${image}" != "${destination}" ]]; then
    run_with_timeout "${pull_timeout_seconds}" docker tag "${image}" "${destination}"
  fi
}

pull_images() {
  local image failed=false
  for image in "${source_images[@]}"; do
    if ! pull_one "${image}"; then
      failed=true
    fi
  done
  [[ "${failed}" == false ]]
}

remove_source_build_images() {
  local temporary_image
  for temporary_image in "$@"; do
    docker image rm -f "${temporary_image}" >/dev/null 2>&1 || true
  done
}

build_images_from_repositories() {
  local repository context temporary_image
  local index success
  local build_prefix="xingchen-controller-source-$$-${RANDOM}"
  local temporary_images=()
  for image in "${source_images[@]}"; do
    if [[ "${image}" == *@* ]]; then
      echo "固定摘要镜像无法使用源码构建回退：${image}" >&2
      return 1
    fi
  done
  for repository in "${source_repositories[@]}"; do
    temporary_images=()
    success=true
    echo "正在尝试总控源码仓库：${repository} (${source_ref})"
    for ((index = 0; index < ${#source_contexts[@]}; index++)); do
      context="${repository}#${source_ref}:${source_contexts[index]}"
      temporary_image="${build_prefix}-${index}:candidate"
      temporary_images+=("${temporary_image}")
      if ! run_with_timeout "${source_build_timeout_seconds}" docker build --pull --tag "${temporary_image}" "${context}"; then
        success=false
        break
      fi
    done
    if [[ "${success}" == true ]]; then
      for ((index = 0; index < ${#source_images[@]}; index++)); do
        docker tag "${temporary_images[index]}" "${source_images[index]}"
      done
      remove_source_build_images "${temporary_images[@]}"
      return 0
    fi
    remove_source_build_images "${temporary_images[@]}"
  done
  echo "GitHub 与 Gitee 总控源码均无法完成 Docker 构建。" >&2
  return 1
}

set_env_value() {
  local key="$1" value="$2" temporary
  temporary="$(mktemp "${project_root}/.env.controller-update.XXXXXX")"
  awk -v key="${key}" -v value="${value}" '
    BEGIN { found = 0 }
    index($0, key "=") == 1 { print key "=\"" value "\""; found = 1; next }
    { print }
    END { if (!found) print key "=\"" value "\"" }
  ' "${project_root}/.env" > "${temporary}"
  chmod 600 "${temporary}"
  mv "${temporary}" "${project_root}/.env"
}

configure_auto_update() {
  if [[ ! -f "${project_root}/.env" ]]; then
    echo "Controller .env is missing; complete installation first." >&2
    exit 1
  fi
  set_env_value CONTROLLER_AUTO_UPDATE true
  if [[ "$(uname -s)" == "Linux" && "${EUID}" -eq 0 ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now guanlan-controller-update.timer >/dev/null 2>&1 || true
  fi
  run_with_timeout "${compose_timeout_seconds}" docker compose "${compose_args[@]}" up -d --no-deps --wait --wait-timeout 300 setup
  echo "总控自动更新已启用：每天 04:00 按 APP_TIMEZONE 执行。"
}

if [[ "${mode}" == auto ]]; then
  configure_auto_update
  exit 0
fi

if [[ "${build}" == true && "${source_build}" == true ]]; then
  echo "--build 与 --source-build 不能同时使用。" >&2
  exit 2
elif [[ "${build}" == true ]]; then
  echo "使用本地源码构建总控镜像..."
  run_with_timeout "${compose_timeout_seconds}" docker compose "${compose_args[@]}" build --pull "${services[@]}"
elif [[ "${source_build}" == true ]]; then
  build_images_from_repositories
else
  if ! pull_images; then
    if [[ "${source_fallback}" != true ]]; then
      echo "总控镜像拉取失败，且源码构建回退已关闭。" >&2
      exit 1
    fi
    echo "所有总控镜像源均不可用，开始从 Gitee/GitHub 源码构建 Docker 镜像。"
    build_images_from_repositories
  fi
fi

if [[ "${mode}" == check ]]; then
  echo "总控镜像检查完成；如需使新镜像生效，请运行：sudo $0 --apply"
  exit 0
fi

compose_up_args=(up -d --force-recreate --wait --wait-timeout 300)
if [[ "${CONTROLLER_UPDATE_RUNNER:-false}" != true ]]; then
  compose_up_args+=(--remove-orphans)
fi
run_with_timeout "${compose_timeout_seconds}" docker compose "${compose_args[@]}" "${compose_up_args[@]}" "${services[@]}"
echo "总控服务已更新并重启。"
