#!/usr/bin/env bash
set -euo pipefail

manager_root="${XINGCHEN_AGENT_MANAGER_ROOT:-/opt/xingchen/agent}"
manager_path="${manager_root}/agent.sh"
manager_metadata_path="${manager_root}/install.env"
manager_updater_path="${manager_root}/update-agent.sh"
agent_update_status_path="${XINGCHEN_AGENT_UPDATE_STATUS_PATH:-${manager_root}/update-status.json}"
agent_update_status_dir="${agent_update_status_path%/*}"
agent_update_request_dir="${manager_root}/requests"
agent_update_request_path="${agent_update_request_dir}/update-request"
agent_update_request_handler_path="${manager_root}/handle-update-request.sh"
systemd_dir="${XINGCHEN_SYSTEMD_DIR:-/etc/systemd/system}"
agent_service_name="${XINGCHEN_AGENT_SERVICE:-xingchen-agent.service}"
agent_user="${XINGCHEN_AGENT_USER:-xingchen-agent}"
agent_config_dir="${XINGCHEN_AGENT_CONFIG_DIR:-/etc/xingchen-agent}"
agent_config_path="${agent_config_dir}/agent.json"
agent_data_dir="${XINGCHEN_AGENT_DATA_DIR:-/var/lib/xingchen-agent}"
agent_spool_path="${agent_data_dir}/spool"
agent_backup_dir="${agent_data_dir}/backups"
agent_binary_target="${XINGCHEN_AGENT_BINARY:-/usr/local/bin/xingchen-agent}"
agent_update_service_name="${XINGCHEN_AGENT_UPDATE_SERVICE:-xingchen-agent-update.service}"
agent_update_timer_name="${XINGCHEN_AGENT_UPDATE_TIMER:-xingchen-agent-update.timer}"
agent_update_request_service_name="xingchen-agent-update-request.service"
agent_update_request_path_name="xingchen-agent-update-request.path"
legacy_updater_path="${XINGCHEN_LEGACY_AGENT_UPDATER_PATH:-/usr/local/sbin/guanlan-agent-update}"
legacy_installation=false
original_args=("$@")
action="install"
if [[ $# -eq 0 ]]; then
  if [[ -n "${XINGCHEN_SERVER:-${XINGCHEN_SERVER_URL:-}}" && -n "${XINGCHEN_DEVICE_ID:-}" && ( -n "${XINGCHEN_ENROLLMENT_TOKEN:-}" || -n "${XINGCHEN_AGENT_KEY:-}" ) ]]; then
    action="install"
  else
    action="menu"
  fi
elif [[ "$1" =~ ^(install|update|upgrade|rollback|list-versions|versions|restart|status|logs|uninstall|menu)$ ]]; then
  action="$1"
  shift
fi

usage() {
  echo "Usage: XINGCHEN_SERVER=HOST_OR_URL XINGCHEN_DEVICE_ID=ID XINGCHEN_ENROLLMENT_TOKEN=... $0"
  echo "       Legacy automation may provide XINGCHEN_AGENT_KEY instead."
  echo "       $0 install --server-url HOST_OR_URL --device-id ID [安装参数]"
  echo "       [--network-mode public|internal|offline] [--allow-gitee]"
  echo "       [--source-url GIT_URL]... [--source-ref GIT_REF]"
  echo "       $0 update|upgrade|rollback [VERSION] | list-versions"
  echo "       $0 restart|status|logs|uninstall [--purge]"
  echo "       $0 menu"
}

server_url="${XINGCHEN_SERVER:-${XINGCHEN_SERVER_URL:-}}"
device_id="${XINGCHEN_DEVICE_ID:-}"
enrollment_token="${XINGCHEN_ENROLLMENT_TOKEN:-}"
agent_key="${XINGCHEN_AGENT_KEY:-}"
repository_urls=()
if [[ -n "${XINGCHEN_REPOSITORY_URL:-}" ]]; then
  repository_urls+=("${XINGCHEN_REPOSITORY_URL}")
else
  IFS=',' read -r -a repository_urls <<< "${XINGCHEN_REPOSITORY_URLS:-}"
fi
source_url_overridden=false
source_ref="${XINGCHEN_SOURCE_REF:-main}"
source_ref_overridden=false
[[ -n "${XINGCHEN_SOURCE_REF:-}" ]] && source_ref_overridden=true
source_build_timeout="${XINGCHEN_AGENT_SOURCE_BUILD_TIMEOUT_SECONDS:-1800}"
mirror_pull_timeout="${XINGCHEN_UPDATE_MIRROR_TIMEOUT_SECONDS:-45}"
agent_pull_timeout="${XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS:-120}"
agent_image="${XINGCHEN_AGENT_IMAGE:-ghcr.io/pstarchen/monitor-for-server-agent:${XINGCHEN_AGENT_VERSION:-v1.20.15}}"
container_name="${XINGCHEN_AGENT_CONTAINER:-xingchen-agent}"
container_overridden=false
[[ -n "${XINGCHEN_AGENT_CONTAINER:-}" ]] && container_overridden=true
binary_path=""
agent_mode="${XINGCHEN_AGENT_MODE:-native}"
release_repo="${XINGCHEN_AGENT_RELEASE_REPO:-Pstarchen/monitor-for-server}"
release_base_urls="${XINGCHEN_AGENT_RELEASE_BASE_URLS:-}"
release_manifest_urls="${XINGCHEN_RELEASE_MANIFEST_URLS:-}"
controller_releases="${XINGCHEN_AGENT_CONTROLLER_RELEASES:-true}"
allow_github_api="${XINGCHEN_AGENT_ALLOW_GITHUB_API:-false}"
network_mode="${XINGCHEN_NETWORK_MODE:-public}"
allow_gitee="${XINGCHEN_ALLOW_GITEE:-false}"
release_version="${XINGCHEN_AGENT_VERSION:-}"
release_downloaded_binary="xingchen-agent"
rollback_version=""
interval="3s"
services=()
processes=()
disks=()
log_paths=()
collect_system_logs=false
integrity_paths=()
skip_processes=false
collect_all_processes=false
process_limit=256
skip_connections=false
skip_ports=false
port_limit=512
skip_containers=false
container_limit=100
allow_command_execution=false
allow_file_operations=false
no_docker=false
allow_insecure_http=false
auto_update=true
purge=false
docker_socket="${XINGCHEN_DOCKER_SOCKET:-}"
docker_socket_target="/run/xingchen-agent-docker.sock"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-url) server_url="${2:-}"; shift 2 ;;
    --device-id) device_id="${2:-}"; shift 2 ;;
    --allow-insecure-http) allow_insecure_http=true; shift ;;
    --network-mode) network_mode="${2:-}"; shift 2 ;;
    --allow-gitee) allow_gitee=true; shift ;;
    --offline) network_mode=offline; shift ;;
    --allow-command-execution) allow_command_execution=true; shift ;;
    --allow-file-operations) allow_file_operations=true; shift ;;
    --no-auto-update) auto_update=false; shift ;;
    --binary) binary_path="${2:-}"; shift 2 ;;
    --native) agent_mode="native"; shift ;;
    --docker) agent_mode="docker"; shift ;;
    --image) agent_image="${2:-}"; shift 2 ;;
    --container) container_name="${2:-}"; container_overridden=true; shift 2 ;;
    --no-docker) no_docker=true; shift ;;
    --docker-socket) docker_socket="${2:-}"; shift 2 ;;
    --source-url)
      if [[ "${source_url_overridden}" == false ]]; then
        repository_urls=()
        source_url_overridden=true
      fi
      repository_urls+=("${2:-}")
      shift 2
      ;;
    --source-ref) source_ref="${2:-}"; source_ref_overridden=true; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    --service) services+=("${2:-}"); shift 2 ;;
    --process) processes+=("${2:-}"); shift 2 ;;
    --disk) disks+=("${2:-}"); shift 2 ;;
    --log-path) log_paths+=("${2:-}"); shift 2 ;;
    --system-logs) collect_system_logs=true; shift ;;
    --integrity-path) integrity_paths+=("${2:-}"); shift 2 ;;
    --skip-processes) skip_processes=true; shift ;;
    --all-processes) collect_all_processes=true; shift ;;
    --process-limit) process_limit="${2:-}"; shift 2 ;;
    --skip-connections) skip_connections=true; shift ;;
    --skip-ports) skip_ports=true; shift ;;
    --port-limit) port_limit="${2:-}"; shift 2 ;;
    --skip-containers) skip_containers=true; shift ;;
    --container-limit) container_limit="${2:-}"; shift 2 ;;
    --purge) purge=true; shift ;;
    --version) release_version="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *)
      if [[ "${action}" == rollback && -z "${rollback_version}" ]]; then
        rollback_version="$1"
        shift
      elif [[ "${action}" =~ ^(update|upgrade)$ && -z "${release_version}" && "$1" != -* ]]; then
        release_version="$1"
        shift
      else
        echo "Unknown option: $1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

network_mode="${network_mode,,}"
allow_gitee="${allow_gitee,,}"
allow_github_api="${allow_github_api,,}"
if [[ ! "${network_mode}" =~ ^(public|internal|offline)$ ]]; then
  echo "--network-mode 必须是 public、internal 或 offline。" >&2
  exit 2
fi
if [[ ! "${allow_gitee}" =~ ^(true|false)$ || ! "${allow_github_api}" =~ ^(true|false)$ ]]; then
  echo "XINGCHEN_ALLOW_GITEE 和 XINGCHEN_AGENT_ALLOW_GITHUB_API 必须是 true 或 false。" >&2
  exit 2
fi
if [[ "${network_mode}" != public && "${allow_github_api}" == true ]]; then
  echo "${network_mode} 网络模式禁止 GitHub API；请移除 --allow-github-api/XINGCHEN_AGENT_ALLOW_GITHUB_API。" >&2
  exit 2
fi
if [[ "${network_mode}" == offline ]]; then
  auto_update=false
fi
release_max_redirects=10
if [[ "${network_mode}" == internal ]]; then
  release_max_redirects=0
fi

script_source="${BASH_SOURCE[0]-}"
if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1 && [[ -n "${script_source}" && -f "${script_source}" ]]; then
    exec sudo --preserve-env=XINGCHEN_SERVER,XINGCHEN_SERVER_URL,XINGCHEN_DEVICE_ID,XINGCHEN_ENROLLMENT_TOKEN,XINGCHEN_AGENT_KEY,XINGCHEN_AGENT_IMAGE,XINGCHEN_AGENT_IMAGE_MIRRORS,XINGCHEN_AGENT_MODE,XINGCHEN_AGENT_RELEASE_REPO,XINGCHEN_AGENT_RELEASE_BASE_URLS,XINGCHEN_RELEASE_MANIFEST_URLS,XINGCHEN_AGENT_CONTROLLER_RELEASES,XINGCHEN_AGENT_ALLOW_GITHUB_API,XINGCHEN_NETWORK_MODE,XINGCHEN_ALLOW_GITEE,XINGCHEN_REPOSITORY_URL,XINGCHEN_REPOSITORY_URLS,XINGCHEN_SOURCE_REF,XINGCHEN_AGENT_SOURCE_BUILD_TIMEOUT_SECONDS,XINGCHEN_UPDATE_MIRROR_TIMEOUT_SECONDS,XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS bash "${script_source}" "${original_args[@]}"
  fi
  echo "请以 root 身份运行，或安装 sudo 后重试。" >&2
  exit 1
fi
unset XINGCHEN_AGENT_KEY XINGCHEN_ENROLLMENT_TOKEN

load_manager_metadata() {
  [[ -r "${manager_metadata_path}" ]] || return 0
  local saved_container saved_volume saved_mode saved_binary saved_repo saved_base_urls saved_service saved_user saved_config_dir saved_data_dir saved_binary_target saved_update_service saved_update_timer saved_network_mode saved_allow_gitee
  saved_mode="$(sed -n 's/^AGENT_MODE=//p' "${manager_metadata_path}" | head -n 1)"
  saved_binary="$(sed -n 's/^BINARY_PATH=//p' "${manager_metadata_path}" | head -n 1)"
  saved_repo="$(sed -n 's/^RELEASE_REPO=//p' "${manager_metadata_path}" | head -n 1)"
  saved_base_urls="$(sed -n 's/^RELEASE_BASE_URLS=//p' "${manager_metadata_path}" | head -n 1)"
  saved_container="$(sed -n 's/^CONTAINER_NAME=//p' "${manager_metadata_path}" | head -n 1)"
  saved_volume="$(sed -n 's/^SPOOL_VOLUME=//p' "${manager_metadata_path}" | head -n 1)"
  saved_service="$(sed -n 's/^AGENT_SERVICE=//p' "${manager_metadata_path}" | head -n 1)"
  saved_user="$(sed -n 's/^AGENT_USER=//p' "${manager_metadata_path}" | head -n 1)"
  saved_config_dir="$(sed -n 's/^CONFIG_DIR=//p' "${manager_metadata_path}" | head -n 1)"
  saved_data_dir="$(sed -n 's/^DATA_DIR=//p' "${manager_metadata_path}" | head -n 1)"
  saved_binary_target="$(sed -n 's/^BINARY_TARGET=//p' "${manager_metadata_path}" | head -n 1)"
  saved_update_service="$(sed -n 's/^UPDATE_SERVICE=//p' "${manager_metadata_path}" | head -n 1)"
  saved_update_timer="$(sed -n 's/^UPDATE_TIMER=//p' "${manager_metadata_path}" | head -n 1)"
  saved_network_mode="$(sed -n 's/^NETWORK_MODE=//p' "${manager_metadata_path}" | head -n 1)"
  saved_allow_gitee="$(sed -n 's/^ALLOW_GITEE=//p' "${manager_metadata_path}" | head -n 1)"
  if [[ "${saved_mode}" == native || "${saved_mode}" == docker ]]; then
    agent_mode="${saved_mode}"
  fi
  if [[ -n "${saved_binary}" ]]; then
    binary_path="${saved_binary}"
  fi
  if [[ "${saved_repo}" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
    release_repo="${saved_repo}"
  fi
  if [[ -n "${saved_base_urls}" ]]; then
    release_base_urls="${saved_base_urls}"
  fi
  if [[ "${saved_container}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    container_name="${saved_container}"
  fi
  if [[ "${saved_volume}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    manager_spool_volume="${saved_volume}"
  fi
  [[ -n "${saved_service}" ]] && agent_service_name="${saved_service}"
  [[ -n "${saved_user}" ]] && agent_user="${saved_user}"
  [[ -n "${saved_config_dir}" ]] && agent_config_dir="${saved_config_dir}" && agent_config_path="${agent_config_dir}/agent.json"
  [[ -n "${saved_data_dir}" ]] && agent_data_dir="${saved_data_dir}" && agent_spool_path="${agent_data_dir}/spool" && agent_backup_dir="${agent_data_dir}/backups"
  [[ -n "${saved_binary_target}" ]] && agent_binary_target="${saved_binary_target}"
  [[ -n "${saved_update_service}" ]] && agent_update_service_name="${saved_update_service}"
  [[ -n "${saved_update_timer}" ]] && agent_update_timer_name="${saved_update_timer}"
  [[ "${saved_network_mode}" =~ ^(public|internal|offline)$ ]] && network_mode="${saved_network_mode}"
  [[ "${saved_allow_gitee}" =~ ^(true|false)$ ]] && allow_gitee="${saved_allow_gitee}"
}

use_legacy_installation_names() {
  legacy_installation=true
  agent_service_name="guanlan-agent.service"
  agent_user="guanlan-agent"
  agent_config_dir="/etc/guanlan-agent"
  agent_config_path="${agent_config_dir}/agent.json"
  agent_data_dir="/var/lib/guanlan-agent"
  agent_spool_path="${agent_data_dir}/spool"
  agent_backup_dir="${agent_data_dir}/backups"
  agent_binary_target="/usr/local/bin/guanlan-agent"
  agent_update_service_name="guanlan-agent-update.service"
  agent_update_timer_name="guanlan-agent-update.timer"
  agent_update_request_service_name="guanlan-agent-update-request.service"
  agent_update_request_path_name="guanlan-agent-update-request.path"
  docker_socket_target="/run/guanlan-agent-docker.sock"
}

detect_existing_installation() {
  [[ -r "${manager_metadata_path}" ]] || true
  local saved_binary
  saved_binary="$(sed -n 's/^BINARY_PATH=//p' "${manager_metadata_path}" 2>/dev/null | head -n 1 || true)"
  if [[ "${saved_binary}" == "/usr/local/bin/guanlan-agent" ]]; then
    use_legacy_installation_names
    return
  fi
  if [[ "${container_overridden}" != true ]] && command -v docker >/dev/null 2>&1 && docker container inspect guanlan-agent >/dev/null 2>&1 && ! docker container inspect xingchen-agent >/dev/null 2>&1; then
    container_name="guanlan-agent"
    use_legacy_installation_names
    return
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl cat guanlan-agent.service >/dev/null 2>&1 && ! systemctl cat xingchen-agent.service >/dev/null 2>&1; then
    use_legacy_installation_names
  fi
}

manager_mode() {
  if command -v docker >/dev/null 2>&1 && docker container inspect "${container_name}" >/dev/null 2>&1; then
    printf 'docker'
  elif command -v systemctl >/dev/null 2>&1 && systemctl cat "${agent_service_name}" >/dev/null 2>&1; then
    printf 'systemd'
  else
    printf 'missing'
  fi
}

manager_status() {
  case "$(manager_mode)" in
    docker) docker ps -a --filter "name=^/${container_name}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' ;;
    systemd) systemctl status "${agent_service_name}" --no-pager ;;
    missing) echo "Agent 尚未安装。" >&2; return 1 ;;
  esac
}

manager_logs() {
  case "$(manager_mode)" in
    docker) docker logs --tail 100 "${container_name}" ;;
    systemd) journalctl -u "${agent_service_name}" -n 100 --no-pager ;;
    missing) echo "Agent 尚未安装。" >&2; return 1 ;;
  esac
}

manager_restart() {
  case "$(manager_mode)" in
    docker) docker restart "${container_name}" >/dev/null ;;
    systemd) systemctl restart "${agent_service_name}" ;;
    missing) echo "Agent 尚未安装。" >&2; return 1 ;;
  esac
  echo "Agent 已重新启动。"
}

manager_update() {
  if [[ ! -x "${manager_updater_path}" ]]; then
    echo "当前安装缺少更新器，请从总控重新复制安装命令覆盖安装。" >&2
    return 1
  fi
  "${manager_updater_path}" "$@"
  echo "Agent 更新检查已完成。"
}

manager_uninstall() {
  local mode
  mode="$(manager_mode)"
  if [[ "${mode}" == docker ]]; then
    docker rm -f "${container_name}" >/dev/null
  elif [[ "${mode}" == systemd ]]; then
    systemctl disable --now "${agent_service_name}" >/dev/null 2>&1 || true
    rm -f "${systemd_dir}/${agent_service_name}" "${agent_binary_target}"
  fi
  systemctl disable --now "${agent_update_timer_name}" >/dev/null 2>&1 || true
  systemctl disable --now "${agent_update_request_path_name}" >/dev/null 2>&1 || true
  rm -f "${systemd_dir}/${agent_update_service_name}" "${systemd_dir}/${agent_update_timer_name}" \
    "${systemd_dir}/${agent_update_request_service_name}" "${systemd_dir}/${agent_update_request_path_name}" \
    "${manager_updater_path}" "${agent_update_request_handler_path}" "${agent_update_request_path}" "${legacy_updater_path}"
  rmdir "${agent_update_request_dir}" >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ "${purge}" == true ]]; then
    rm -rf -- "${agent_config_dir}" "${agent_data_dir}"
    if [[ -n "${manager_spool_volume:-}" ]] && command -v docker >/dev/null 2>&1; then
      docker volume rm "${manager_spool_volume}" >/dev/null 2>&1 || true
    fi
    echo "Agent、配置和本地缓存已卸载。"
  else
    echo "Agent 已卸载；配置和离线缓存已保留。使用 uninstall --purge 可彻底删除。"
  fi
  rm -f "${manager_path}" "${manager_metadata_path}"
}

manager_menu() {
  local choice answer executable="${script_source}"
  [[ -x "${manager_path}" ]] && executable="${manager_path}"
  while true; do
    printf '\n星辰监控 Agent 管理\n'
    printf '1. 查看状态\n2. 查看日志\n3. 重启 Agent\n4. 立即更新\n5. 卸载 Agent\n0. 退出\n'
    read -r -p '请选择操作 [0-5]: ' choice
    case "${choice}" in
      1) "${executable}" status || true ;;
      2) "${executable}" logs || true ;;
      3) "${executable}" restart || true ;;
      4) "${executable}" update || true ;;
      5)
        read -r -p '是否同时删除配置和离线缓存？[y/N]: ' answer
        if [[ "${answer}" =~ ^[Yy]$ ]]; then "${executable}" uninstall --purge; else "${executable}" uninstall; fi
        return
        ;;
      0) return ;;
      *) echo "请输入 0-5。" ;;
    esac
  done
}

detect_existing_installation
if [[ "${action}" != install ]]; then
  load_manager_metadata
  case "${action}" in
    update|upgrade)
      if [[ -n "${release_version}" ]]; then manager_update update "${release_version}"; else manager_update update; fi
      ;;
    rollback) [[ -n "${rollback_version}" ]] || { echo "请提供要回退的版本，例如 rollback v1.20.4。" >&2; exit 2; }; manager_update rollback "${rollback_version}" ;;
    list-versions|versions) manager_update list-versions ;;
    restart) manager_restart ;;
    status) manager_status ;;
    logs) manager_logs ;;
    uninstall) manager_uninstall ;;
    menu) manager_menu ;;
  esac
  exit $?
fi

if [[ -z "${agent_key}" && -z "${enrollment_token}" && -t 0 ]]; then
  read -r -s -p '请输入一次性 Agent 接入令牌（输入不会回显）: ' enrollment_token
  printf '\n'
fi
if [[ -z "${server_url}" || -z "${device_id}" || ( -z "${enrollment_token}" && -z "${agent_key}" ) ]]; then
  echo "Server URL, device ID and XINGCHEN_ENROLLMENT_TOKEN or XINGCHEN_AGENT_KEY are required." >&2
  usage >&2
  exit 2
fi
if [[ ! "${interval}" =~ ^(1s|3s|10s|30s|60s)$ ]]; then
  echo "Interval must be 1s, 3s, 10s, 30s or 60s." >&2
  exit 2
fi
if [[ -z "${agent_image}" ]]; then
  echo "Agent image cannot be empty." >&2
  exit 2
fi
if [[ "${agent_update_status_path}" != /* \
  || "${agent_update_status_path}" == *[[:space:]]* \
  || "${agent_update_status_path}" == */ \
  || "${agent_update_status_path}" == *//* \
  || "${agent_update_status_path}" == */./* \
  || "${agent_update_status_path}" == */. \
  || "${agent_update_status_path}" == */../* \
  || "${agent_update_status_path}" == */.. \
  || -z "${agent_update_status_dir}" \
  || "${agent_update_status_dir}" == / \
  || "${agent_update_status_dir}" == "${agent_update_status_path}" ]]; then
  echo "XINGCHEN_AGENT_UPDATE_STATUS_PATH 必须是位于非根目录下、无空白或路径跳转的绝对文件路径。" >&2
  exit 2
fi
if [[ "${agent_update_request_path}" != /* \
  || "${agent_update_request_path}" == *[[:space:]]* \
  || "${agent_update_request_path}" == */ \
  || "${agent_update_request_path}" == *//* \
  || "${agent_update_request_path}" == */./* \
  || "${agent_update_request_path}" == */../* \
  || "${agent_update_request_path}" == */.. \
  || -z "${agent_update_request_dir}" \
  || "${agent_update_request_dir}" == / \
  || "${agent_update_request_dir}" == "${agent_update_request_path}" ]]; then
  echo "Agent update request path must be an absolute file path below a non-root directory." >&2
  exit 2
fi
if [[ -z "${source_ref}" || "${source_ref}" == -* || "${source_ref}" == *..* || ! "${source_ref}" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
  echo "Agent source repository list or Git ref is invalid." >&2
  exit 2
fi
if [[ ! "${source_build_timeout}" =~ ^[1-9][0-9]*$ ]]; then
  echo "XINGCHEN_AGENT_SOURCE_BUILD_TIMEOUT_SECONDS 必须是正整数秒数。" >&2
  exit 2
fi
for repository_url in "${repository_urls[@]}"; do
  if [[ -z "${repository_url}" ]]; then
    echo "Agent source repository URL cannot be empty." >&2
    exit 2
  fi
done
if [[ ! "${container_name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
  echo "Container name contains invalid characters: ${container_name}" >&2
  exit 2
fi
if [[ "${agent_mode}" != native && "${agent_mode}" != docker ]]; then
  echo "Agent mode must be native or docker." >&2
  exit 2
fi
if [[ ! "${release_repo}" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
  echo "Agent release repository is invalid." >&2
  exit 2
fi

is_local_host() {
  local host="$1"
  [[ "${host}" =~ ^(localhost|127\.0\.0\.1|\[::1\]|::1)(:[0-9]+)?$ ]]
}

network_url_host() {
  local value="${1,,}" authority host
  authority="${value#*://}"
  authority="${authority%%/*}"
  authority="${authority%%\?*}"
  authority="${authority%%\#*}"
  [[ "${authority}" != *@* ]] || return 1
  if [[ "${authority}" == \[* ]]; then
    host="${authority#\[}"
    host="${host%%\]*}"
  else
    host="${authority%%:*}"
  fi
  host="${host%.}"
  [[ -n "${host}" ]] || return 1
  printf '%s' "${host}"
}

network_host_matches() {
  local host="${1,,}" suffix="${2,,}"
  [[ "${host}" == "${suffix}" || "${host}" == *."${suffix}" ]]
}

network_host_is_forbidden() {
  local host="$1"
  network_host_matches "${host}" github.com \
    || network_host_matches "${host}" githubusercontent.com \
    || network_host_matches "${host}" githubassets.com \
    || network_host_matches "${host}" ghcr.io \
    || network_host_matches "${host}" docker.io \
    || network_host_matches "${host}" docker.com
}

network_source_host() {
  local value="$1" authority
  if [[ "${value}" == *://* ]]; then
    network_url_host "${value}"
  elif [[ "${value}" == *@*:* ]]; then
    authority="${value#*@}"
    authority="${authority%%:*}"
    authority="${authority,,}"
    authority="${authority%.}"
    [[ -n "${authority}" ]] || return 1
    printf '%s' "${authority}"
  else
    return 1
  fi
}

validate_remote_source() {
  local value="$1" label="$2" host
  [[ -z "${value}" ]] && return 0
  if [[ "${network_mode}" == offline ]]; then
    echo "offline 网络模式拒绝远程${label}：${value}" >&2
    return 1
  fi
  host="$(network_source_host "${value}" 2>/dev/null || true)"
  if [[ -n "${host}" ]] && network_host_matches "${host}" gitee.com && [[ "${allow_gitee}" != true ]]; then
    echo "Gitee ${label}仅在 XINGCHEN_ALLOW_GITEE=true 时允许：${value}" >&2
    return 1
  fi
  [[ "${network_mode}" == internal ]] || return 0
  if [[ "${value}" != https://* ]]; then
    echo "internal 网络模式只允许 HTTPS ${label}：${value}" >&2
    return 1
  fi
  host="$(network_url_host "${value}")" || { echo "${label}地址无效：${value}" >&2; return 1; }
  if network_host_is_forbidden "${host}"; then
    echo "internal 网络模式拒绝 GitHub/GHCR/Docker ${label}：${value}" >&2
    return 1
  fi
}

validate_internal_registry() {
  local reference="$1" label="$2" name first host
  [[ "${network_mode}" != offline ]] || return 0
  name="${reference%%@*}"
  if [[ "${name}" != */* ]]; then
    [[ "${network_mode}" == internal ]] || return 0
    echo "internal 网络模式拒绝无 Registry 主机的${label}：${reference}" >&2
    return 1
  fi
  first="${name%%/*}"
  if [[ "${first}" != *.* && "${first}" != *:* && "${first,,}" != localhost ]]; then
    [[ "${network_mode}" == internal ]] || return 0
    echo "internal 网络模式拒绝 Docker Hub/无主机${label}：${reference}" >&2
    return 1
  fi
  host="${first%%:*}"
  host="${host,,}"
  host="${host%.}"
  if network_host_matches "${host}" gitee.com && [[ "${allow_gitee}" != true ]]; then
    echo "Gitee Registry 仅在 XINGCHEN_ALLOW_GITEE=true 时允许：${reference}" >&2
    return 1
  fi
  [[ "${network_mode}" == internal ]] || return 0
  if network_host_is_forbidden "${host}"; then
    echo "internal 网络模式拒绝公共 Registry ${label}：${reference}" >&2
    return 1
  fi
}

validate_network_configuration() {
  local value
  IFS=',' read -r -a configured_manifest_sources <<< "${release_manifest_urls}"
  for value in "${configured_manifest_sources[@]}"; do
    value="${value//[[:space:]]/}"
    if [[ -n "${value}" ]]; then
      validate_remote_source "${value}" "manifest 源" || return 1
    fi
  done
  IFS=',' read -r -a configured_release_sources <<< "${release_base_urls}"
  for value in "${configured_release_sources[@]}"; do
    value="${value//[[:space:]]/}"
    if [[ -n "${value}" ]]; then
      validate_remote_source "${value}" "制品源" || return 1
    fi
  done
  for value in "${repository_urls[@]}"; do
    if [[ -n "${value}" ]]; then
      validate_remote_source "${value}" "源码源" || return 1
    fi
  done
  if [[ "${agent_mode}" == docker ]]; then
    if [[ "${network_mode}" == offline && -n "${XINGCHEN_AGENT_IMAGE_MIRRORS:-}" ]]; then
      echo "offline 网络模式拒绝配置镜像源；请预先导入 Agent 镜像。" >&2
      return 1
    fi
    validate_internal_registry "${agent_image}" "Agent 镜像" || return 1
    IFS=',' read -r -a configured_mirrors <<< "${XINGCHEN_AGENT_IMAGE_MIRRORS:-}"
    for value in "${configured_mirrors[@]}"; do
      value="${value%/}"
      if [[ -n "${value}" ]]; then
        validate_internal_registry "${value}/placeholder/image:v0.0.0" "镜像源" || return 1
      fi
    done
  fi
}

probe_server_url() {
  local scheme="$1"
  local candidate="$2"
  local url="${candidate%/}/healthz"
  local args=(--fail --silent --show-error --location --max-redirs 0 --max-time 10 --connect-timeout 5 --proto "=${scheme}" --proto-redir "=${scheme}")
  [[ "${scheme}" == "https" ]] && args+=(--tlsv1.2)
  # Some hosts publish IPv6 DNS records without a working IPv6 route. Try IPv4
  # first, then fall back to the normal resolver for IPv6-only networks.
  curl -4 "${args[@]}" "${url}" >/dev/null 2>&1 || curl "${args[@]}" "${url}" >/dev/null
}

resolve_server_url() {
  local raw="${server_url%/}"
  local scheme=""
  local host=""
  local candidate=""
  local local_host=false
  config_allow_insecure_http=false

  if [[ "${raw}" =~ ^(https?):// ]]; then
    scheme="${BASH_REMATCH[1]}"
    host="${raw#*://}"
    if [[ "${raw}" == *[[:space:]?#@]* || "${host}" == */* ]]; then
      echo "Server URL cannot contain credentials, a path, query or fragment: ${raw}" >&2
      exit 2
    fi
    if is_local_host "${host}"; then
      local_host=true
    fi
    if [[ "${scheme}" == "http" && "${local_host}" != true ]]; then
      if [[ "${allow_insecure_http}" != true ]]; then
        echo "远程 HTTP 连接未获授权；请配置 HTTPS，或确认风险后显式传入 --allow-insecure-http。" >&2
        exit 2
      fi
      config_allow_insecure_http=true
      echo "警告：Agent 将通过未加密的 HTTP 连接 ${raw}。生产环境建议配置 HTTPS。" >&2
    fi
    server_url="${raw}"
    return
  fi

  if [[ "${network_mode}" == offline ]]; then
    echo "offline 网络模式不会探测 DNS/协议；请通过 --server-url 提供完整 HTTP(S) URL。" >&2
    exit 2
  fi

  if [[ -z "${raw}" || "${raw}" == *[[:space:]/?#@]* || "${raw}" == *://* ]]; then
    echo "Server URL must be a hostname, hostname:port, or complete HTTP(S) URL: ${server_url}" >&2
    exit 2
  fi
  host="${raw}"
  if is_local_host "${host}"; then
    local_host=true
  fi
  candidate="https://${host}"
  if ! command -v curl >/dev/null 2>&1; then
    echo "自动识别协议需要 curl；请安装 curl，或直接传入完整 HTTPS URL。" >&2
    exit 1
  fi
  if probe_server_url https "${candidate}"; then
    server_url="${candidate}"
    return
  fi
  candidate="http://${host}"
  if [[ "${local_host}" != true && "${allow_insecure_http}" != true ]]; then
    echo "未检测到可用 HTTPS；不会自动尝试远程 HTTP。确认风险后可传入 --allow-insecure-http。" >&2
    exit 2
  fi
  if probe_server_url http "${candidate}"; then
    server_url="${candidate}"
    if [[ "${local_host}" != true ]]; then
      config_allow_insecure_http=true
      echo "未检测到可用 HTTPS，已回退到未加密 HTTP：${candidate}" >&2
    fi
    return
  fi
  echo "无法访问 ${host} 的 HTTPS 或 HTTP 健康检查。请检查 DNS、端口和服务状态。" >&2
  exit 1
}

exchange_enrollment_token() {
  [[ -z "${agent_key}" ]] || return 0
  if [[ "${network_mode}" == offline ]]; then
    echo "offline 网络模式不能交换一次性接入令牌；请仅通过 XINGCHEN_AGENT_KEY 环境变量提供已签发长期密钥。" >&2
    return 1
  fi
  local endpoint="${server_url%/}/api/agent/v1/enroll" protocol='=https' response
  [[ "${server_url}" == http://* ]] && protocol='=http'
  response="$(printf '{"deviceId":"%s","token":"%s"}' "$(json_escape "${device_id}")" "$(json_escape "${enrollment_token}")" |
    curl -fsS --connect-timeout 10 --max-time 30 --max-filesize 65536 --proto "${protocol}" --proto-redir "${protocol}" --tlsv1.2 \
      -H 'Content-Type: application/json' --data-binary @- "${endpoint}")" || {
    echo "Agent 接入令牌交换失败；请确认令牌未过期或重新签发。" >&2
    return 1
  }
  agent_key="$(printf '%s' "${response}" | sed -n 's/.*"agentKey"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p' | head -n 1)"
  if [[ ! "${agent_key}" =~ ^[A-Za-z0-9_-]{32,128}$ ]]; then
    agent_key=""
    echo "总控返回的 Agent 长期凭据格式无效。" >&2
    return 1
  fi
  enrollment_token=""
  unset XINGCHEN_ENROLLMENT_TOKEN
}

validate_network_configuration
resolve_server_url
if [[ "${network_mode}" == internal ]]; then
  validate_remote_source "${server_url}" "Controller 地址"
fi

run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}s" "$@"
  else
    "$@"
  fi
}

release_platform() {
  release_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  release_arch="$(uname -m)"
  [[ "${release_os}" == linux ]] || { echo "当前系统不支持预编译 Agent：${release_os}" >&2; return 1; }
  case "${release_arch}" in
    x86_64|amd64) release_arch=amd64 ;;
    aarch64|arm64) release_arch=arm64 ;;
    *) echo "当前 CPU 架构不支持预编译 Agent：${release_arch}" >&2; return 1 ;;
  esac
}

normalize_release_version() {
  local value="${1:-}"
  value="${value#v}"
  if [[ "${value}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf 'v%s.%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

get_release_version() {
  if [[ -n "${release_version}" ]]; then
    normalize_release_version "${release_version}" || { echo "版本号必须是稳定语义版本，例如 v1.20.6。" >&2; return 2; }
    return
  fi
  [[ "${network_mode}" != offline ]] || return 1
  local response latest manifest_url
  IFS=',' read -r -a manifest_sources <<< "${release_manifest_urls}"
  for manifest_url in "${manifest_sources[@]}"; do
    manifest_url="${manifest_url//[[:space:]]/}"
    [[ "${manifest_url}" == https://* && "${manifest_url}" != *"@"* ]] || continue
    response="$(curl -fsSL --max-redirs "${release_max_redirects}" --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 30 --max-filesize 1048576 --proto '=https' --proto-redir '=https' --tlsv1.2 "${manifest_url}" 2>/dev/null)" || continue
    latest="$(printf '%s' "${response}" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    normalize_release_version "${latest}" && return 0
  done
  if [[ "${allow_github_api}" == true ]]; then
    response="$(curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 30 --proto '=https' --proto-redir '=https' --tlsv1.2 "https://api.github.com/repos/${release_repo}/releases/latest" 2>/dev/null)" || return 1
    latest="$(printf '%s' "${response}" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    normalize_release_version "${latest}"
    return
  fi
  return 1
}

release_asset_name() {
  printf '%s_%s_%s_%s.tar.gz' "${2:-xingchen-agent}" "${1#v}" "${release_os}" "${release_arch}"
}

controller_curl_protocol() {
  if [[ "${server_url}" == https://* ]]; then
    printf '=https'
  else
    printf '=http'
  fi
}

extract_agent_archive() {
  local archive="$1" destination="$2" expected_name="${3:-}" listing entry verbose
  listing="$(tar -tzf "${archive}")" || return 1
  [[ -n "${listing}" && "${listing}" != *$'\n'* ]] || return 1
  entry="${listing#./}"
  [[ "${entry}" == xingchen-agent || "${entry}" == guanlan-agent ]] || return 1
  [[ -z "${expected_name}" || "${entry}" == "${expected_name}" ]] || return 1
  verbose="$(tar -tvzf "${archive}")" || return 1
  [[ -n "${verbose}" && "${verbose}" != *$'\n'* && "${verbose:0:1}" == - ]] || return 1
  tar -xzf "${archive}" -C "${destination}" || return 1
  [[ -f "${destination}/${entry}" && ! -L "${destination}/${entry}" ]] || return 1
  printf '%s' "${destination}/${entry}"
}

controller_release_metadata() {
  local endpoint response version file checksum size protocol
  [[ "${controller_releases}" == true && "${network_mode}" != offline ]] || return 1
  endpoint="${server_url%/}/api/setup/agent-release?os=${release_os}&arch=${release_arch}"
  protocol="$(controller_curl_protocol)"
  response="$(curl -fsSL --max-redirs 0 --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 30 --max-filesize 1048576 --proto "${protocol}" --proto-redir "${protocol}" --tlsv1.2 "${endpoint}" 2>/dev/null)" || return 1
  version="$(printf '%s' "${response}" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  file="$(printf '%s' "${response}" | sed -n 's/.*"file"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  checksum="$(printf '%s' "${response}" | sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([a-fA-F0-9]*\)".*/\1/p' | head -n 1 | tr '[:upper:]' '[:lower:]')"
  size="$(printf '%s' "${response}" | sed -n 's/.*"size"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  controller_release_version="$(normalize_release_version "${version}")" || return 1
  [[ "${file}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.tar\.gz$ ]] || return 1
  [[ "${checksum}" =~ ^[a-f0-9]{64}$ ]] || return 1
  [[ "${size}" =~ ^[1-9][0-9]*$ ]] && ((size <= 536870912)) || return 1
  controller_release_file="${file}"
  controller_release_sha256="${checksum}"
  controller_release_size="${size}"
}

download_controller_release_binary() {
  local requested_version="${1:-}" destination="$2" normalized_requested archive actual_size actual extracted protocol
  controller_release_metadata || return 1
  if [[ -n "${requested_version}" ]]; then
    normalized_requested="$(normalize_release_version "${requested_version}")" || return 1
    [[ "${normalized_requested}" == "${controller_release_version}" ]] || return 1
  fi
  mkdir -p "${destination}"
  archive="${destination}/${controller_release_file}"
  protocol="$(controller_curl_protocol)"
  echo "正在从总控下载 Agent ${controller_release_version}（${release_os}/${release_arch}）..."
  if ! curl -fsSL --max-redirs 0 --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 --max-filesize 536870912 --proto "${protocol}" --proto-redir "${protocol}" --tlsv1.2 \
    "${server_url%/}/api/setup/agent-artifact?os=${release_os}&arch=${release_arch}&version=${controller_release_version}" -o "${archive}"; then
    rm -f "${archive}"
    return 1
  fi
  actual_size="$(wc -c < "${archive}" | tr -d '[:space:]')"
  actual="$(sha256sum "${archive}" | awk '{print $1}')"
  if [[ "${actual_size}" != "${controller_release_size}" || "${actual}" != "${controller_release_sha256}" ]]; then
    echo "总控返回的 Agent 制品完整性校验失败，已丢弃。" >&2
    rm -f "${archive}"
    return 1
  fi
  if ! extracted="$(extract_agent_archive "${archive}" "${destination}")"; then
    echo "Agent 压缩包必须只包含一个根目录普通二进制，已拒绝。" >&2
    rm -f "${archive}"
    return 1
  fi
  release_downloaded_binary="$(basename "${extracted}")"
  if [[ "${extracted}" != "${destination}/${release_downloaded_binary}" ]]; then
    install -m 0755 "${extracted}" "${destination}/${release_downloaded_binary}"
  else
    chmod 0755 "${extracted}"
  fi
  release_downloaded_version="${controller_release_version}"
  rm -f "${archive}"
}

download_release_binary() {
  local requested_version="${1:-}" destination="$2" version asset_prefix asset base archive checksum expected actual extracted
  release_platform || return 1
  if download_controller_release_binary "${requested_version}" "${destination}"; then
    return 0
  fi
  release_version="${requested_version}"
  version="$(get_release_version)" || { echo "无法获取 Agent Release 版本，请稍后重试或指定 --version。" >&2; return 1; }
  mkdir -p "${destination}"
  IFS=',' read -r -a release_bases <<< "${release_base_urls}"
  for base in "${release_bases[@]}"; do
    base="${base%/}"
    [[ "${base}" == https://* && "${base}" != *"@"* && "${base}" != *"?"* && "${base}" != *"#"* && "${base}" != *[[:space:]]* ]] || continue
    for asset_prefix in xingchen-agent guanlan-agent; do
      asset="$(release_asset_name "${version}" "${asset_prefix}")"
      archive="${destination}/${asset}"
      checksum="${destination}/checksums.txt"
      echo "正在下载 Agent ${version}（${release_os}/${release_arch}）..."
      if ! curl -fsSL --max-redirs "${release_max_redirects}" --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 --max-filesize 52428800 --proto '=https' --proto-redir '=https' --tlsv1.2 "${base}/${version}/${asset}" -o "${archive}"; then
        rm -f "${archive}"
        continue
      fi
      [[ -s "${archive}" ]] || { rm -f "${archive}"; continue; }
      if ! curl -fsSL --max-redirs "${release_max_redirects}" --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 --max-filesize 1048576 --proto '=https' --proto-redir '=https' --tlsv1.2 "${base}/${version}/checksums.txt" -o "${checksum}"; then
        rm -f "${archive}" "${checksum}"
        continue
      fi
      [[ -s "${checksum}" ]] || { rm -f "${archive}" "${checksum}"; continue; }
      expected="$(awk -v name="${asset}" '$2 == name || substr($2, 2) == name { print $1; exit }' "${checksum}")"
      actual="$(sha256sum "${archive}" | awk '{print $1}')"
      if [[ -z "${expected}" || "${expected}" != "${actual}" ]]; then
        echo "Agent 下载校验失败，已丢弃 ${asset}。" >&2
        rm -f "${archive}" "${checksum}"
        continue
      fi
      if ! extracted="$(extract_agent_archive "${archive}" "${destination}" "${asset_prefix}")"; then
        echo "Agent 压缩包必须只包含预期的根目录普通二进制。" >&2
        rm -f "${archive}" "${checksum}"
        continue
      fi
      if [[ "${extracted}" != "${destination}/${asset_prefix}" ]]; then
        install -m 0755 "${extracted}" "${destination}/${asset_prefix}"
      else
        chmod 0755 "${extracted}"
      fi
      release_downloaded_version="${version}"
      release_downloaded_binary="${asset_prefix}"
      rm -f "${archive}" "${checksum}"
      return 0
    done
  done
  return 1
}

script_dir=""
project_root=""
if [[ -n "${script_source}" && -f "${script_source}" ]]; then
  script_dir="$(cd -- "$(dirname -- "${script_source}")" && pwd)"
  project_root="$(cd -- "${script_dir}/.." && pwd)"
fi
temp_dir="$(mktemp -d)"
trap 'agent_key=""; enrollment_token=""; unset XINGCHEN_AGENT_KEY XINGCHEN_ENROLLMENT_TOKEN; rm -rf "${temp_dir}"' EXIT

docker_available=false
if [[ "${no_docker}" != true ]] && command -v docker >/dev/null 2>&1 && run_with_timeout 10 docker info >/dev/null 2>&1; then
  docker_available=true
fi

if [[ -n "${docker_socket}" ]]; then
  if [[ ! -S "${docker_socket}" ]]; then
    echo "Docker/Podman socket does not exist or is not a Unix socket: ${docker_socket}" >&2
    exit 2
  fi
else
  for candidate_socket in /var/run/docker.sock /run/podman/podman.sock; do
    if [[ -S "${candidate_socket}" ]]; then
      docker_socket="${candidate_socket}"
      break
    fi
  done
fi

host_root=""
if [[ "${docker_available}" == true ]]; then
  host_root="/host"
fi
docker_socket_config="${docker_socket}"
if [[ "${docker_available}" == true ]]; then
  docker_socket_config="${docker_socket_target}"
fi

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "${value}"
}

write_initial_update_status() {
  printf '{"status":"IDLE","lastError":"","changedAt":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${temp_dir}/update-status.json"
}

service_json=""
if ((${#services[@]} > 0)); then
  for service in "${services[@]}"; do
    if [[ -n "${service_json}" ]]; then
      service_json+=","
    fi
    service_json+="\"$(json_escape "${service}")\""
  done
fi
if ! [[ "${process_limit}" =~ ^[1-9][0-9]*$ ]] || ((process_limit > 256)); then
  echo "Process limit must be an integer between 1 and 256." >&2
  exit 2
fi
if ! [[ "${port_limit}" =~ ^[1-9][0-9]*$ ]] || ((port_limit > 512)); then
  echo "Port limit must be an integer between 1 and 512." >&2
  exit 2
fi
if ! [[ "${container_limit}" =~ ^[1-9][0-9]*$ ]] || ((container_limit > 100)); then
  echo "Container limit must be an integer between 1 and 100." >&2
  exit 2
fi

process_json=""
if ((${#processes[@]} > 0)); then
  for process in "${processes[@]}"; do
    if [[ -n "${process_json}" ]]; then
      process_json+=","
    fi
    process_json+="\"$(json_escape "${process}")\""
  done
fi

disk_json=""
if ((${#disks[@]} > 0)); then
  for mountpoint in "${disks[@]}"; do
    if [[ -n "${disk_json}" ]]; then
      disk_json+=","
    fi
    disk_json+="\"$(json_escape "${mountpoint}")\""
  done
fi

log_json=""
if ((${#log_paths[@]} > 0)); then
  for path in "${log_paths[@]}"; do
    if [[ -n "${log_json}" ]]; then
      log_json+=","
    fi
    log_json+="\"$(json_escape "${path}")\""
  done
fi

integrity_json=""
if ((${#integrity_paths[@]} > 0)); then
  for path in "${integrity_paths[@]}"; do
    if [[ -n "${integrity_json}" ]]; then
      integrity_json+=","
    fi
    integrity_json+="\"$(json_escape "${path}")\""
  done
fi

config_tmp="${temp_dir}/agent.json"
write_agent_config() {
  printf '{\n  "server_url": "%s",\n  "device_id": "%s",\n  "agent_key": "%s",\n  "interval": "%s",\n  "request_timeout": "10s",\n  "spool_dir": "%s",\n  "update_status_path": "%s",\n  "update_request_path": "%s",\n  "update_launcher_path": "",\n  "max_buffered_reports": 10000,\n  "allow_insecure_http": false,\n  "allow_command_execution": %s,\n  "allow_file_operations": %s,\n  "monitored_services": [%s],\n  "skip_process_collection": %s,\n  "skip_connection_count": %s,\n  "disk_mountpoints": [%s],\n  "host_root": "%s",\n  "docker_socket": "%s"\n}\n' \
    "$(json_escape "${server_url}")" "$(json_escape "${device_id}")" "$(json_escape "${agent_key}")" "${interval}" "$(json_escape "${agent_spool_path}")" "$(json_escape "${agent_update_status_path}")" "$(json_escape "${agent_update_request_path}")" "${allow_command_execution}" "${allow_file_operations}" "${service_json}" "${skip_processes}" "${skip_connections}" "${disk_json}" "$(json_escape "${host_root}")" "$(json_escape "${docker_socket_config}")" > "${config_tmp}"

  # Avoid passing escaped JSON through awk -v, which can reinterpret backslashes.
  sed -i '$d' "${config_tmp}"
  sed -i '$s/$/,/' "${config_tmp}"
  printf '  "collect_all_processes": %s,\n  "process_collection_limit": %s,\n  "skip_port_collection": %s,\n  "port_collection_limit": %s,\n  "skip_container_collection": %s,\n  "container_collection_limit": %s,\n  "monitored_processes": [%s],\n  "log_paths": [%s],\n  "collect_system_logs": %s,\n  "integrity_paths": [%s]\n}\n' "${collect_all_processes}" "${process_limit}" "${skip_ports}" "${port_limit}" "${skip_containers}" "${container_limit}" "${process_json}" "${log_json}" "${collect_system_logs}" "${integrity_json}" >> "${config_tmp}"

  if [[ "${config_allow_insecure_http}" == true ]]; then
    sed -i 's/"allow_insecure_http": false/"allow_insecure_http": true/' "${config_tmp}"
  fi
}

install_docker_agent() {
  echo "正在准备 Agent 镜像 ${agent_image}..."
  if ! pull_agent_image; then
    echo "无法从配置的镜像或源码源准备 Agent 镜像 ${agent_image}。请配置内网源，或使用 --no-docker --binary PATH 安装已校验程序。" >&2
    return 1
  fi

  exchange_enrollment_token
  write_agent_config
  write_initial_update_status

  local spool_volume="${XINGCHEN_AGENT_VOLUME:-xingchen-agent-spool}"
  docker volume create "${spool_volume}" >/dev/null
  install -d -m 0750 "${agent_config_dir}"
  install -d -m 0755 "${manager_root}" "${agent_update_status_dir}"
  install -d -o root -g root -m 0750 "${agent_update_request_dir}"
  install -m 0600 "${config_tmp}" "${agent_config_path}"
  [[ -f "${agent_update_status_path}" ]] || install -m 0644 "${temp_dir}/update-status.json" "${agent_update_status_path}"
  systemctl disable --now "${agent_service_name}" >/dev/null 2>&1 || true
  if docker container inspect "${container_name}" >/dev/null 2>&1; then
    docker rm -f "${container_name}" >/dev/null
  fi
  local docker_socket_mount=()
  if [[ -n "${docker_socket}" ]]; then
    docker_socket_mount=(--mount "type=bind,src=${docker_socket},dst=${docker_socket_target},readonly")
  fi

  docker run -d \
    --name "${container_name}" \
    --restart unless-stopped \
    --pid host \
    --network host \
    --security-opt no-new-privileges:true \
    --env HOST_PROC=/host/proc \
    --env HOST_SYS=/host/sys \
    --env HOST_ETC=/host/etc \
    --mount "type=bind,src=${agent_config_path},dst=${agent_config_path},readonly" \
    --mount "type=bind,src=${agent_update_status_dir},dst=${agent_update_status_dir},readonly" \
    --mount "type=bind,src=${agent_update_request_dir},dst=${agent_update_request_dir}" \
    --mount "type=volume,src=${spool_volume},dst=${agent_spool_path}" \
    --mount "type=bind,src=/,dst=/host,readonly" \
    --mount "type=bind,src=/proc,dst=/host/proc,readonly" \
    --mount "type=bind,src=/sys,dst=/host/sys,readonly" \
    --mount "type=bind,src=/dev,dst=/host/dev,readonly" \
    --mount "type=bind,src=/etc,dst=/host/etc,readonly" \
    --mount "type=bind,src=/run,dst=/host/run,readonly" \
    "${docker_socket_mount[@]}" \
    "${agent_image}" -config "${agent_config_path}" >/dev/null
  sleep 2
  if [[ "$(docker inspect --format '{{.State.Running}}' "${container_name}")" != "true" ]]; then
    docker logs --tail 100 "${container_name}" >&2 || true
    echo "Agent 容器启动后退出：${container_name}" >&2
    return 1
  fi
  echo "星辰监控 Agent Docker 容器已安装并启动：${container_name}"
  echo "检查状态：docker logs --tail 100 ${container_name}"
  install_agent_updater
  install_agent_update_bridge
}

pull_agent_image() {
  local candidate mirror_prefix image_suffix
  if [[ ! "${mirror_pull_timeout}" =~ ^[1-9][0-9]*$ || ! "${agent_pull_timeout}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Agent 镜像拉取超时必须是正整数秒数。" >&2
    return 2
  fi
  if [[ "${network_mode}" == offline ]]; then
    if docker image inspect "${agent_image}" >/dev/null 2>&1; then
      echo "offline 网络模式使用已导入的本地 Agent 镜像。"
      return 0
    fi
    echo "offline 网络模式未找到本地 Agent 镜像 ${agent_image}；请先从已校验 bundle 导入。" >&2
    return 1
  fi
  if [[ "${agent_image}" == ghcr.io/* ]]; then
    image_suffix="${agent_image#ghcr.io/}"
    IFS=',' read -r -a mirror_prefixes <<< "${XINGCHEN_AGENT_IMAGE_MIRRORS:-}"
    for mirror_prefix in "${mirror_prefixes[@]}"; do
      mirror_prefix="${mirror_prefix%/}"
      [[ -z "${mirror_prefix}" ]] && continue
      candidate="${mirror_prefix}/${image_suffix}"
      echo "正在尝试 Agent 镜像源 ${candidate}..."
      if run_with_timeout "${mirror_pull_timeout}" docker pull "${candidate}" >/dev/null && run_with_timeout "${mirror_pull_timeout}" docker tag "${candidate}" "${agent_image}"; then
        return 0
      fi
    done
  fi
  echo "正在尝试 Agent 官方镜像源 ${agent_image}..."
  if run_with_timeout "${agent_pull_timeout}" docker pull "${agent_image}"; then
    return 0
  fi
  if [[ "${network_mode}" == internal ]]; then
    echo "internal 网络模式下 Agent 镜像拉取失败，拒绝源码构建回退。" >&2
    return 1
  fi
  build_agent_image_from_source
}

build_agent_image_from_source() {
  local repository_url context build_version="${release_version:-}" build_ref="${source_ref}" image_tag actual_build_version
  [[ "${network_mode}" == public ]] || return 1
  if [[ "${agent_image}" == *@* ]]; then
    echo "固定摘要镜像无法使用源码构建回退：${agent_image}" >&2
    return 1
  fi
  if [[ -z "${build_version}" ]]; then
    image_tag="${agent_image##*:}"
    build_version="$(normalize_release_version "${image_tag}" 2>/dev/null || true)"
  fi
  build_version="${build_version:-dev}"
  if [[ "${source_ref_overridden}" != true && "${build_version}" != dev ]]; then
    build_ref="${build_version}"
  fi
  for repository_url in "${repository_urls[@]}"; do
    context="${repository_url}#${build_ref}:agent"
    echo "镜像源不可用，尝试从源码构建 Agent：${repository_url} (${build_ref})"
    if run_with_timeout "${source_build_timeout}" docker build --pull --build-arg "VERSION=${build_version}" --tag "${agent_image}" "${context}"; then
      if [[ "${build_version}" == dev ]]; then
        return 0
      fi
      actual_build_version="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${agent_image}" 2>/dev/null || true)"
      if [[ "${actual_build_version#v}" == "${build_version#v}" ]]; then
        return 0
      fi
      echo "源码构建的 Agent 镜像版本标签不匹配：${actual_build_version:-unknown}。" >&2
    fi
  done
  return 1
}

shell_quote() {
  printf "'%s'" "${1//\'/\'\"\'\"\'}"
}

install_agent_update_bridge() {
  if [[ "$(uname -s)" != Linux ]] || ! command -v systemctl >/dev/null 2>&1 || ! systemctl show-environment >/dev/null 2>&1; then
    echo "未检测到可用的 systemd；专用 Agent 远程更新请求未启用。" >&2
    return 0
  fi
  local handler="${agent_update_request_handler_path}"
  local service="${systemd_dir}/${agent_update_request_service_name}"
  local path_unit="${systemd_dir}/${agent_update_request_path_name}"
  install -d -m 0755 "${manager_root}" "${systemd_dir}"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf 'request_path=%s\n' "$(shell_quote "${agent_update_request_path}")"
    printf 'manager_root=%s\n' "$(shell_quote "${manager_root}")"
    printf 'updater_path=%s\n' "$(shell_quote "${manager_updater_path}")"
    printf 'update_status_path=%s\n' "$(shell_quote "${agent_update_status_path}")"
    printf '%s\n' \
      'processing_path="${manager_root}/.update-request.processing.$$"' \
      'write_rejected_status() { local temporary now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; temporary="$(mktemp "${update_status_path}.XXXXXX" 2>/dev/null || true)"; [[ -n "${temporary}" ]] || return 0; printf '\''{"status":"FAILED","lastError":"Agent update request rejected.","changedAt":"%s"}\n'\'' "${now}" > "${temporary}"; chmod 0644 "${temporary}"; mv -f "${temporary}" "${update_status_path}"; }' \
      'reject_request() { write_rejected_status || true; echo "Agent update request rejected." >&2; exit 2; }' \
      '[[ -e "${request_path}" ]] || exit 0' \
      'mv -- "${request_path}" "${processing_path}" || exit 75' \
      'trap '\''rm -f -- "${processing_path}"'\'' EXIT' \
      '[[ -f "${processing_path}" && ! -L "${processing_path}" ]] || reject_request' \
      '[[ "$(stat -c %a "${processing_path}" 2>/dev/null || true)" == 600 ]] || reject_request' \
      'size="$(stat -c %s "${processing_path}" 2>/dev/null || true)"; [[ "${size}" =~ ^[1-9][0-9]*$ ]] && ((size <= 512)) || reject_request' \
      'mapfile -t fields < "${processing_path}"; ((${#fields[@]} == 4)) || reject_request' \
      '[[ "${fields[0]}" =~ ^action=(update|rollback)$ ]] || reject_request; action="${BASH_REMATCH[1]}"' \
      '[[ "${fields[1]}" =~ ^version=(v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$ ]] || reject_request; version="${BASH_REMATCH[1]}"; ((${#version} <= 64)) || reject_request' \
      '[[ "${fields[2]}" =~ ^rollout_id=([1-9][0-9]*)?$ ]] || reject_request; rollout_id="${BASH_REMATCH[1]:-}"' \
      '[[ "${fields[3]}" =~ ^member_id=([1-9][0-9]*)?$ ]] || reject_request; member_id="${BASH_REMATCH[1]:-}"' \
      '[[ ( -z "${rollout_id}" && -z "${member_id}" ) || ( -n "${rollout_id}" && -n "${member_id}" ) ]] || reject_request' \
      '[[ -x "${updater_path}" && ! -L "${updater_path}" ]] || reject_request' \
      'sleep 10' \
      '"${updater_path}" "${action}" "${version}"'
  } > "${handler}"
  chmod 0755 "${handler}"
  printf '%s\n' '[Unit]' 'Description=Handle a validated Xingchen Agent update request' '' '[Service]' 'Type=oneshot' 'User=root' 'TimeoutStartSec=20min' "ExecStart=${handler}" > "${service}"
  printf '%s\n' '[Unit]' 'Description=Watch for Xingchen Agent update requests' '' '[Path]' "PathExists=${agent_update_request_path}" "Unit=${agent_update_request_service_name}" '' '[Install]' 'WantedBy=multi-user.target' > "${path_unit}"
  chmod 0644 "${service}" "${path_unit}"
  systemctl daemon-reload
  systemctl enable --now "${agent_update_request_path_name}" >/dev/null
}

install_agent_updater() {
  local systemd_available=true
  if [[ "$(uname -s)" != "Linux" ]] || ! command -v systemctl >/dev/null 2>&1 || ! systemctl show-environment >/dev/null 2>&1; then
    systemd_available=false
  fi
  local updater="${manager_updater_path}"
  local service="${systemd_dir}/${agent_update_service_name}"
  local timer="${systemd_dir}/${agent_update_timer_name}"
  install -d -m 0755 "${manager_root}"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf 'image=%s\n' "$(shell_quote "${agent_image}")"
    printf 'container_name=%s\n' "$(shell_quote "${container_name}")"
    printf 'config_path=%s\n' "$(shell_quote "${agent_config_path}")"
    printf 'spool_path=%s\n' "$(shell_quote "${agent_spool_path}")"
    printf 'spool_volume=%s\n' "$(shell_quote "${XINGCHEN_AGENT_VOLUME:-xingchen-agent-spool}")"
    printf 'mirror_list=%s\n' "$(shell_quote "${XINGCHEN_AGENT_IMAGE_MIRRORS:-}")"
    printf 'mirror_timeout=%s\n' "$(shell_quote "${mirror_pull_timeout}")"
    printf 'pull_timeout=%s\n' "$(shell_quote "${agent_pull_timeout}")"
    printf 'source_ref=%s\n' "$(shell_quote "${source_ref}")"
    printf 'source_build_timeout=%s\n' "$(shell_quote "${source_build_timeout}")"
    printf 'release_repo=%s\n' "$(shell_quote "${release_repo}")"
    printf 'release_manifest_urls=%s\n' "$(shell_quote "${release_manifest_urls}")"
    printf 'controller_url=%s\n' "$(shell_quote "${server_url%/}")"
    printf 'controller_protocol=%s\n' "$(shell_quote "$(controller_curl_protocol)")"
    printf 'controller_releases=%s\n' "$(shell_quote "${controller_releases}")"
    printf 'allow_github_api=%s\n' "$(shell_quote "${allow_github_api}")"
    printf 'network_mode=%s\n' "$(shell_quote "${network_mode}")"
    printf 'allow_gitee=%s\n' "$(shell_quote "${allow_gitee}")"
    printf 'release_max_redirects=%s\n' "$(shell_quote "${release_max_redirects}")"
    printf 'repositories=('
    for repository_url in "${repository_urls[@]}"; do
      printf ' %s' "$(shell_quote "${repository_url}")"
    done
    printf ' )\n'
    printf 'docker_socket_source=%s\n' "$(shell_quote "${docker_socket}")"
    printf 'docker_socket_target=%s\n' "$(shell_quote "${docker_socket_target}")"
    printf 'update_state_dir=%s\n' "$(shell_quote "${manager_root}")"
    printf 'update_status_path=%s\n' "$(shell_quote "${agent_update_status_path}")"
    printf 'update_status_dir=%s\n' "$(shell_quote "${agent_update_status_dir}")"
    printf 'update_request_dir=%s\n' "$(shell_quote "${agent_update_request_dir}")"
    printf '%s\n' \
      'automatic_update=false; if [[ "${1:-}" == --automatic ]]; then automatic_update=true; shift; fi' \
      'failure_file="${update_state_dir}/update-failures"; pause_file="${update_state_dir}/update-paused-until"; failure_threshold=5; pause_seconds=86400' \
      'write_update_status() { local state="$1" message="${2:-}" temporary now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; temporary="$(mktemp "${update_status_path}.XXXXXX" 2>/dev/null || true)"; [[ -n "${temporary}" ]] || return 0; printf '\''{"status":"%s","lastError":"%s","changedAt":"%s"}\n'\'' "${state}" "${message}" "${now}" > "${temporary}"; chmod 0644 "${temporary}"; mv -f "${temporary}" "${update_status_path}"; }' \
      'if [[ "${automatic_update}" == true && -r "${pause_file}" ]]; then paused_until="$(cat "${pause_file}" 2>/dev/null || true)"; now="$(date +%s)"; if [[ "${paused_until}" =~ ^[0-9]+$ ]] && ((paused_until > now)); then write_update_status PAUSED "Automatic updates paused after repeated failures." || true; echo "Agent 自动更新已暂停到 Unix 时间 ${paused_until}；可手动执行 update 重试。"; exit 0; fi; fi' \
      'command -v flock >/dev/null 2>&1 || { echo "Agent 更新需要 flock；请先安装 util-linux。" >&2; exit 1; }; lock_path="/run/lock/xingchen-agent-update.lock"; mkdir -p "$(dirname "${lock_path}")"; exec 9>"${lock_path}"; flock -n 9 || { echo "Agent 更新任务正在执行。" >&2; exit 75; }' \
      'finish_update() {' \
      '  status=$?; trap - EXIT' \
      '  if ((status == 0)); then' \
      '    rm -f "${failure_file}" "${pause_file}" 2>/dev/null || true; write_update_status SUCCEEDED "" || true' \
      '  elif [[ "${automatic_update}" == true ]] && ((status != 75)); then' \
      '    count="$(cat "${failure_file}" 2>/dev/null || true)"; [[ "${count}" =~ ^[0-9]+$ ]] || count=0; count=$((count + 1)); temporary="$(mktemp "${update_state_dir}/.update-failures.XXXXXX" 2>/dev/null || true)"; if [[ -n "${temporary}" ]]; then printf "%s\n" "${count}" > "${temporary}"; chmod 0600 "${temporary}"; mv -f "${temporary}" "${failure_file}"; fi' \
      '    if ((count >= failure_threshold)); then pause_until=$(($(date +%s) + pause_seconds)); temporary="$(mktemp "${update_state_dir}/.update-paused.XXXXXX" 2>/dev/null || true)"; if [[ -n "${temporary}" ]]; then printf "%s\n" "${pause_until}" > "${temporary}"; chmod 0600 "${temporary}"; mv -f "${temporary}" "${pause_file}"; fi; write_update_status PAUSED "Automatic updates paused after repeated failures." || true; echo "Agent 自动更新连续失败 ${count} 次，已暂停 24 小时。" >&2' \
      '    else write_update_status FAILED "Agent update failed with exit code ${status}." || true; fi' \
      '  else write_update_status FAILED "Agent update failed with exit code ${status}." || true; fi' \
      '  exit "${status}"' \
      '}' \
      'trap finish_update EXIT' \
      'write_update_status CHECKING "" || true' \
      'run_with_timeout() {' \
      '  local seconds="$1"; shift' \
      '  if command -v timeout >/dev/null 2>&1; then timeout "${seconds}s" "$@"; else "$@"; fi' \
      '}' \
      'normalize_version() { local value="${1#v}"; [[ "${value}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || return 1; printf "v%s" "${value}"; }' \
      'version_less() { local left="${1#v}" right="${2#v}" l1 l2 l3 r1 r2 r3; IFS=. read -r l1 l2 l3 <<< "${left}"; IFS=. read -r r1 r2 r3 <<< "${right}"; ((10#${l1} < 10#${r1} || (10#${l1} == 10#${r1} && 10#${l2} < 10#${r2}) || (10#${l1} == 10#${r1} && 10#${l2} == 10#${r2} && 10#${l3} < 10#${r3}))); }' \
      'same_major() { local left="${1#v}" right="${2#v}"; [[ "${left%%.*}" == "${right%%.*}" ]]; }' \
      'platform() { os="$(uname -s | tr "[:upper:]" "[:lower:]")"; arch="$(uname -m)"; [[ "${os}" == linux ]] || return 1; case "${arch}" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) return 1 ;; esac; }' \
      'controller_version() { local response value; [[ "${controller_releases}" == true && "${network_mode}" != offline ]] || return 1; response="$(curl -fsSL --max-redirs 0 --retry 2 --connect-timeout 10 --max-time 30 --max-filesize 1048576 --proto "${controller_protocol}" --proto-redir "${controller_protocol}" --tlsv1.2 "${controller_url}/api/setup/agent-release?os=${os}&arch=${arch}" 2>/dev/null)" || return 1; value="$(printf "%s" "${response}" | sed -n "s/.*\"version\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1)"; normalize_version "${value}"; }' \
      'version_for_update() { local response value manifest_url; if [[ -n "${requested_version}" ]]; then normalize_version "${requested_version}"; return; fi; [[ "${network_mode}" != offline ]] || return 1; if controller_version; then return; fi; IFS="," read -r -a manifests <<< "${release_manifest_urls}"; for manifest_url in "${manifests[@]}"; do [[ "${manifest_url}" == https://* && "${manifest_url}" != *"@"* ]] || continue; response="$(curl -fsSL --max-redirs "${release_max_redirects}" --retry 2 --connect-timeout 10 --max-time 30 --max-filesize 1048576 --proto "=https" --proto-redir "=https" --tlsv1.2 "${manifest_url}" 2>/dev/null)" || continue; value="$(printf "%s" "${response}" | sed -n "s/.*\"version\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1)"; normalize_version "${value}" && return; done; if [[ "${network_mode}" == public && "${allow_github_api}" == true ]]; then response="$(curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 --max-filesize 1048576 --proto "=https" --proto-redir "=https" --tlsv1.2 "https://api.github.com/repos/${release_repo}/releases/latest" 2>/dev/null)" || return 1; value="$(printf "%s" "${response}" | sed -n "s/.*\"tag_name\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1)"; normalize_version "${value}"; return; fi; return 1; }' \
      'versioned_image() { local reference="$1" version="$2" leaf; [[ "${reference}" != *@* ]] || return 1; leaf="${reference##*/}"; if [[ "${leaf}" == *:* ]]; then printf "%s:%s" "${reference%:*}" "${version}"; else printf "%s:%s" "${reference}" "${version}"; fi; }' \
      'verify_image_version() { local candidate="$1" expected="$2" actual; actual="$(docker image inspect --format "{{index .Config.Labels \"org.opencontainers.image.version\"}}" "${candidate}" 2>/dev/null || true)"; [[ "${actual#v}" == "${expected#v}" ]]; }' \
      'pull_image() {' \
      '  local target_version="$1" suffix prefix candidate build_ref="${1}"' \
      '  if [[ "${network_mode}" == offline ]]; then verify_image_version "${image}" "${target_version}"; return; fi' \
      '  write_update_status DOWNLOADING "" || true' \
      '  if [[ "${image}" == ghcr.io/* ]]; then' \
      '    suffix="${image#ghcr.io/}"' \
      '    IFS="," read -r -a prefixes <<< "${mirror_list}"' \
      '    for prefix in "${prefixes[@]}"; do' \
      '      prefix="${prefix%/}"; [[ -z "${prefix}" ]] && continue' \
      '      candidate="${prefix}/${suffix}"' \
      '      if run_with_timeout "${mirror_timeout}" docker pull "${candidate}" >/dev/null && verify_image_version "${candidate}" "${target_version}" && run_with_timeout "${mirror_timeout}" docker tag "${candidate}" "${image}"; then return 0; fi' \
      '    done' \
      '  fi' \
      '  if run_with_timeout "${pull_timeout}" docker pull "${image}" && verify_image_version "${image}" "${target_version}"; then return 0; fi' \
      '  [[ "${network_mode}" == public ]] || return 1' \
      '  [[ "${image}" == *@* ]] && return 1' \
      '  for repository in "${repositories[@]}"; do' \
      '    echo "镜像源不可用，尝试从源码构建 Agent：${repository} (${build_ref})"' \
      '    if run_with_timeout "${source_build_timeout}" docker build --pull --build-arg "VERSION=${target_version}" --tag "${image}" "${repository}#${build_ref}:agent" && verify_image_version "${image}" "${target_version}"; then return 0; fi' \
      '  done' \
      '  return 1' \
      '}' \
      'command="${1:-update}"; requested_version="${2:-}"; platform || { echo "当前系统或架构不支持 Agent 镜像更新。" >&2; exit 1; }' \
      'if [[ "${command}" == list-versions ]]; then version_for_update; exit $?; fi' \
      'version="$(version_for_update)" || { echo "无法获取 Agent Release 版本。" >&2; exit 1; }' \
      'current_version="$(docker inspect --format "{{index .Config.Labels \"org.opencontainers.image.version\"}}" "${container_name}" 2>/dev/null || true)"' \
      'current_version="$(normalize_version "${current_version}" 2>/dev/null || true)"' \
      'if [[ -z "${current_version}" ]]; then current_reference="$(docker inspect --format "{{.Config.Image}}" "${container_name}" 2>/dev/null || true)"; current_version="$(normalize_version "${current_reference##*:}" 2>/dev/null || true)"; fi' \
      'if [[ -n "${current_version}" && "${version}" == "${current_version}" ]]; then echo "Agent 已是 ${version}。"; exit 0; fi' \
      'if [[ "${automatic_update}" == true && "${command}" != rollback && -n "${current_version}" ]] && ! same_major "${current_version}" "${version}"; then echo "Agent 自动更新不会跨主版本：当前 ${current_version}，目标 ${version}；请人工评估后手动更新。"; exit 0; fi' \
      'if [[ "${command}" != rollback && -n "${current_version}" ]] && version_less "${version}" "${current_version}"; then echo "拒绝从 ${current_version} 降级到 ${version}；请显式使用 rollback ${version}。" >&2; exit 2; fi' \
      'if [[ "${image}" == *@* ]]; then echo "固定摘要镜像不会自动改写；请使用新 digest 重新安装 Agent。" >&2; exit 2; fi' \
      'image="$(versioned_image "${image}" "${version}")"' \
      'current="$(docker inspect --format "{{.Image}}" "${container_name}" 2>/dev/null || true)"' \
      'pull_image "${version}"' \
      'after="$(docker image inspect --format "{{.Id}}" "${image}" 2>/dev/null || true)"' \
      '[[ -n "${current}" && "${current}" == "${after}" ]] && exit 0' \
      'write_update_status APPLYING "" || true' \
      'new_container="${container_name}.update"' \
      'old_container="${container_name}.previous"' \
      'docker rm -f "${new_container}" "${old_container}" >/dev/null 2>&1 || true' \
      'old_exists=false' \
      'if docker container inspect "${container_name}" >/dev/null 2>&1; then' \
      '  docker rename "${container_name}" "${old_container}"' \
      '  docker stop "${old_container}" >/dev/null 2>&1 || true' \
      '  old_exists=true' \
      'fi' \
      'restore_old() {' \
      '  write_update_status ROLLING_BACK "Agent health check failed; restoring previous container." || true' \
      '  docker rm -f "${new_container}" >/dev/null 2>&1 || true' \
      '  if [[ "${old_exists}" == true ]]; then' \
      '    docker rename "${old_container}" "${container_name}" >/dev/null 2>&1 || true' \
      '    docker start "${container_name}" >/dev/null 2>&1 || true' \
      '  fi' \
      '}' \
      'if [[ -z "${docker_socket_source}" ]]; then for candidate_socket in /var/run/docker.sock /run/podman/podman.sock; do if [[ -S "${candidate_socket}" ]]; then docker_socket_source="${candidate_socket}"; break; fi; done; fi' \
      'socket_mount=()' \
      'if [[ -n "${docker_socket_source}" && -S "${docker_socket_source}" ]]; then socket_mount=(--mount "type=bind,src=${docker_socket_source},dst=${docker_socket_target},readonly"); fi' \
       'if ! run_with_timeout 30 docker run -d --name "${new_container}" --restart unless-stopped --pid host --network host --security-opt no-new-privileges:true --env HOST_PROC=/host/proc --env HOST_SYS=/host/sys --env HOST_ETC=/host/etc --mount "type=bind,src=${config_path},dst=${config_path},readonly" --mount "type=bind,src=${update_status_dir},dst=${update_status_dir},readonly" --mount "type=bind,src=${update_request_dir},dst=${update_request_dir}" --mount "type=volume,src=${spool_volume},dst=${spool_path}" --mount "type=bind,src=/,dst=/host,readonly" --mount "type=bind,src=/proc,dst=/host/proc,readonly" --mount "type=bind,src=/sys,dst=/host/sys,readonly" --mount "type=bind,src=/dev,dst=/host/dev,readonly" --mount "type=bind,src=/etc,dst=/host/etc,readonly" --mount "type=bind,src=/run,dst=/host/run,readonly" "${socket_mount[@]}" "${image}" -config "${config_path}" >/dev/null; then restore_old; exit 1; fi' \
      'sleep 2' \
      'if [[ "$(docker inspect --format "{{.State.Running}}" "${new_container}" 2>/dev/null || true)" != true ]]; then docker logs --tail 100 "${new_container}" >&2 || true; restore_old; exit 1; fi' \
      'docker rm -f "${old_container}" >/dev/null 2>&1 || true' \
      'docker rename "${new_container}" "${container_name}"'
  } > "${updater}"
  chmod 0755 "${updater}"
  if [[ "${agent_image}" == *@* && "${auto_update}" == true ]]; then
    echo "Agent 使用固定 digest，未启用自动更新；切换版本时请显式提供新 digest。"
    return 0
  fi
  if [[ "${auto_update}" != true ]]; then
    if [[ "${systemd_available}" == true ]]; then
      systemctl disable --now "${agent_update_timer_name}" >/dev/null 2>&1 || true
      rm -f "${service}" "${timer}"
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    echo "Agent 自动更新未启用，可运行 ${manager_path} update 手动检查。"
    return 0
  fi
  if [[ "${systemd_available}" != true ]]; then
    echo "未检测到可用的 systemd，Agent 已启动但未安装自动更新任务；可运行 ${manager_path} update 手动检查。" >&2
    return 0
  fi
  install -d -m 0755 "${systemd_dir}"
  printf '%s\n' '[Unit]' 'Description=Update Xingchen Monitor Agent image' 'After=docker.service network-online.target' 'Wants=network-online.target' '' '[Service]' 'Type=oneshot' 'TimeoutStartSec=10min' "ExecStart=${updater} --automatic" > "${service}"
  printf '%s\n' '[Unit]' 'Description=Periodic Xingchen Monitor Agent image update' '' '[Timer]' 'OnCalendar=*-*-* 04:15' 'RandomizedDelaySec=30m' 'Persistent=true' "Unit=${agent_update_service_name}" '' '[Install]' 'WantedBy=timers.target' > "${timer}"
  systemctl daemon-reload
  systemctl enable --now "${agent_update_timer_name}" >/dev/null
  echo "Agent 自动更新已启用：systemctl status ${agent_update_timer_name}"
}

clone_agent_source() {
  local destination="$1" repository_url
  [[ "${network_mode}" == public ]] || return 1
  for repository_url in "${repository_urls[@]}"; do
    rm -rf -- "${destination}"
    echo "正在尝试 Agent 源码仓库：${repository_url} (${source_ref})"
    if git clone --branch "${source_ref}" --depth 1 --filter=blob:none --sparse "${repository_url}" "${destination}" >/dev/null \
      && git -C "${destination}" sparse-checkout set agent >/dev/null; then
      return 0
    fi
  done
  return 1
}

install_local_agent_updater() {
  local updater="${manager_updater_path}"
  local service="${systemd_dir}/${agent_update_service_name}"
  local timer="${systemd_dir}/${agent_update_timer_name}"
  install -d -m 0755 "${manager_root}" "${systemd_dir}"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf 'release_repo=%s\n' "$(shell_quote "${release_repo}")"
    printf 'release_base_urls=%s\n' "$(shell_quote "${release_base_urls}")"
    printf 'release_manifest_urls=%s\n' "$(shell_quote "${release_manifest_urls}")"
    printf 'controller_url=%s\n' "$(shell_quote "${server_url%/}")"
    printf 'controller_protocol=%s\n' "$(shell_quote "$(controller_curl_protocol)")"
    printf 'controller_releases=%s\n' "$(shell_quote "${controller_releases}")"
    printf 'allow_github_api=%s\n' "$(shell_quote "${allow_github_api}")"
    printf 'network_mode=%s\n' "$(shell_quote "${network_mode}")"
    printf 'allow_gitee=%s\n' "$(shell_quote "${allow_gitee}")"
    printf 'release_max_redirects=%s\n' "$(shell_quote "${release_max_redirects}")"
    printf 'binary_path=%s\n' "$(shell_quote "${agent_binary_target}")"
    printf 'service_name=%s\n' "$(shell_quote "${agent_service_name}")"
    printf 'backup_dir=%s\n' "$(shell_quote "${agent_backup_dir}")"
    printf 'update_state_dir=%s\n' "$(shell_quote "${manager_root}")"
    printf 'update_status_path=%s\n' "$(shell_quote "${agent_update_status_path}")"
    printf '%s\n' \
      'temp_dir="$(mktemp -d)"' \
      'automatic_update=false; if [[ "${1:-}" == --automatic ]]; then automatic_update=true; shift; fi' \
      'failure_file="${update_state_dir}/update-failures"; pause_file="${update_state_dir}/update-paused-until"; failure_threshold=5; pause_seconds=86400' \
      'write_update_status() { local state="$1" message="${2:-}" temporary now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; temporary="$(mktemp "${update_status_path}.XXXXXX" 2>/dev/null || true)"; [[ -n "${temporary}" ]] || return 0; printf '\''{"status":"%s","lastError":"%s","changedAt":"%s"}\n'\'' "${state}" "${message}" "${now}" > "${temporary}"; chmod 0644 "${temporary}"; mv -f "${temporary}" "${update_status_path}"; }' \
      'if [[ "${automatic_update}" == true && -r "${pause_file}" ]]; then paused_until="$(cat "${pause_file}" 2>/dev/null || true)"; now="$(date +%s)"; if [[ "${paused_until}" =~ ^[0-9]+$ ]] && ((paused_until > now)); then write_update_status PAUSED "Automatic updates paused after repeated failures." || true; rm -rf "${temp_dir}"; echo "Agent 自动更新已暂停到 Unix 时间 ${paused_until}；可手动执行 update 重试。"; exit 0; fi; fi' \
      'command -v flock >/dev/null 2>&1 || { echo "Agent 更新需要 flock；请先安装 util-linux。" >&2; exit 1; }; lock_path="/run/lock/xingchen-agent-update.lock"; mkdir -p "$(dirname "${lock_path}")"; exec 9>"${lock_path}"; flock -n 9 || exit 75' \
      'finish_update() {' \
      '  status=$?; trap - EXIT; rm -rf "${temp_dir}"' \
      '  if ((status == 0)); then' \
      '    rm -f "${failure_file}" "${pause_file}" 2>/dev/null || true; write_update_status SUCCEEDED "" || true' \
      '  elif [[ "${automatic_update}" == true ]] && ((status != 75)); then' \
      '    count="$(cat "${failure_file}" 2>/dev/null || true)"; [[ "${count}" =~ ^[0-9]+$ ]] || count=0; count=$((count + 1)); temporary="$(mktemp "${update_state_dir}/.update-failures.XXXXXX" 2>/dev/null || true)"; if [[ -n "${temporary}" ]]; then printf "%s\n" "${count}" > "${temporary}"; chmod 0600 "${temporary}"; mv -f "${temporary}" "${failure_file}"; fi' \
      '    if ((count >= failure_threshold)); then pause_until=$(($(date +%s) + pause_seconds)); temporary="$(mktemp "${update_state_dir}/.update-paused.XXXXXX" 2>/dev/null || true)"; if [[ -n "${temporary}" ]]; then printf "%s\n" "${pause_until}" > "${temporary}"; chmod 0600 "${temporary}"; mv -f "${temporary}" "${pause_file}"; fi; write_update_status PAUSED "Automatic updates paused after repeated failures." || true; echo "Agent 自动更新连续失败 ${count} 次，已暂停 24 小时。" >&2' \
      '    else write_update_status FAILED "Agent update failed with exit code ${status}." || true; fi' \
      '  else write_update_status FAILED "Agent update failed with exit code ${status}." || true; fi' \
      '  exit "${status}"' \
      '}' \
      'trap finish_update EXIT' \
      'write_update_status CHECKING "" || true' \
      'normalize_version() { local value="${1#v}"; [[ "${value}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || return 1; printf "v%s" "${value}"; }' \
      'version_less() { local left="${1#v}" right="${2#v}" l1 l2 l3 r1 r2 r3; IFS=. read -r l1 l2 l3 <<< "${left}"; IFS=. read -r r1 r2 r3 <<< "${right}"; ((10#${l1} < 10#${r1} || (10#${l1} == 10#${r1} && 10#${l2} < 10#${r2}) || (10#${l1} == 10#${r1} && 10#${l2} == 10#${r2} && 10#${l3} < 10#${r3}))); }' \
      'same_major() { local left="${1#v}" right="${2#v}"; [[ "${left%%.*}" == "${right%%.*}" ]]; }' \
      'platform() { os="$(uname -s | tr "[:upper:]" "[:lower:]")"; arch="$(uname -m)"; [[ "${os}" == linux ]] || return 1; case "${arch}" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) return 1 ;; esac; }' \
      'controller_metadata() { local response; [[ "${controller_releases}" == true && "${network_mode}" != offline ]] || return 1; response="$(curl -fsSL --max-redirs 0 --retry 2 --connect-timeout 10 --max-time 30 --max-filesize 1048576 --proto "${controller_protocol}" --proto-redir "${controller_protocol}" --tlsv1.2 "${controller_url}/api/setup/agent-release?os=${os}&arch=${arch}" 2>/dev/null)" || return 1; controller_version="$(printf "%s" "${response}" | sed -n "s/.*\"version\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1)"; controller_file="$(printf "%s" "${response}" | sed -n "s/.*\"file\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1)"; controller_sha="$(printf "%s" "${response}" | sed -n "s/.*\"sha256\"[[:space:]]*:[[:space:]]*\"\([a-fA-F0-9]*\)\".*/\1/p" | head -n 1 | tr "[:upper:]" "[:lower:]")"; controller_size="$(printf "%s" "${response}" | sed -n "s/.*\"size\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -n 1)"; controller_version="$(normalize_version "${controller_version}")" || return 1; [[ "${controller_file}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.tar\.gz$ && "${controller_sha}" =~ ^[a-f0-9]{64}$ && "${controller_size}" =~ ^[1-9][0-9]*$ ]] || return 1; ((controller_size <= 536870912)); }' \
      'version_for_update() { local response value manifest_url; if [[ -n "${requested_version}" ]]; then normalize_version "${requested_version}"; return; fi; [[ "${network_mode}" != offline ]] || return 1; if controller_metadata; then printf "%s" "${controller_version}"; return; fi; IFS="," read -r -a manifests <<< "${release_manifest_urls}"; for manifest_url in "${manifests[@]}"; do [[ "${manifest_url}" == https://* && "${manifest_url}" != *"@"* ]] || continue; response="$(curl -fsSL --max-redirs "${release_max_redirects}" --retry 2 --connect-timeout 10 --max-time 30 --max-filesize 1048576 --proto "=https" --proto-redir "=https" --tlsv1.2 "${manifest_url}" 2>/dev/null)" || continue; value="$(printf "%s" "${response}" | sed -n "s/.*\"version\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1)"; normalize_version "${value}" && return; done; if [[ "${network_mode}" == public && "${allow_github_api}" == true ]]; then curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 --proto "=https" --proto-redir "=https" --tlsv1.2 "https://api.github.com/repos/${release_repo}/releases/latest" 2>/dev/null | sed -n "s/.*\"tag_name\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1 | while IFS= read -r value; do normalize_version "${value}"; done; return; fi; return 1; }' \
      'extract_archive() { local archive="$1" expected="${2:-}" listing entry verbose; listing="$(tar -tzf "${archive}")" || return 1; [[ -n "${listing}" && "${listing}" != *$'\''\n'\''* ]] || return 1; entry="${listing#./}"; [[ "${entry}" == xingchen-agent || "${entry}" == guanlan-agent ]] || return 1; [[ -z "${expected}" || "${entry}" == "${expected}" ]] || return 1; verbose="$(tar -tvzf "${archive}")" || return 1; [[ -n "${verbose}" && "${verbose}" != *$'\''\n'\''* && "${verbose:0:1}" == - ]] || return 1; tar -xzf "${archive}" -C "${temp_dir}" || return 1; [[ -f "${temp_dir}/${entry}" && ! -L "${temp_dir}/${entry}" ]] || return 1; install -m 0755 "${temp_dir}/${entry}" "${temp_dir}/xingchen-agent.new"; }' \
      'download_controller() { local version="$1" archive actual_size actual; controller_metadata || return 1; [[ "${controller_version}" == "${version}" ]] || return 1; archive="${temp_dir}/${controller_file}"; curl -fsSL --max-redirs 0 --retry 3 --connect-timeout 10 --max-time 300 --max-filesize 536870912 --proto "${controller_protocol}" --proto-redir "${controller_protocol}" --tlsv1.2 "${controller_url}/api/setup/agent-artifact?os=${os}&arch=${arch}&version=${version}" -o "${archive}" || return 1; actual_size="$(wc -c < "${archive}" | tr -d "[:space:]")"; actual="$(sha256sum "${archive}" | awk '\''{print $1}'\'')"; [[ "${actual_size}" == "${controller_size}" && "${actual}" == "${controller_sha}" ]] || return 1; extract_archive "${archive}"; }' \
      'download() { local version="${1}" asset_prefix asset="" base archive checksum expected actual; [[ "${network_mode}" != offline ]] || return 1; write_update_status DOWNLOADING "" || true; download_controller "${version}" && return 0; IFS="," read -r -a bases <<< "${release_base_urls}"; for base in "${bases[@]}"; do base="${base%/}"; [[ "${base}" == https://* && "${base}" != *"@"* && "${base}" != *"?"* && "${base}" != *"#"* && "${base}" != *[[:space:]]* ]] || continue; for asset_prefix in xingchen-agent guanlan-agent; do asset="${asset_prefix}_${1#v}_${os}_${arch}.tar.gz"; archive="${temp_dir}/${asset}"; checksum="${temp_dir}/checksums.txt"; curl -fsSL --max-redirs "${release_max_redirects}" --retry 3 --connect-timeout 10 --max-time 300 --max-filesize 536870912 --proto "=https" --proto-redir "=https" --tlsv1.2 "${base}/${version}/${asset}" -o "${archive}" || continue; curl -fsSL --max-redirs "${release_max_redirects}" --retry 3 --connect-timeout 10 --max-time 60 --max-filesize 1048576 --proto "=https" --proto-redir "=https" --tlsv1.2 "${base}/${version}/checksums.txt" -o "${checksum}" || continue; expected="$(awk -v n="${asset}" '\''$2 == n || substr($2, 2) == n { print $1; exit }'\'' "${checksum}")"; actual="$(sha256sum "${archive}" | awk '\''{print $1}'\'')"; [[ -n "${expected}" && "${expected}" == "${actual}" ]] || continue; extract_archive "${archive}" "${asset_prefix}" && return 0; done; done; return 1; }' \
      'rollback_old() { local old="$1"; write_update_status ROLLING_BACK "Agent health check failed; restoring previous binary." || true; rm -f "${binary_path}"; mv "${old}" "${binary_path}" || return 1; systemctl start "${service_name}" >/dev/null 2>&1 && systemctl is-active --quiet "${service_name}"; }' \
      'atomic_install() { local old="${binary_path}.previous.$$" backup_version="unknown" backup_path; write_update_status APPLYING "" || true; mkdir -p "${backup_dir}"; backup_version="$("${binary_path}" --version 2>/dev/null | sed -n "s/.*\(v[0-9][0-9.]*\).*/\1/p" | head -n 1 || true)"; backup_path="${backup_dir}/xingchen-agent.${backup_version#v}.$(date -u +%Y%m%d%H%M%S).backup"; cp -p "${binary_path}" "${backup_path}" 2>/dev/null || true; find "${backup_dir}" -type f -name "xingchen-agent.*.backup" -printf "%T@ %p\\n" 2>/dev/null | sort -rn | awk '\''NR > 5 { sub(/^[^ ]+ /, ""); print }'\'' | xargs -r rm -f; systemctl stop "${service_name}" >/dev/null 2>&1 || true; mv "${binary_path}" "${old}" || return 1; if ! mv "${temp_dir}/xingchen-agent.new" "${binary_path}"; then rollback_old "${old}" || { echo "Agent 替换失败，且旧版本恢复失败。" >&2; return 2; }; return 1; fi; if ! systemctl start "${service_name}" >/dev/null 2>&1 || ! systemctl is-active --quiet "${service_name}"; then rollback_old "${old}" || { echo "Agent 启动失败，且旧版本恢复后仍未存活。" >&2; return 2; }; return 1; fi; rm -f "${old}"; }' \
      'command="${1:-update}"; requested_version="${2:-}"; platform || { echo "当前系统或架构不支持预编译 Agent。" >&2; exit 1; }' \
      'if [[ "${command}" == list-versions ]]; then if controller_metadata; then printf "%s\n" "${controller_version}"; exit 0; fi; version_for_update; exit $?; fi' \
      'version="$(version_for_update)" || { echo "无法获取 Agent Release 版本。" >&2; exit 1; }' \
      'current_version="$("${binary_path}" --version 2>/dev/null | sed -n "s/.*\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p" | head -n 1 || true)"' \
      'if [[ -n "${current_version}" && "${version}" == "${current_version}" ]]; then echo "Agent 已是 ${version}。"; exit 0; fi' \
      'if [[ "${automatic_update}" == true && "${command}" != rollback && -n "${current_version}" ]] && ! same_major "${current_version}" "${version}"; then echo "Agent 自动更新不会跨主版本：当前 ${current_version}，目标 ${version}；请人工评估后手动更新。"; exit 0; fi' \
      'if [[ "${command}" != rollback && -n "${current_version}" ]] && version_less "${version}" "${current_version}"; then echo "拒绝从 ${current_version} 降级到 ${version}；请显式使用 rollback ${version}。" >&2; exit 2; fi' \
      'download "${version}" || { echo "Agent ${version} 下载或校验失败。" >&2; exit 1; }' \
      'atomic_install || { echo "Agent 更新失败，已恢复旧版本。" >&2; exit 1; }' \
      'echo "Agent 已更新到 ${version}。"'
  } > "${updater}"
  chmod 0755 "${updater}"
  if [[ "${auto_update}" != true ]]; then
    systemctl disable --now "${agent_update_timer_name}" >/dev/null 2>&1 || true
    rm -f "${service}" "${timer}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
  fi
  printf '%s\n' '[Unit]' 'Description=Update Xingchen Monitor Agent binary' 'After=network-online.target' 'Wants=network-online.target' '' '[Service]' 'Type=oneshot' 'TimeoutStartSec=15min' "ExecStart=${updater} --automatic" > "${service}"
  printf '%s\n' '[Unit]' 'Description=Periodic Xingchen Monitor Agent binary update' '' '[Timer]' 'OnCalendar=*-*-* 04:15' 'RandomizedDelaySec=30m' 'Persistent=true' "Unit=${agent_update_service_name}" '' '[Install]' 'WantedBy=timers.target' > "${timer}"
  systemctl daemon-reload
  systemctl enable --now "${agent_update_timer_name}" >/dev/null
}

install_local_agent() {
  local source_root source_build_version
  if [[ -z "${binary_path}" ]]; then
    if [[ "${network_mode}" == offline ]]; then
      echo "offline 网络模式安装原生 Agent 必须通过 --binary 提供已校验的本地二进制。" >&2
      exit 2
    fi
    if ! download_release_binary "${release_version}" "${temp_dir}/release"; then
      if [[ "${network_mode}" == internal ]]; then
        echo "internal 网络模式下预编译 Agent Release 不可用，拒绝源码构建回退；请修复内部制品源或通过 --binary 提供已校验程序。" >&2
        exit 1
      fi
      echo "预编译 Agent Release 不可用，准备回退到源码构建。" >&2
      source_root="${project_root}"
      if [[ -z "${source_root}" || ! -f "${source_root}/agent/go.mod" ]]; then
        if ! command -v git >/dev/null 2>&1; then
          if ((${#repository_urls[@]} == 0)); then
            echo "总控制品不可用，且未配置外部 Agent 源码仓库；请恢复总控、配置 --source-url，或通过 --binary 提供已校验程序。" >&2
            exit 1
          fi
          echo "未找到 Agent 源码。请安装 git，或通过 --binary 提供预编译 Agent。" >&2
          exit 1
        fi
        echo "正在下载 Agent 源码..."
        if ! clone_agent_source "${temp_dir}/source"; then
          echo "配置的 Agent 源码仓库均不可用。" >&2
          exit 1
        fi
        source_root="${temp_dir}/source"
      fi
      if ! command -v go >/dev/null 2>&1; then
        echo "未提供预编译 Agent 时需要 Go 1.24+。也可以使用 --binary 指定已构建程序。" >&2
        exit 1
      fi
      source_build_version="$(normalize_release_version "${release_version}" 2>/dev/null || true)"
      if [[ -z "${source_build_version}" ]]; then
        source_build_version="$(normalize_release_version "${source_ref}" 2>/dev/null || true)"
      fi
      source_build_version="${source_build_version:-dev}"
      (cd "${source_root}/agent" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.version=${source_build_version}" -o "${temp_dir}/xingchen-agent" ./cmd/agent)
      binary_path="${temp_dir}/xingchen-agent"
    else
      binary_path="${temp_dir}/release/${release_downloaded_binary}"
      release_version="${release_downloaded_version}"
    fi
  fi
  if [[ ! -f "${binary_path}" ]]; then
  echo "Agent binary not found: ${binary_path}" >&2
  exit 1
  fi

  exchange_enrollment_token
  write_agent_config
  write_initial_update_status

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && docker container inspect "${container_name}" >/dev/null 2>&1; then
    docker rm -f "${container_name}" >/dev/null
  fi

  if ! id "${agent_user}" >/dev/null 2>&1; then
  useradd --system --home-dir "${agent_data_dir}" --shell /usr/sbin/nologin "${agent_user}"
  fi
  install -d -o "${agent_user}" -g "${agent_user}" -m 0750 "${agent_config_dir}" "${agent_spool_path}" "${agent_backup_dir}"
  install -d -m 0755 "${manager_root}" "${agent_update_status_dir}"
  install -d -o root -g "${agent_user}" -m 0770 "${agent_update_request_dir}"
  install -m 0755 "${binary_path}" "${agent_binary_target}"
  install -o "${agent_user}" -g "${agent_user}" -m 0600 "${config_tmp}" "${agent_config_path}"
  [[ -f "${agent_update_status_path}" ]] || install -m 0644 "${temp_dir}/update-status.json" "${agent_update_status_path}"

socket_group_line=""
if [[ -n "${docker_socket}" && -S "${docker_socket}" ]] && command -v stat >/dev/null 2>&1; then
  socket_gid="$(stat -c '%g' "${docker_socket}" 2>/dev/null || true)"
  socket_group=""
  if [[ -n "${socket_gid}" && "${socket_gid}" != "0" ]] && command -v getent >/dev/null 2>&1; then
    socket_group="$(getent group "${socket_gid}" | cut -d: -f1 | head -n 1 || true)"
  fi
  if [[ -z "${socket_group}" && "${socket_gid}" =~ ^[0-9]+$ && "${socket_gid}" != "0" ]]; then
    socket_group="${socket_gid}"
  fi
  if [[ -n "${socket_group}" ]]; then
    socket_group_line="SupplementaryGroups=${socket_group}"
  fi
fi

unit_tmp="${temp_dir}/${agent_service_name}"
printf '%s\n' \
  '[Unit]' \
  'Description=Xingchen Server Monitoring Agent' \
  'After=network-online.target' \
  'Wants=network-online.target' \
  '' \
  '[Service]' \
  'Type=simple' \
  "User=${agent_user}" \
  "Group=${agent_user}" \
  "${socket_group_line}" \
  "ExecStart=${agent_binary_target} -config ${agent_config_path}" \
  'Restart=always' \
  'RestartSec=5' \
  'NoNewPrivileges=true' \
  'PrivateTmp=true' \
  'ProtectSystem=strict' \
  'ProtectHome=true' \
  "ReadWritePaths=${agent_data_dir}" \
  "ReadWritePaths=${agent_update_request_dir}" \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' > "${unit_tmp}"
install -d -m 0755 "${systemd_dir}"
install -m 0644 "${unit_tmp}" "${systemd_dir}/${agent_service_name}"

systemctl daemon-reload
systemctl enable --now "${agent_service_name}"
install_local_agent_updater
install_agent_update_bridge
}

install_manager() {
  if [[ -z "${script_source}" || ! -f "${script_source}" ]]; then
    echo "当前通过标准输入运行，未保存管理脚本；请使用控制台生成的下载到文件命令。" >&2
    return 0
  fi
  install -d -m 0755 "${manager_root}"
  local source_path manager_real_path
  source_path="$(cd -- "$(dirname -- "${script_source}")" && pwd)/$(basename -- "${script_source}")"
  manager_real_path="${manager_path}"
  if [[ "${source_path}" != "${manager_real_path}" ]]; then
    install -m 0755 "${script_source}" "${manager_path}"
  fi
  printf 'AGENT_MODE=%s\nBINARY_PATH=%s\nBINARY_TARGET=%s\nAGENT_SERVICE=%s\nAGENT_USER=%s\nCONFIG_DIR=%s\nDATA_DIR=%s\nUPDATE_SERVICE=%s\nUPDATE_TIMER=%s\nRELEASE_REPO=%s\nRELEASE_BASE_URLS=%s\nNETWORK_MODE=%s\nALLOW_GITEE=%s\nCONTAINER_NAME=%s\nSPOOL_VOLUME=%s\n' \
    "${agent_mode}" "${agent_binary_target}" "${agent_binary_target}" "${agent_service_name}" "${agent_user}" "${agent_config_dir}" "${agent_data_dir}" "${agent_update_service_name}" "${agent_update_timer_name}" "${release_repo}" "${release_base_urls}" "${network_mode}" "${allow_gitee}" "${container_name}" "${XINGCHEN_AGENT_VOLUME:-xingchen-agent-spool}" > "${manager_metadata_path}"
  chmod 0600 "${manager_metadata_path}"
  rm -f "${legacy_updater_path}"
  echo "Agent 管理入口：${manager_path}"
}

if [[ "${agent_mode}" == docker && "${docker_available}" == true && "${no_docker}" != true ]]; then
  install_docker_agent
else
  install_local_agent
fi
install_manager
unset agent_key XINGCHEN_AGENT_KEY
if [[ "${docker_available}" != true ]]; then
  echo "星辰监控 Agent installed and started. Check with: systemctl status ${agent_service_name}"
fi
