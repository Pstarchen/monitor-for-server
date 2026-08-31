#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: update-controller.sh [--check|--apply|--auto] [--build] [--no-mirror]

  --check       pull candidate images and report that an update is ready.
  --apply       pull images and restart the controller services.
  --auto        enable the controller's daily 04:00 automatic update.
  --build       build from local source instead of pulling images.
  --no-mirror   skip configured mainland-China mirror registries.
USAGE
}

mode=check
build=false
use_mirror=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) mode=check; shift ;;
    --apply) mode=apply; shift ;;
    --auto) mode=auto; shift ;;
    --build) build=true; shift ;;
    --no-mirror) use_mirror=false; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "${script_dir}/.." && pwd)"
cd "${project_root}"

# Registry downloads can legitimately take several minutes on a constrained link.
# Keep the timeout finite, configurable, and aligned with the Windows updater.
pull_timeout_seconds="${GUANLAN_UPDATE_PULL_TIMEOUT_SECONDS:-180}"
compose_timeout_seconds="${GUANLAN_UPDATE_COMPOSE_TIMEOUT_SECONDS:-900}"
if [[ ! "${pull_timeout_seconds}" =~ ^[1-9][0-9]*$ || ! "${compose_timeout_seconds}" =~ ^[1-9][0-9]*$ ]]; then
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

read_env_value() {
  local key="$1"
  awk -v key="${key}" 'index($0, key "=") == 1 {value=substr($0, length(key) + 2); gsub(/^"|"$/, "", value); print value; exit}' .env 2>/dev/null || true
}

compose_args=()
controller_agent_enabled="${CONTROLLER_AGENT_ENABLED:-}"
if [[ -z "${controller_agent_enabled}" && -f .env ]]; then
  controller_agent_enabled="$(read_env_value CONTROLLER_AGENT_ENABLED)"
fi
if [[ "$(uname -s)" == "Linux" && "${controller_agent_enabled,,}" == "true" ]]; then
  compose_args+=(--profile host-monitoring)
fi
compose_project_root="${GUANLAN_HOST_PROJECT_ROOT:-${project_root}}"
compose_args+=(-f "${project_root}/docker-compose.yml" --project-directory "${compose_project_root}" --env-file "${project_root}/.env")
services=(setup server web)
if [[ "$(uname -s)" == "Linux" && "${controller_agent_enabled,,}" == "true" ]]; then
  services+=(controller-agent)
fi

image_value() {
  local name="$1" default="$2" value
  value="${!name:-}"
  if [[ -z "${value}" && -f .env ]]; then
    value="$(read_env_value "${name}")"
  fi
  printf '%s' "${value:-${default}}"
}

pull_one() {
  local image="$1"
  local suffix prefix candidate
  if [[ "${use_mirror}" == true && "${image}" == ghcr.io/* ]]; then
    suffix="${image#ghcr.io/}"
    local mirror_list="${GUANLAN_CONTROLLER_IMAGE_MIRRORS:-}"
    if [[ -z "${mirror_list}" && -f .env ]]; then
      mirror_list="$(read_env_value GUANLAN_CONTROLLER_IMAGE_MIRRORS)"
    fi
    IFS=',' read -r -a prefixes <<< "${mirror_list:-ghcr.1ms.run,ghcr.nju.edu.cn}"
    for prefix in "${prefixes[@]}"; do
      prefix="${prefix%/}"
      [[ -z "${prefix}" ]] && continue
      candidate="${prefix}/${suffix}"
      echo "尝试国内镜像源：${candidate}"
      if run_with_timeout "${pull_timeout_seconds}" docker pull "${candidate}" >/dev/null && run_with_timeout "${pull_timeout_seconds}" docker tag "${candidate}" "${image}"; then
        return 0
      fi
    done
  fi
  echo "尝试官方镜像源：${image}"
  run_with_timeout "${pull_timeout_seconds}" docker pull "${image}"
}

pull_images() {
  local image
  pull_one "$(image_value GUANLAN_SETUP_IMAGE ghcr.io/pstarchen/monitor-for-server-setup:latest)"
  pull_one "$(image_value GUANLAN_SERVER_IMAGE ghcr.io/pstarchen/monitor-for-server-server:latest)"
  pull_one "$(image_value GUANLAN_WEB_IMAGE ghcr.io/pstarchen/monitor-for-server-web:latest)"
  if [[ "$(uname -s)" == "Linux" && "${controller_agent_enabled,,}" == "true" ]]; then
    pull_one "$(image_value GUANLAN_AGENT_IMAGE ghcr.io/pstarchen/monitor-for-server-agent:latest)"
  fi
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

if [[ "${build}" == true ]]; then
  echo "使用本地源码构建总控镜像..."
  run_with_timeout "${compose_timeout_seconds}" docker compose "${compose_args[@]}" build --pull "${services[@]}"
else
  pull_images
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
