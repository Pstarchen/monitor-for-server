#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: GUANLAN_AGENT_KEY=... $0 --server-url HOST_OR_URL --device-id ID [--allow-insecure-http] [--allow-command-execution] [--allow-file-operations] [--no-auto-update] [--binary PATH] [--image IMAGE] [--container NAME] [--no-docker] [--docker-socket PATH] [--source-url URL] [--interval 1s|3s|10s|30s|60s] [--service NAME] [--process NAME] [--disk MOUNTPOINT] [--log-path PATH] [--system-logs] [--integrity-path PATH] [--skip-processes] [--all-processes] [--process-limit N] [--skip-connections] [--skip-ports] [--port-limit N] [--skip-containers] [--container-limit N]"
}

server_url="${GUANLAN_SERVER_URL:-}"
device_id="${GUANLAN_DEVICE_ID:-}"
agent_key="${GUANLAN_AGENT_KEY:-}"
repository_url="${GUANLAN_REPOSITORY_URL:-https://github.com/Pstarchen/monitor-for-server.git}"
agent_image="${GUANLAN_AGENT_IMAGE:-ghcr.io/pstarchen/monitor-for-server-agent:${GUANLAN_AGENT_VERSION:-latest}}"
container_name="${GUANLAN_AGENT_CONTAINER:-guanlan-agent}"
binary_path=""
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
docker_socket="${GUANLAN_DOCKER_SOCKET:-}"
docker_socket_target="/run/guanlan-agent-docker.sock"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-url) server_url="${2:-}"; shift 2 ;;
    --device-id) device_id="${2:-}"; shift 2 ;;
    --allow-insecure-http) allow_insecure_http=true; shift ;;
    --allow-command-execution) allow_command_execution=true; shift ;;
    --allow-file-operations) allow_file_operations=true; shift ;;
    --no-auto-update) auto_update=false; shift ;;
    --binary) binary_path="${2:-}"; shift 2 ;;
    --image) agent_image="${2:-}"; shift 2 ;;
    --container) container_name="${2:-}"; shift 2 ;;
    --no-docker) no_docker=true; shift ;;
    --docker-socket) docker_socket="${2:-}"; shift 2 ;;
    --source-url) repository_url="${2:-}"; shift 2 ;;
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
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this installer as root." >&2
  exit 1
fi
if [[ -z "${server_url}" || -z "${device_id}" || -z "${agent_key}" ]]; then
  echo "Server URL, device ID and GUANLAN_AGENT_KEY are required." >&2
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
if [[ ! "${container_name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
  echo "Container name contains invalid characters: ${container_name}" >&2
  exit 2
fi

is_local_host() {
  local host="$1"
  [[ "${host}" =~ ^(localhost|127\.0\.0\.1|\[::1\]|::1)(:[0-9]+)?$ ]]
}

probe_server_url() {
  local scheme="$1"
  local candidate="$2"
  local url="${candidate%/}/healthz"
  local args=(--fail --silent --show-error --location --max-time 10 --connect-timeout 5 --proto "=${scheme}")
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
      config_allow_insecure_http=true
      echo "警告：Agent 将通过未加密的 HTTP 连接 ${raw}。生产环境建议配置 HTTPS。" >&2
    fi
    server_url="${raw}"
    return
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

resolve_server_url

run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}s" "$@"
  else
    "$@"
  fi
}

script_source="${BASH_SOURCE[0]-}"
script_dir=""
project_root=""
if [[ -n "${script_source}" && -f "${script_source}" ]]; then
  script_dir="$(cd -- "$(dirname -- "${script_source}")" && pwd)"
  project_root="$(cd -- "${script_dir}/.." && pwd)"
fi
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

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
printf '{\n  "server_url": "%s",\n  "device_id": "%s",\n  "agent_key": "%s",\n  "interval": "%s",\n  "request_timeout": "10s",\n  "spool_dir": "/var/lib/guanlan-agent/spool",\n  "max_buffered_reports": 10000,\n  "allow_insecure_http": false,\n  "allow_command_execution": %s,\n  "allow_file_operations": %s,\n  "monitored_services": [%s],\n  "skip_process_collection": %s,\n  "skip_connection_count": %s,\n  "disk_mountpoints": [%s],\n  "host_root": "%s",\n  "docker_socket": "%s"\n}\n' \
  "$(json_escape "${server_url}")" "$(json_escape "${device_id}")" "$(json_escape "${agent_key}")" "${interval}" "${allow_command_execution}" "${allow_file_operations}" "${service_json}" "${skip_processes}" "${skip_connections}" "${disk_json}" "$(json_escape "${host_root}")" "$(json_escape "${docker_socket_config}")" > "${config_tmp}"

# Append optional arrays without passing escaped JSON through awk -v, which can
# reinterpret backslashes and turn valid JSON escape sequences into newlines.
sed -i '$d' "${config_tmp}"
sed -i '$s/$/,/' "${config_tmp}"
printf '  "collect_all_processes": %s,\n  "process_collection_limit": %s,\n  "skip_port_collection": %s,\n  "port_collection_limit": %s,\n  "skip_container_collection": %s,\n  "container_collection_limit": %s,\n  "monitored_processes": [%s],\n  "log_paths": [%s],\n  "collect_system_logs": %s,\n  "integrity_paths": [%s]\n}\n' "${collect_all_processes}" "${process_limit}" "${skip_ports}" "${port_limit}" "${skip_containers}" "${container_limit}" "${process_json}" "${log_json}" "${collect_system_logs}" "${integrity_json}" >> "${config_tmp}"

if [[ "${config_allow_insecure_http}" == true ]]; then
  sed -i 's/"allow_insecure_http": false/"allow_insecure_http": true/' "${config_tmp}"
fi

agent_config_dir="/etc/guanlan-agent"
agent_config_path="${agent_config_dir}/agent.json"
agent_spool_path="/var/lib/guanlan-agent/spool"

install_docker_agent() {
  echo "正在拉取 Agent 镜像 ${agent_image}..."
  if ! pull_agent_image; then
    echo "无法拉取 Agent 镜像 ${agent_image}。请检查镜像权限/网络，或使用 --no-docker --binary PATH 强制本机安装。" >&2
    return 1
  fi

  local spool_volume="${GUANLAN_AGENT_VOLUME:-guanlan-agent-spool}"
  docker volume create "${spool_volume}" >/dev/null
  install -d -m 0750 "${agent_config_dir}"
  install -m 0600 "${config_tmp}" "${agent_config_path}"
  systemctl disable --now guanlan-agent.service >/dev/null 2>&1 || true
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
    --mount "type=bind,src=${agent_config_path},dst=/etc/guanlan-agent/agent.json,readonly" \
    --mount "type=volume,src=${spool_volume},dst=${agent_spool_path}" \
    --mount "type=bind,src=/,dst=/host,readonly" \
    --mount "type=bind,src=/proc,dst=/host/proc,readonly" \
    --mount "type=bind,src=/sys,dst=/host/sys,readonly" \
    --mount "type=bind,src=/dev,dst=/host/dev,readonly" \
    --mount "type=bind,src=/etc,dst=/host/etc,readonly" \
    --mount "type=bind,src=/run,dst=/host/run,readonly" \
    "${docker_socket_mount[@]}" \
    "${agent_image}" -config /etc/guanlan-agent/agent.json >/dev/null
  sleep 2
  if [[ "$(docker inspect --format '{{.State.Running}}' "${container_name}")" != "true" ]]; then
    docker logs --tail 100 "${container_name}" >&2 || true
    echo "Agent 容器启动后退出：${container_name}" >&2
    return 1
  fi
  echo "Guanlan Agent Docker 容器已安装并启动：${container_name}"
  echo "检查状态：docker logs --tail 100 ${container_name}"
  install_agent_updater
}

pull_agent_image() {
  local candidate mirror_prefix image_suffix
  local pull_timeout=120
  if [[ "${agent_image}" == ghcr.io/* ]]; then
    image_suffix="${agent_image#ghcr.io/}"
    IFS=',' read -r -a mirror_prefixes <<< "${GUANLAN_AGENT_IMAGE_MIRRORS:-ghcr.1ms.run,ghcr.nju.edu.cn}"
    for mirror_prefix in "${mirror_prefixes[@]}"; do
      mirror_prefix="${mirror_prefix%/}"
      [[ -z "${mirror_prefix}" ]] && continue
      candidate="${mirror_prefix}/${image_suffix}"
      echo "正在尝试 Agent 镜像源 ${candidate}..."
      if run_with_timeout "${pull_timeout}" docker pull "${candidate}" >/dev/null && docker tag "${candidate}" "${agent_image}"; then
        return 0
      fi
    done
  fi
  echo "正在尝试 Agent 官方镜像源 ${agent_image}..."
  run_with_timeout "${pull_timeout}" docker pull "${agent_image}"
}

shell_quote() {
  printf "'%s'" "${1//\'/\'\"\'\"\'}"
}

install_agent_updater() {
  [[ "${auto_update}" == true ]] || return 0
  if [[ "$(uname -s)" != "Linux" ]] || ! command -v systemctl >/dev/null 2>&1 || ! systemctl show-environment >/dev/null 2>&1; then
    echo "未检测到可用的 systemd，Agent 已启动但未安装自动更新任务。" >&2
    return 0
  fi
  local updater="/usr/local/sbin/guanlan-agent-update"
  local service="/etc/systemd/system/guanlan-agent-update.service"
  local timer="/etc/systemd/system/guanlan-agent-update.timer"
  install -d -m 0755 /usr/local/sbin
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf 'image=%s\n' "$(shell_quote "${agent_image}")"
    printf 'container_name=%s\n' "$(shell_quote "${container_name}")"
    printf 'config_path=%s\n' "$(shell_quote "${agent_config_path}")"
    printf 'spool_volume=%s\n' "$(shell_quote "${GUANLAN_AGENT_VOLUME:-guanlan-agent-spool}")"
    printf 'mirror_list=%s\n' "$(shell_quote "${GUANLAN_AGENT_IMAGE_MIRRORS:-ghcr.1ms.run,ghcr.nju.edu.cn}")"
    printf 'docker_socket_source=%s\n' "$(shell_quote "${docker_socket}")"
    printf 'docker_socket_target=%s\n' "$(shell_quote "${docker_socket_target}")"
    printf '%s\n' \
      'if command -v flock >/dev/null 2>&1; then lock_path="/run/lock/guanlan-agent-update.lock"; mkdir -p "$(dirname "${lock_path}")"; exec 9>"${lock_path}"; flock -n 9 || { echo "Agent 更新任务正在执行。" >&2; exit 75; }; fi' \
      'run_with_timeout() {' \
      '  local seconds="$1"; shift' \
      '  if command -v timeout >/dev/null 2>&1; then timeout "${seconds}s" "$@"; else "$@"; fi' \
      '}' \
      'pull_image() {' \
      '  local suffix prefix candidate' \
      '  if [[ "${image}" == ghcr.io/* ]]; then' \
      '    suffix="${image#ghcr.io/}"' \
      '    IFS="," read -r -a prefixes <<< "${mirror_list}"' \
      '    for prefix in "${prefixes[@]}"; do' \
      '      prefix="${prefix%/}"; [[ -z "${prefix}" ]] && continue' \
      '      candidate="${prefix}/${suffix}"' \
      '      if run_with_timeout 120 docker pull "${candidate}" >/dev/null && run_with_timeout 30 docker tag "${candidate}" "${image}"; then return 0; fi' \
      '    done' \
      '  fi' \
      '  run_with_timeout 120 docker pull "${image}"' \
      '}' \
      'before="$(docker image inspect --format "{{.Id}}" "${image}" 2>/dev/null || true)"' \
      'pull_image' \
      'after="$(docker image inspect --format "{{.Id}}" "${image}" 2>/dev/null || true)"' \
      '[[ -n "${before}" && "${before}" == "${after}" ]] && exit 0' \
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
      '  docker rm -f "${new_container}" >/dev/null 2>&1 || true' \
      '  if [[ "${old_exists}" == true ]]; then' \
      '    docker rename "${old_container}" "${container_name}" >/dev/null 2>&1 || true' \
      '    docker start "${container_name}" >/dev/null 2>&1 || true' \
      '  fi' \
      '}' \
      'if [[ -z "${docker_socket_source}" ]]; then for candidate_socket in /var/run/docker.sock /run/podman/podman.sock; do if [[ -S "${candidate_socket}" ]]; then docker_socket_source="${candidate_socket}"; break; fi; done; fi' \
      'socket_mount=()' \
      'if [[ -n "${docker_socket_source}" && -S "${docker_socket_source}" ]]; then socket_mount=(--mount "type=bind,src=${docker_socket_source},dst=${docker_socket_target},readonly"); fi' \
      'if ! run_with_timeout 30 docker run -d --name "${new_container}" --restart unless-stopped --pid host --network host --security-opt no-new-privileges:true --env HOST_PROC=/host/proc --env HOST_SYS=/host/sys --env HOST_ETC=/host/etc --mount "type=bind,src=/etc/guanlan-agent/agent.json,dst=/etc/guanlan-agent/agent.json,readonly" --mount "type=volume,src=${spool_volume},dst=/var/lib/guanlan-agent/spool" --mount "type=bind,src=/,dst=/host,readonly" --mount "type=bind,src=/proc,dst=/host/proc,readonly" --mount "type=bind,src=/sys,dst=/host/sys,readonly" --mount "type=bind,src=/dev,dst=/host/dev,readonly" --mount "type=bind,src=/etc,dst=/host/etc,readonly" --mount "type=bind,src=/run,dst=/host/run,readonly" "${socket_mount[@]}" "${image}" -config /etc/guanlan-agent/agent.json >/dev/null; then restore_old; exit 1; fi' \
      'sleep 2' \
      'if [[ "$(docker inspect --format "{{.State.Running}}" "${new_container}" 2>/dev/null || true)" != true ]]; then docker logs --tail 100 "${new_container}" >&2 || true; restore_old; exit 1; fi' \
      'docker rm -f "${old_container}" >/dev/null 2>&1 || true' \
      'docker rename "${new_container}" "${container_name}"'
  } > "${updater}"
  chmod 0755 "${updater}"
  printf '%s\n' '[Unit]' 'Description=Update Guanlan Agent image' 'After=docker.service network-online.target' 'Wants=network-online.target' '' '[Service]' 'Type=oneshot' 'TimeoutStartSec=10min' "ExecStart=${updater}" > "${service}"
  printf '%s\n' '[Unit]' 'Description=Periodic Guanlan Agent image update' '' '[Timer]' 'OnCalendar=*-*-* 04:15' 'RandomizedDelaySec=30m' 'Persistent=true' 'Unit=guanlan-agent-update.service' '' '[Install]' 'WantedBy=timers.target' > "${timer}"
  systemctl daemon-reload
  systemctl enable --now guanlan-agent-update.timer >/dev/null
  echo "Agent 自动更新已启用：systemctl status guanlan-agent-update.timer"
}

install_local_agent_updater() {
  [[ "${auto_update}" == true ]] || return 0
  local updater="/usr/local/sbin/guanlan-agent-update"
  local service="/etc/systemd/system/guanlan-agent-update.service"
  local timer="/etc/systemd/system/guanlan-agent-update.timer"
  install -d -m 0755 /usr/local/sbin
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf 'repository_url=%s\n' "$(shell_quote "${repository_url}")"
    printf 'binary_path=%s\n' "$(shell_quote "/usr/local/bin/guanlan-agent")"
    printf 'service_name=%s\n' "$(shell_quote "guanlan-agent.service")"
    printf '%s\n' \
      'temp_dir="$(mktemp -d)"' \
      'if command -v flock >/dev/null 2>&1; then lock_path="/run/lock/guanlan-agent-update.lock"; mkdir -p "$(dirname "${lock_path}")"; exec 9>"${lock_path}"; flock -n 9 || exit 75; fi' \
      'trap '\''rm -rf "${temp_dir}"'\'' EXIT' \
      'command -v git >/dev/null 2>&1 || exit 0' \
      'command -v go >/dev/null 2>&1 || exit 0' \
      'git clone --depth 1 --filter=blob:none --sparse "${repository_url}" "${temp_dir}/source" >/dev/null || exit 0' \
      'git -C "${temp_dir}/source" sparse-checkout set agent >/dev/null || exit 0' \
      '(cd "${temp_dir}/source/agent" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "${temp_dir}/guanlan-agent" ./cmd/agent) || exit 0' \
      'cmp -s "${temp_dir}/guanlan-agent" "${binary_path}" && exit 0' \
      'install -m 0755 "${temp_dir}/guanlan-agent" "${binary_path}"' \
      'systemctl restart "${service_name}"'
  } > "${updater}"
  chmod 0755 "${updater}"
  printf '%s\n' '[Unit]' 'Description=Update Guanlan Agent binary' 'After=network-online.target' 'Wants=network-online.target' '' '[Service]' 'Type=oneshot' 'TimeoutStartSec=15min' "ExecStart=${updater}" > "${service}"
  printf '%s\n' '[Unit]' 'Description=Periodic Guanlan Agent binary update' '' '[Timer]' 'OnCalendar=*-*-* 04:15' 'RandomizedDelaySec=30m' 'Persistent=true' 'Unit=guanlan-agent-update.service' '' '[Install]' 'WantedBy=timers.target' > "${timer}"
  systemctl daemon-reload
  systemctl enable --now guanlan-agent-update.timer >/dev/null
}

install_local_agent() {
  if [[ -z "${binary_path}" ]]; then
  source_root="${project_root}"
  if [[ -z "${source_root}" || ! -f "${source_root}/agent/go.mod" ]]; then
    if ! command -v git >/dev/null 2>&1; then
      echo "未找到 Agent 源码。请安装 git，或通过 --binary 提供预编译 Agent。" >&2
      exit 1
    fi
    echo "正在下载 Agent 源码..."
    git clone --depth 1 --filter=blob:none --sparse "${repository_url}" "${temp_dir}/source" >/dev/null
    git -C "${temp_dir}/source" sparse-checkout set agent >/dev/null
    source_root="${temp_dir}/source"
  fi
  if ! command -v go >/dev/null 2>&1; then
    echo "未提供预编译 Agent 时需要 Go 1.24+。也可以使用 --binary 指定已构建程序。" >&2
    exit 1
  fi
  (cd "${source_root}/agent" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "${temp_dir}/guanlan-agent" ./cmd/agent)
  binary_path="${temp_dir}/guanlan-agent"
  fi
  if [[ ! -f "${binary_path}" ]]; then
  echo "Agent binary not found: ${binary_path}" >&2
  exit 1
  fi

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && docker container inspect "${container_name}" >/dev/null 2>&1; then
    docker rm -f "${container_name}" >/dev/null
  fi

  if ! id guanlan-agent >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/guanlan-agent --shell /usr/sbin/nologin guanlan-agent
  fi
  install -d -o guanlan-agent -g guanlan-agent -m 0750 "${agent_config_dir}" /var/lib/guanlan-agent/spool
  install -m 0755 "${binary_path}" /usr/local/bin/guanlan-agent
  install -o guanlan-agent -g guanlan-agent -m 0600 "${config_tmp}" "${agent_config_path}"

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

unit_tmp="${temp_dir}/guanlan-agent.service"
printf '%s\n' \
  '[Unit]' \
  'Description=Guanlan Server Monitoring Agent' \
  'After=network-online.target' \
  'Wants=network-online.target' \
  '' \
  '[Service]' \
  'Type=simple' \
  'User=guanlan-agent' \
  'Group=guanlan-agent' \
  "${socket_group_line}" \
  "ExecStart=/usr/local/bin/guanlan-agent -config ${agent_config_path}" \
  'Restart=always' \
  'RestartSec=5' \
  'NoNewPrivileges=true' \
  'PrivateTmp=true' \
  'ProtectSystem=strict' \
  'ProtectHome=true' \
  'ReadWritePaths=/var/lib/guanlan-agent' \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' > "${unit_tmp}"
install -m 0644 "${unit_tmp}" /etc/systemd/system/guanlan-agent.service

systemctl daemon-reload
systemctl enable --now guanlan-agent.service
install_local_agent_updater
}

if [[ "${docker_available}" == true ]]; then
  install_docker_agent
else
  install_local_agent
fi
unset agent_key GUANLAN_AGENT_KEY
if [[ "${docker_available}" != true ]]; then
  echo "Guanlan Agent installed and started. Check with: systemctl status guanlan-agent"
fi
