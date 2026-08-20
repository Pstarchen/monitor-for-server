#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
installer="${script_dir}/install-agent.sh"
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
    "GUANLAN_AGENT_KEY=test-agent-key"
  )
  if [[ "${EUID}" -eq 0 ]]; then
    env "${environment[@]}" bash "${installer}" \
      --server-url https://monitor.example.com --device-id test-device "$@"
  else
    sudo env "${environment[@]}" bash "${installer}" \
      --server-url https://monitor.example.com --device-id test-device "$@"
  fi
}

: > "${log_file}"
run_installer 1
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-agent:latest' "${log_file}" >/dev/null
grep -F 'docker run -d --name guanlan-agent --restart unless-stopped --pid host --network host' "${log_file}" >/dev/null
grep -F -- '--mount type=bind,src=/,dst=/host,readonly' "${log_file}" >/dev/null
grep -F '"host_root": "/host"' "${config_file}" >/dev/null
if grep -q '^go ' "${log_file}"; then
  echo 'Docker path unexpectedly invoked Go.' >&2
  exit 1
fi

: > "${log_file}"
run_installer 0
grep -F 'go build -trimpath' "${log_file}" >/dev/null
grep -F 'systemctl enable --now guanlan-agent.service' "${log_file}" >/dev/null
grep -F '"host_root": ""' "${config_file}" >/dev/null
if grep -q '^docker pull ' "${log_file}"; then
  echo 'Local fallback unexpectedly pulled the Agent image.' >&2
  exit 1
fi

: > "${log_file}"
binary_path="${temp_dir}/prebuilt-agent"
touch "${binary_path}"
run_installer 1 --no-docker --binary "${binary_path}"
grep -F 'systemctl enable --now guanlan-agent.service' "${log_file}" >/dev/null
if grep -Eq '^(docker pull|go )' "${log_file}"; then
  echo 'Explicit binary path did not select the local Agent.' >&2
  exit 1
fi

: > "${log_file}"
run_installer 1 --binary "${binary_path}"
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-agent:latest' "${log_file}" >/dev/null
if grep -q '^go ' "${log_file}"; then
  echo 'Docker-first path unexpectedly invoked Go when --binary was present.' >&2
  exit 1
fi

echo 'install-agent.sh behavior tests passed.'
