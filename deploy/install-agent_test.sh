#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
installer="${script_dir}/install-agent.sh"
grep -F 'GUANLAN_AGENT_IMAGE_MIRRORS:-ghcr.nju.edu.cn,ghcr.1ms.run' "${installer}" >/dev/null
grep -F 'timeout "${seconds}s"' "${installer}" >/dev/null
grep -F 'cdn.jsdelivr.net/gh/Pstarchen/monitor-for-server@v1.7.1/deploy/install-agent.sh' "${script_dir}/../docs/monitored-agent.md" >/dev/null
grep -F -- '--retry-all-errors --connect-timeout 10 --max-time 30' "${script_dir}/../docs/monitored-agent.md" >/dev/null
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT
fake_bin="${temp_dir}/bin"
log_file="${temp_dir}/commands.log"
config_file="${temp_dir}/agent.json"
mkdir -p "${fake_bin}"
if [[ "${EUID}" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
  echo 'install-agent.sh behavior tests skipped: root or sudo is required.'
  exit 0
fi

cat > "${fake_bin}/docker" <<'SCRIPT'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${TEST_LOG}"
if [[ "${1:-}" == "info" ]]; then
  [[ "${TEST_DOCKER_AVAILABLE:-0}" == "1" ]]
elif [[ "${1:-}" == "container" && "${2:-}" == "inspect" ]]; then
  exit 1
elif [[ "${1:-}" == "inspect" && "${2:-}" == "--format" ]]; then
  printf 'true\n'
fi
SCRIPT

cat > "${fake_bin}/curl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${TEST_LOG}"
case "$*" in
  *https://*) [[ "${TEST_HTTPS_PROBE:-1}" == "1" ]] ;;
  *http://*) [[ "${TEST_HTTP_PROBE:-0}" == "1" ]] ;;
  *) exit 2 ;;
esac
SCRIPT

cat > "${fake_bin}/install" <<'SCRIPT'
#!/usr/bin/env bash
printf 'install %s\n' "$*" >> "${TEST_LOG}"
arguments=("$@")
count="${#arguments[@]}"
if (( count >= 2 )) && [[ "${arguments[count-1]}" == "/etc/guanlan-agent/agent.json" ]]; then
  cp "${arguments[count-2]}" "${TEST_CONFIG}"
fi
SCRIPT

cat > "${fake_bin}/go" <<'SCRIPT'
#!/usr/bin/env bash
printf 'go %s\n' "$*" >> "${TEST_LOG}"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    touch "$2"
    exit 0
  fi
  shift
done
SCRIPT

for command in systemctl useradd sleep; do
  cat > "${fake_bin}/${command}" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${TEST_LOG}"
SCRIPT
done

cat > "${fake_bin}/id" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
chmod +x "${fake_bin}"/*

run_installer() {
  local docker_available="$1"
  shift
  local environment=(
    "PATH=${fake_bin}:/usr/bin:/bin"
    "TEST_LOG=${log_file}"
    "TEST_CONFIG=${config_file}"
    "TEST_DOCKER_AVAILABLE=${docker_available}"
    "TEST_HTTPS_PROBE=${TEST_HTTPS_PROBE:-1}"
    "TEST_HTTP_PROBE=${TEST_HTTP_PROBE:-0}"
    "GUANLAN_AGENT_IMAGE_MIRRORS=ghcr.io"
    "GUANLAN_AGENT_KEY=test-agent-key"
  )
  if [[ "${EUID}" -eq 0 ]]; then
    env "${environment[@]}" bash "${installer}" \
      --server-url "${server_url}" --device-id test-device --no-auto-update "$@"
  else
    sudo env "${environment[@]}" bash "${installer}" \
      --server-url "${server_url}" --device-id test-device --no-auto-update "$@"
  fi
}

run_installer_stdin() {
  local docker_available="$1"
  shift
  local environment=(
    "PATH=${fake_bin}:/usr/bin:/bin"
    "TEST_LOG=${log_file}"
    "TEST_CONFIG=${config_file}"
    "TEST_DOCKER_AVAILABLE=${docker_available}"
    "TEST_HTTPS_PROBE=${TEST_HTTPS_PROBE:-1}"
    "TEST_HTTP_PROBE=${TEST_HTTP_PROBE:-0}"
    "GUANLAN_AGENT_IMAGE_MIRRORS=ghcr.io"
    "GUANLAN_AGENT_KEY=test-agent-key"
  )
  if [[ "${EUID}" -eq 0 ]]; then
    env "${environment[@]}" bash -s -- \
      --server-url "${server_url}" --device-id test-device --no-auto-update "$@" < "${installer}"
  else
    sudo env "${environment[@]}" bash -s -- \
      --server-url "${server_url}" --device-id test-device --no-auto-update "$@" < "${installer}"
  fi
}

: > "${log_file}"
server_url=https://monitor.example.com
run_installer 1
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-agent:latest' "${log_file}" >/dev/null
grep -F 'docker run -d --name guanlan-agent --restart unless-stopped --pid host --network host' "${log_file}" >/dev/null
grep -F -- '--mount type=bind,src=/,dst=/host,readonly' "${log_file}" >/dev/null
grep -F '"host_root": "/host"' "${config_file}" >/dev/null
grep -F '"docker_socket": "/run/guanlan-agent-docker.sock"' "${config_file}" >/dev/null
grep -F '"allow_command_execution": false' "${config_file}" >/dev/null
grep -F '"allow_file_operations": false' "${config_file}" >/dev/null

: > "${log_file}"
server_url=https://monitor.example.com
run_installer 1 --all-processes --process-limit 128 --skip-ports --port-limit 100 --skip-containers --container-limit 20
grep -F '"collect_all_processes": true' "${config_file}" >/dev/null
grep -F '"process_collection_limit": 128' "${config_file}" >/dev/null
grep -F '"skip_port_collection": true' "${config_file}" >/dev/null
grep -F '"port_collection_limit": 100' "${config_file}" >/dev/null
grep -F '"skip_container_collection": true' "${config_file}" >/dev/null
grep -F '"container_collection_limit": 20' "${config_file}" >/dev/null

: > "${log_file}"
server_url=https://monitor.example.com
run_installer 1 --log-path /var/log/example.log --integrity-path /etc/example --process java
grep -F '"log_paths": ["/var/log/example.log"]' "${config_file}" >/dev/null
grep -F '"integrity_paths": ["/etc/example"]' "${config_file}" >/dev/null
grep -F '"monitored_processes": ["java"]' "${config_file}" >/dev/null
if grep -q '^go ' "${log_file}"; then
  echo 'Docker path unexpectedly invoked Go.' >&2
  exit 1
fi

: > "${log_file}"
server_url=https://monitor.example.com
run_installer 0
grep -F 'go build -trimpath' "${log_file}" >/dev/null
grep -F 'systemctl enable --now guanlan-agent.service' "${log_file}" >/dev/null
grep -F '"host_root": ""' "${config_file}" >/dev/null
grep -F '"docker_socket": "' "${config_file}" >/dev/null
if grep -q '^docker pull ' "${log_file}"; then
  echo 'Local fallback unexpectedly pulled the Agent image.' >&2
  exit 1
fi

: > "${log_file}"
binary_path="${temp_dir}/prebuilt-agent"
touch "${binary_path}"
server_url=https://monitor.example.com
run_installer 1 --no-docker --binary "${binary_path}"
grep -F 'systemctl enable --now guanlan-agent.service' "${log_file}" >/dev/null
if grep -Eq '^(docker pull|go )' "${log_file}"; then
  echo 'Explicit binary path did not select the local Agent.' >&2
  exit 1
fi

: > "${log_file}"
server_url=https://monitor.example.com
run_installer 1 --binary "${binary_path}"
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-agent:latest' "${log_file}" >/dev/null
if grep -q '^go ' "${log_file}"; then
  echo 'Docker-first path unexpectedly invoked Go when --binary was present.' >&2
  exit 1
fi

: > "${log_file}"
server_url=https://monitor.example.com
run_installer 1 --allow-command-execution --allow-file-operations
grep -F '"allow_command_execution": true' "${config_file}" >/dev/null
grep -F '"allow_file_operations": true' "${config_file}" >/dev/null

: > "${log_file}"
server_url=https://monitor.example.com
run_installer_stdin 1
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-agent:latest' "${log_file}" >/dev/null
grep -F '"host_root": "/host"' "${config_file}" >/dev/null

: > "${log_file}"
server_url=monitor.example.com
TEST_HTTPS_PROBE=1
TEST_HTTP_PROBE=0
run_installer 1
grep -F 'curl --fail --silent --show-error --location --max-time 10 --connect-timeout 5 --proto =https' "${log_file}" >/dev/null
grep -F '"server_url": "https://monitor.example.com"' "${config_file}" >/dev/null

: > "${log_file}"
server_url=https://monitor.example.com
auto_update_environment=(
  "PATH=${fake_bin}:/usr/bin:/bin"
  "TEST_LOG=${log_file}"
  "TEST_CONFIG=${config_file}"
  "TEST_DOCKER_AVAILABLE=1"
  "GUANLAN_AGENT_IMAGE_MIRRORS=ghcr.io"
  "GUANLAN_AGENT_KEY=test-agent-key"
)
if [[ "${EUID}" -eq 0 ]]; then
  env "${auto_update_environment[@]}" bash "${installer}" \
    --server-url "${server_url}" --device-id test-device
else
  sudo env "${auto_update_environment[@]}" bash "${installer}" \
    --server-url "${server_url}" --device-id test-device
fi
grep -F 'systemctl enable --now guanlan-agent-update.timer' "${log_file}" >/dev/null

: > "${log_file}"
server_url=https://monitor.example.com
if run_installer 1 --docker-socket "${temp_dir}/missing.sock"; then
  echo 'Invalid Docker socket path was accepted.' >&2
  exit 1
fi

: > "${log_file}"
server_url=monitor.example.com
TEST_HTTPS_PROBE=0
TEST_HTTP_PROBE=1
run_installer 1
grep -F 'curl --fail --silent --show-error --location --max-time 10 --connect-timeout 5 --proto =http' "${log_file}" >/dev/null
grep -F '"server_url": "http://monitor.example.com"' "${config_file}" >/dev/null
grep -F '"allow_insecure_http": true' "${config_file}" >/dev/null

: > "${log_file}"
server_url=http://monitor.example.com
run_installer 1
grep -F '"server_url": "http://monitor.example.com"' "${config_file}" >/dev/null
grep -F '"allow_insecure_http": true' "${config_file}" >/dev/null

echo 'install-agent.sh behavior tests passed.'
