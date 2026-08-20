#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: GUANLAN_AGENT_KEY=... $0 --server-url URL --device-id ID [--binary PATH] [--image IMAGE] [--container NAME] [--no-docker] [--source-url URL] [--interval 1s|3s|10s|30s|60s] [--service NAME] [--disk MOUNTPOINT] [--skip-processes] [--skip-connections]"
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
disks=()
skip_processes=false
skip_connections=false
no_docker=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-url) server_url="${2:-}"; shift 2 ;;
    --device-id) device_id="${2:-}"; shift 2 ;;
    --binary) binary_path="${2:-}"; shift 2 ;;
    --image) agent_image="${2:-}"; shift 2 ;;
    --container) container_name="${2:-}"; shift 2 ;;
    --no-docker) no_docker=true; shift ;;
    --source-url) repository_url="${2:-}"; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    --service) services+=("${2:-}"); shift 2 ;;
    --disk) disks+=("${2:-}"); shift 2 ;;
    --skip-processes) skip_processes=true; shift ;;
    --skip-connections) skip_connections=true; shift ;;
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

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "${script_dir}/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

docker_available=false
if [[ "${no_docker}" != true ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker_available=true
fi
host_root=""
if [[ "${docker_available}" == true ]]; then
  host_root="/host"
fi

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "${value}"
}

service_json=""
for service in "${services[@]}"; do
  [[ -n "${service_json}" ]] && service_json+=","
  service_json+="\"$(json_escape "${service}")\""
done

disk_json=""
for mountpoint in "${disks[@]}"; do
  [[ -n "${disk_json}" ]] && disk_json+=","
  disk_json+="\"$(json_escape "${mountpoint}")\""
done

config_tmp="${temp_dir}/agent.json"
printf '{\n  "server_url": "%s",\n  "device_id": "%s",\n  "agent_key": "%s",\n  "interval": "%s",\n  "request_timeout": "10s",\n  "spool_dir": "/var/lib/guanlan-agent/spool",\n  "max_buffered_reports": 10000,\n  "allow_insecure_http": false,\n  "monitored_services": [%s],\n  "skip_process_collection": %s,\n  "skip_connection_count": %s,\n  "disk_mountpoints": [%s],\n  "host_root": "%s"\n}\n' \
  "$(json_escape "${server_url}")" "$(json_escape "${device_id}")" "$(json_escape "${agent_key}")" "${interval}" "${service_json}" "${skip_processes}" "${skip_connections}" "${disk_json}" "$(json_escape "${host_root}")" > "${config_tmp}"

agent_config_dir="/etc/guanlan-agent"
agent_config_path="${agent_config_dir}/agent.json"
agent_spool_path="/var/lib/guanlan-agent/spool"

install_docker_agent() {
  echo "正在拉取 Agent 镜像 ${agent_image}..."
  if ! docker pull "${agent_image}"; then
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
    --mount "type=bind,src=/etc,dst=/host/etc,readonly" \
    --mount "type=bind,src=/run,dst=/host/run,readonly" \
    "${agent_image}" -config /etc/guanlan-agent/agent.json >/dev/null
  sleep 2
  if [[ "$(docker inspect --format '{{.State.Running}}' "${container_name}")" != "true" ]]; then
    docker logs --tail 100 "${container_name}" >&2 || true
    echo "Agent 容器启动后退出：${container_name}" >&2
    return 1
  fi
  echo "Guanlan Agent Docker 容器已安装并启动：${container_name}"
  echo "检查状态：docker logs --tail 100 ${container_name}"
}

install_local_agent() {
  if [[ -z "${binary_path}" ]]; then
  source_root="${project_root}"
  if [[ ! -f "${source_root}/agent/go.mod" ]]; then
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
