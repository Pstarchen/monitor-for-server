#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: GUANLAN_AGENT_KEY=... $0 --server-url URL --device-id ID [--binary PATH] [--interval 1s|3s|10s] [--service NAME] [--disk MOUNTPOINT] [--skip-processes] [--skip-connections]"
}

server_url="${GUANLAN_SERVER_URL:-}"
device_id="${GUANLAN_DEVICE_ID:-}"
agent_key="${GUANLAN_AGENT_KEY:-}"
binary_path=""
interval="3s"
services=()
disks=()
skip_processes=false
skip_connections=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-url) server_url="${2:-}"; shift 2 ;;
    --device-id) device_id="${2:-}"; shift 2 ;;
    --binary) binary_path="${2:-}"; shift 2 ;;
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
if [[ ! "${interval}" =~ ^(1s|3s|10s)$ ]]; then
  echo "Interval must be 1s, 3s or 10s." >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "${script_dir}/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

if [[ -z "${binary_path}" ]]; then
  if ! command -v go >/dev/null 2>&1; then
    echo "Go is required when --binary is not provided." >&2
    exit 1
  fi
  (cd "${project_root}/agent" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "${temp_dir}/guanlan-agent" ./cmd/agent)
  binary_path="${temp_dir}/guanlan-agent"
fi
if [[ ! -f "${binary_path}" ]]; then
  echo "Agent binary not found: ${binary_path}" >&2
  exit 1
fi

if ! id guanlan-agent >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/guanlan-agent --shell /usr/sbin/nologin guanlan-agent
fi
install -d -o guanlan-agent -g guanlan-agent -m 0750 /etc/guanlan-agent /var/lib/guanlan-agent/spool
install -m 0755 "${binary_path}" /usr/local/bin/guanlan-agent

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
printf '{\n  "server_url": "%s",\n  "device_id": "%s",\n  "agent_key": "%s",\n  "interval": "%s",\n  "request_timeout": "10s",\n  "spool_dir": "/var/lib/guanlan-agent/spool",\n  "max_buffered_reports": 10000,\n  "allow_insecure_http": false,\n  "monitored_services": [%s],\n  "skip_process_collection": %s,\n  "skip_connection_count": %s,\n  "disk_mountpoints": [%s]\n}\n' \
  "$(json_escape "${server_url}")" "$(json_escape "${device_id}")" "$(json_escape "${agent_key}")" "${interval}" "${service_json}" "${skip_processes}" "${skip_connections}" "${disk_json}" > "${config_tmp}"
install -o guanlan-agent -g guanlan-agent -m 0600 "${config_tmp}" /etc/guanlan-agent/agent.json

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
  'ExecStart=/usr/local/bin/guanlan-agent -config /etc/guanlan-agent/agent.json' \
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
unset agent_key GUANLAN_AGENT_KEY
echo "Guanlan Agent installed and started. Check with: systemctl status guanlan-agent"
