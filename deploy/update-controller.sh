#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: update-controller.sh [--check|--apply|--auto] [--build|--source-build] [--offline] [--no-mirror] [--no-source-fallback]

  --check       pull candidate images and report that an update is ready.
  --apply       pull images and restart the controller services.
  --auto        enable the controller's daily 04:00 automatic update.
  --build       build from local source instead of pulling images.
  --source-build  build Docker images from Gitee/GitHub source repositories.
  --offline     use only images that are already loaded in the local Docker engine.
  --no-mirror   skip configured mainland-China mirror registries.
  --no-source-fallback  fail instead of building from source when all image registries are unavailable.
USAGE
}

mode=check
build=false
source_build=false
source_fallback=true
use_mirror=true
offline=false
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
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "${offline}" == true && ( "${build}" == true || "${source_build}" == true || "${mode}" == auto ) ]]; then
  echo "--offline 不能与 --build、--source-build 或 --auto 同时使用。" >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "${script_dir}/.." && pwd)"
cd "${project_root}"

read_env_value() {
  local key="$1" value
  value="$(awk -v key="${key}" 'index($0, key "=") == 1 {value=substr($0, length(key) + 2); gsub(/^"|"$/, "", value); print value; exit}' .env 2>/dev/null || true)"
  printf '%s' "${value}"
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
if ! command -v flock >/dev/null 2>&1; then
  echo "总控更新需要 flock 提供跨进程互斥；请先安装 util-linux。" >&2
  exit 1
fi
exec 9>"${lock_file}"
if ! flock -n 9; then
  echo "已有总控更新任务正在执行，请稍后重试。" >&2
  exit 75
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
if [[ "${offline}" == true && -z "${target_version}" ]]; then
  echo "离线模式要求通过 XINGCHEN_TARGET_VERSION 指定稳定版本。" >&2
  exit 2
fi
source_build_timeout_seconds="${XINGCHEN_SOURCE_BUILD_TIMEOUT_SECONDS:-$(read_env_value XINGCHEN_SOURCE_BUILD_TIMEOUT_SECONDS)}"
source_build_timeout_seconds="${source_build_timeout_seconds:-1200}"
source_repository_list="${XINGCHEN_SOURCE_REPOSITORIES:-$(read_env_value XINGCHEN_SOURCE_REPOSITORIES)}"
IFS=',' read -r -a source_repositories <<< "${source_repository_list:-https://gitee.com/starchen520/monitor-for-server.git}"
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

image_keys=(XINGCHEN_SETUP_IMAGE XINGCHEN_SERVER_IMAGE XINGCHEN_WEB_IMAGE)
source_images=(
  "$(image_value XINGCHEN_SETUP_IMAGE ghcr.io/pstarchen/monitor-for-server-setup:v1.20.12)"
  "$(image_value XINGCHEN_SERVER_IMAGE ghcr.io/pstarchen/monitor-for-server-server:v1.20.12)"
  "$(image_value XINGCHEN_WEB_IMAGE ghcr.io/pstarchen/monitor-for-server-web:v1.20.12)"
)
if [[ "$(uname -s)" == "Linux" && "${controller_agent_enabled,,}" == "true" ]]; then
  image_keys+=(XINGCHEN_AGENT_IMAGE)
  source_images+=("$(image_value XINGCHEN_AGENT_IMAGE ghcr.io/pstarchen/monitor-for-server-agent:v1.20.12)")
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
for source_image in "${source_images[@]}"; do
  candidate_images+=("$(versioned_reference "${source_image}")")
done

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

pull_one() {
  local image="$1"
  local suffix prefix candidate
  if [[ "${use_mirror}" == true && "${image}" == ghcr.io/* ]]; then
    suffix="${image#ghcr.io/}"
    local mirror_list="${XINGCHEN_CONTROLLER_IMAGE_MIRRORS:-}"
    if [[ -z "${mirror_list}" && -f .env ]]; then
      mirror_list="$(read_env_value XINGCHEN_CONTROLLER_IMAGE_MIRRORS)"
    fi
    IFS=',' read -r -a prefixes <<< "${mirror_list}"
    for prefix in "${prefixes[@]}"; do
      prefix="${prefix%/}"
      [[ -z "${prefix}" ]] && continue
      candidate="${prefix}/${suffix}"
      echo "尝试国内镜像源：${candidate}"
      if run_with_timeout "${mirror_timeout_seconds}" docker pull "${candidate}" >/dev/null && verify_image_version "${candidate}" && run_with_timeout "${mirror_timeout_seconds}" docker tag "${candidate}" "${image}"; then
        return 0
      fi
    done
  fi
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
  local repository context temporary_image
  local index success
  local build_prefix="xingchen-controller-source-$$-${RANDOM}"
  local temporary_images=()
  for image in "${candidate_images[@]}"; do
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
      if ! run_with_timeout "${source_build_timeout_seconds}" docker build --pull --build-arg "VERSION=${target_version:-dev}" --tag "${temporary_image}" "${context}" \
        || ! verify_image_version "${temporary_image}"; then
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

if [[ "${offline}" == true ]]; then
  verify_local_images
elif [[ "${build}" == true && "${source_build}" == true ]]; then
  echo "--build 与 --source-build 不能同时使用。" >&2
  exit 2
elif [[ "${build}" == true ]]; then
  prepare_dependency_images
  echo "使用本地源码构建总控镜像..."
  run_with_timeout "${compose_timeout_seconds}" docker compose "${compose_args[@]}" build --pull "${services[@]}"
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
