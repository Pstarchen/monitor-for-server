#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: update-controller.sh [--check|--apply|--auto] [--build] [--no-mirror]

  --check       pull candidate images and report that an update is ready.
  --apply       pull images and restart the controller services.
  --auto        install a daily systemd timer which runs --apply.
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

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Docker Engine and Docker Compose v2 are required." >&2
  exit 1
fi

read_env_value() {
  local key="$1"
  awk -v key="${key}" 'index($0, key "=") == 1 {value=substr($0, length(key) + 2); gsub(/^"|"$/, "", value); print value; exit}' .env 2>/dev/null || true
}

compose_args=()
if [[ "$(uname -s)" == "Linux" ]]; then
  compose_args+=(--profile host-monitoring)
fi
compose_args+=(--project-directory "${project_root}" --env-file "${project_root}/.env")
services=(setup server web)
if [[ "$(uname -s)" == "Linux" ]]; then
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
    IFS=',' read -r -a prefixes <<< "${mirror_list:-ghcr.nju.edu.cn,ghcr.m.daocloud.io,ghcr.1ms.run}"
    for prefix in "${prefixes[@]}"; do
      prefix="${prefix%/}"
      [[ -z "${prefix}" ]] && continue
      candidate="${prefix}/${suffix}"
      echo "尝试国内镜像源：${candidate}"
      if docker pull "${candidate}" >/dev/null && docker tag "${candidate}" "${image}"; then
        return 0
      fi
    done
  fi
  echo "尝试官方镜像源：${image}"
  docker pull "${image}"
}

pull_images() {
  local image
  pull_one "$(image_value GUANLAN_SETUP_IMAGE ghcr.io/pstarchen/monitor-for-server-setup:latest)"
  pull_one "$(image_value GUANLAN_SERVER_IMAGE ghcr.io/pstarchen/monitor-for-server-server:latest)"
  pull_one "$(image_value GUANLAN_WEB_IMAGE ghcr.io/pstarchen/monitor-for-server-web:latest)"
  if [[ "$(uname -s)" == "Linux" ]]; then
    pull_one "$(image_value GUANLAN_AGENT_IMAGE ghcr.io/pstarchen/monitor-for-server-agent:latest)"
  fi
}

install_auto_timer() {
  if [[ "$(uname -s)" != "Linux" || "${EUID}" -ne 0 ]]; then
    echo "--auto currently requires a Linux root shell with systemd." >&2
    exit 1
  fi
  local service=/etc/systemd/system/guanlan-controller-update.service
  local timer=/etc/systemd/system/guanlan-controller-update.timer
  printf '%s\n' '[Unit]' 'Description=Update Guanlan controller images' 'After=docker.service network-online.target' 'Wants=network-online.target' '' '[Service]' 'Type=oneshot' "WorkingDirectory=${project_root}" "ExecStart=${script_dir}/update-controller.sh --apply" > "${service}"
  printf '%s\n' '[Unit]' 'Description=Daily Guanlan controller image update' '' '[Timer]' 'OnCalendar=*-*-* 04:00' 'RandomizedDelaySec=45m' 'Persistent=true' 'Unit=guanlan-controller-update.service' '' '[Install]' 'WantedBy=timers.target' > "${timer}"
  systemctl daemon-reload
  systemctl enable --now guanlan-controller-update.timer >/dev/null
  echo "总控自动更新已启用：systemctl status guanlan-controller-update.timer"
}

if [[ "${mode}" == auto ]]; then
  install_auto_timer
  exit 0
fi

if [[ "${build}" == true ]]; then
  echo "使用本地源码构建总控镜像..."
  docker compose "${compose_args[@]}" build --pull "${services[@]}"
else
  pull_images
fi

if [[ "${mode}" == check ]]; then
  echo "总控镜像检查完成；如需使新镜像生效，请运行：sudo $0 --apply"
  exit 0
fi

docker compose "${compose_args[@]}" up -d --remove-orphans "${services[@]}"
echo "总控服务已更新并重启。"
