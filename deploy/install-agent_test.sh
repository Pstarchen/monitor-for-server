#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
installer="${script_dir}/install-agent.sh"
grep -F 'XINGCHEN_AGENT_IMAGE_MIRRORS:-}' "${installer}" >/dev/null
grep -F '/api/setup/agent-release?os=${release_os}&arch=${release_arch}' "${installer}" >/dev/null
grep -F 'XINGCHEN_AGENT_ALLOW_GITHUB_API:-false' "${installer}" >/dev/null
grep -F 'XINGCHEN_AGENT_RELEASE_BASE_URLS:-}' "${installer}" >/dev/null
grep -F 'XINGCHEN_ENROLLMENT_TOKEN:-}' "${installer}" >/dev/null
grep -F '/api/agent/v1/enroll' "${installer}" >/dev/null
grep -F -- '--data-binary @-' "${installer}" >/dev/null
grep -F 'XINGCHEN_ENROLLMENT_TOKEN' "${script_dir}/install-agent.ps1" >/dev/null
grep -F '/api/agent/v1/enroll' "${script_dir}/install-agent.ps1" >/dev/null
grep -F 'XINGCHEN_REPOSITORY_URLS:-}' "${installer}" >/dev/null
grep -F 'version_less()' "${installer}" >/dev/null
if [[ "$(grep -Fc 'same_major()' "${installer}")" -ne 2 ]]; then
  echo 'Generated Bash updaters do not enforce the same-major automatic update policy.' >&2
  exit 1
fi
grep -F '拒绝从 ${current_version} 降级到 ${version}' "${installer}" >/dev/null
grep -F 'function Compare-Version' "${script_dir}/install-agent.ps1" >/dev/null
grep -F 'function Test-SameMajor' "${script_dir}/install-agent.ps1" >/dev/null
grep -F "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File \$updaterPath \$Action \$requestedVersion" "${script_dir}/install-agent.ps1" >/dev/null
grep -F 'Agent ZIP 必须只包含一个二进制文件。' "${script_dir}/install-agent.ps1" >/dev/null
grep -F 'failureThreshold = 5' "${script_dir}/install-agent.ps1" >/dev/null
grep -F -- '-Automatic' "${script_dir}/install-agent.ps1" >/dev/null
grep -F 'elseif (`$Automatic)' "${script_dir}/install-agent.ps1" >/dev/null
if [[ "$(grep -Fc 'elif [[ "${automatic_update}" == true ]] && ((status != 75)); then' "${installer}")" -ne 2 ]]; then
  echo 'Generated Bash updaters do not isolate automatic failure accounting.' >&2
  exit 1
fi
grep -F 'XINGCHEN_UPDATE_MIRROR_TIMEOUT_SECONDS:-45' "${installer}" >/dev/null
grep -F 'timeout "${seconds}s"' "${installer}" >/dev/null
for documentation in monitored-agent.md deployment.md user-guide.md; do
  documentation_path="${script_dir}/../docs/${documentation}"
  grep -F 'https://monitor.example.com/api/setup/agent-installer?platform=linux' "${documentation_path}" >/dev/null
  grep -F 'platform=linux&format=sha256' "${documentation_path}" >/dev/null
  grep -F 'installer=$(mktemp "${TMPDIR:-/tmp}/xingchen-agent.XXXXXX.sh")' "${documentation_path}" >/dev/null
  grep -F 'trap '\''rm -f "$installer"'\'' EXIT' "${documentation_path}" >/dev/null
  grep -F -- 'curl -fL --max-redirs 0 --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60' "${documentation_path}" >/dev/null
  grep -F -- 'curl -fsSL --max-redirs 0 --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60' "${documentation_path}" >/dev/null
  grep -F 'sha256sum "$installer"' "${documentation_path}" >/dev/null
  grep -F 'chmod 700 "$installer"' "${documentation_path}" >/dev/null
  grep -F "XINGCHEN_SERVER='https://monitor.example.com' XINGCHEN_DEVICE_ID='<设备ID>'" "${documentation_path}" >/dev/null
  if grep -Eq '(gitee\.com|raw\.githubusercontent\.com)/.*/(raw/)?main/deploy/install-agent' "${documentation_path}"; then
    echo "${documentation} executes an unpinned main-branch Agent installer." >&2
    exit 1
  fi
  if grep -F 'XINGCHEN_AGENT_KEY=' "${documentation_path}" >/dev/null; then
    echo "${documentation} embeds the long-lived Agent key in a command." >&2
    exit 1
  fi
  if grep -F -- '-o xingchen-agent.sh' "${documentation_path}" >/dev/null; then
    echo "${documentation} uses a predictable Agent installer path." >&2
    exit 1
  fi
done
grep -F '/opt/xingchen/agent/agent.sh update' "${script_dir}/../docs/monitored-agent.md" >/dev/null
grep -F 'manager_update()' "${installer}" >/dev/null
grep -F 'checksums.txt' "${installer}" >/dev/null
grep -F 'atomic_install()' "${installer}" >/dev/null
grep -F 'agent_mode="${XINGCHEN_AGENT_MODE:-native}"' "${installer}" >/dev/null
if grep -Eq 'v1\.12\.0|cdn\.jsdelivr\.net|export XINGCHEN_AGENT_KEY' "${script_dir}/../docs/monitored-agent.md"; then
  echo 'Documentation still contains the retired multi-source installer command.' >&2
  exit 1
fi
temp_dir="$(mktemp -d)"
run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}
cleanup() {
  [[ -n "${temp_dir}" && "${temp_dir}" == /tmp/* ]] || return 1
  run_as_root rm -rf -- "${temp_dir}"
}
trap cleanup EXIT
fake_bin="${temp_dir}/bin"
log_file="${temp_dir}/commands.log"
config_file="${temp_dir}/agent.json"
mkdir -p "${fake_bin}"

rendered_dir="${temp_dir}/rendered"
mkdir -p "${rendered_dir}/systemd"
(
  # Render both generated updaters without installing services so every host can
  # validate the nested Bash syntax, even when root/sudo is unavailable.
  source <(awk '/^shell_quote\(\)/ { capture = 1 } /^install_local_agent_updater\(\)/ { exit } capture { print }' "${installer}")
  controller_curl_protocol() { printf '=https'; }
  manager_root="${rendered_dir}/manager"
  manager_path="${rendered_dir}/agent.sh"
  manager_updater_path="${rendered_dir}/docker-update-agent.sh"
  systemd_dir="${rendered_dir}/systemd"
  agent_update_service_name=xingchen-agent-update.service
  agent_update_timer_name=xingchen-agent-update.timer
  agent_image=registry.internal.example/xingchen-agent:v1.20.13
  container_name=xingchen-agent
  agent_config_path="${rendered_dir}/agent.json"
  agent_spool_path="${rendered_dir}/spool"
  mirror_pull_timeout=45
  agent_pull_timeout=120
  source_ref=v1.20.13
  source_build_timeout=1800
  release_repo=Pstarchen/monitor-for-server
  release_manifest_urls='https://releases.example.com/manifest.json'
  server_url=https://monitor.example.com
  controller_releases=true
  allow_github_api=false
  repository_urls=('https://git.example.com/monitor.git')
  docker_socket=''
  docker_socket_target=/run/xingchen-agent-docker.sock
  auto_update=false
  install_agent_updater >/dev/null
  bash -n "${manager_updater_path}"
  grep -F 'version_for_update()' "${manager_updater_path}" >/dev/null
  grep -F 'Agent 自动更新不会跨主版本' "${manager_updater_path}" >/dev/null
  grep -F 'verify_image_version "${image}" "${target_version}"' "${manager_updater_path}" >/dev/null

  source <(awk '/^install_local_agent_updater\(\)/ { capture = 1 } /^install_local_agent\(\)/ { exit } capture { print }' "${installer}")
  manager_updater_path="${rendered_dir}/native-update-agent.sh"
  agent_binary_target="${rendered_dir}/xingchen-agent"
  agent_service_name=xingchen-agent.service
  agent_backup_dir="${rendered_dir}/backups"
  release_base_urls='https://releases.example.com'
  install_local_agent_updater
  bash -n "${manager_updater_path}"
  grep -F 'Agent 自动更新不会跨主版本' "${manager_updater_path}" >/dev/null
)
if [[ "${EUID}" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
  echo 'install-agent.sh behavior tests skipped: root or sudo is required.'
  exit 0
fi

cat > "${fake_bin}/docker" <<'SCRIPT'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${TEST_LOG}"
if [[ "${1:-}" == "pull" && "${TEST_FAIL_AGENT_PULLS:-0}" == "1" ]]; then
  exit 1
elif [[ "${1:-}" == "build" && "${TEST_FAIL_GITEE_BUILD:-0}" == "1" && "$*" == *gitee.com* ]]; then
  exit 1
elif [[ "${1:-}" == "info" ]]; then
  [[ "${TEST_DOCKER_AVAILABLE:-0}" == "1" ]]
elif [[ "${1:-}" == "container" && "${2:-}" == "inspect" ]]; then
  [[ "${TEST_CONTAINER_EXISTS:-0}" == "1" ]]
elif [[ "${1:-}" == "image" && "${2:-}" == "inspect" && "${3:-}" == "--format" ]]; then
  if [[ "${4:-}" == *'org.opencontainers.image.version'* ]]; then
    printf '%s\n' "${TEST_AGENT_IMAGE_VERSION:-v1.20.13}"
  else
    printf 'new-agent-image\n'
  fi
elif [[ "${1:-}" == "inspect" && "${2:-}" == "--format" ]]; then
  if [[ "${3:-}" == "{{.Image}}" ]]; then
    printf 'old-agent-image\n'
  elif [[ "${3:-}" == *'org.opencontainers.image.version'* ]]; then
    printf '%s\n' "${TEST_RUNNING_AGENT_VERSION:-}"
  elif [[ "${3:-}" == "{{.Config.Image}}" ]]; then
    printf 'registry.internal.example/xingchen-agent:v1.20.10\n'
  else
    printf 'true\n'
  fi
fi
SCRIPT

cat > "${fake_bin}/curl" <<'SCRIPT'
#!/usr/bin/env bash
if [[ -n "${XINGCHEN_AGENT_KEY:-}" || -n "${XINGCHEN_ENROLLMENT_TOKEN:-}" ]]; then
  echo 'Credential environment leaked to curl.' >&2
  exit 97
fi
printf 'curl %s\n' "$*" >> "${TEST_LOG}"
url=""
output=""
arguments=("$@")
for ((index=0; index<${#arguments[@]}; index++)); do
  [[ "${arguments[index]}" == http://* || "${arguments[index]}" == https://* ]] && url="${arguments[index]}"
  if [[ "${arguments[index]}" == -o && $((index+1)) -lt ${#arguments[@]} ]]; then
    output="${arguments[index+1]}"
  fi
done
if [[ "${TEST_CONTROLLER_RELEASE:-0}" == 1 && "${url}" == *'/api/setup/agent-release?'* ]]; then
  printf '{"version":"%s","file":"%s","sha256":"%s","size":%s}\n' "${TEST_RELEASE_VERSION:-v1.20.13}" "${TEST_RELEASE_FILE}" "${TEST_RELEASE_SHA256}" "${TEST_RELEASE_SIZE}"
  exit 0
fi
if [[ "${TEST_CONTROLLER_RELEASE:-0}" == 1 && "${url}" == *'/api/setup/agent-artifact?'* ]]; then
  cp "${TEST_RELEASE_ARCHIVE}" "${output}"
  exit 0
fi
if [[ "${url}" == *'/api/agent/v1/enroll' ]]; then
  cat >/dev/null
  printf '{"agentKey":"enrolled-agent-key-0123456789_abcdefghijklmnopqrstuvwxyz"}\n'
  exit 0
fi
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
if [[ " ${*} " == *" -d "* ]]; then
  for argument in "${arguments[@]}"; do
    [[ "${argument}" == /* ]] && mkdir -p "${argument}"
  done
fi
if (( count >= 2 )) && [[ "${arguments[count-1]}" == "/etc/xingchen-agent/agent.json" ]]; then
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

cat > "${fake_bin}/timeout" <<'SCRIPT'
#!/usr/bin/env bash
printf 'timeout %s\n' "$*" >> "${TEST_LOG}"
shift
"$@"
SCRIPT

for command in systemctl useradd sleep; do
  cat > "${fake_bin}/${command}" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${TEST_LOG}"
SCRIPT
done

cat > "${fake_bin}/uname" <<'SCRIPT'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf 'Linux\n' ;;
  -m) printf 'x86_64\n' ;;
  *) printf 'Linux\n' ;;
esac
SCRIPT

cat > "${fake_bin}/id" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
chmod +x "${fake_bin}"/*

run_installer() {
  local docker_available="$1"
  shift
  local credential_environment=("XINGCHEN_AGENT_KEY=test-agent-key")
  if [[ "${TEST_USE_ENROLLMENT:-0}" == 1 ]]; then
    credential_environment=("XINGCHEN_ENROLLMENT_TOKEN=test-enrollment-token-0123456789_abcdefghijk")
  fi
  local environment=(
    "PATH=${fake_bin}:/usr/bin:/bin"
    "TEST_LOG=${log_file}"
    "TEST_CONFIG=${config_file}"
    "TEST_DOCKER_AVAILABLE=${docker_available}"
    "TEST_HTTPS_PROBE=${TEST_HTTPS_PROBE:-1}"
    "TEST_HTTP_PROBE=${TEST_HTTP_PROBE:-0}"
    "TEST_FAIL_AGENT_PULLS=${TEST_FAIL_AGENT_PULLS:-0}"
    "TEST_FAIL_GITEE_BUILD=${TEST_FAIL_GITEE_BUILD:-0}"
    "TEST_CONTROLLER_RELEASE=${TEST_CONTROLLER_RELEASE:-0}"
    "TEST_RELEASE_FILE=${TEST_RELEASE_FILE:-}"
    "TEST_RELEASE_SHA256=${TEST_RELEASE_SHA256:-}"
  "TEST_RELEASE_SIZE=${TEST_RELEASE_SIZE:-0}"
  "TEST_RELEASE_ARCHIVE=${TEST_RELEASE_ARCHIVE:-}"
    "XINGCHEN_REPOSITORY_URLS=${TEST_REPOSITORY_URLS:-}"
    "XINGCHEN_AGENT_IMAGE_MIRRORS=ghcr.io"
    "XINGCHEN_AGENT_MANAGER_ROOT=${temp_dir}/manager"
    "XINGCHEN_SYSTEMD_DIR=${temp_dir}/systemd"
    "XINGCHEN_LEGACY_AGENT_UPDATER_PATH=${temp_dir}/legacy-update-agent"
    "${credential_environment[@]}"
  )
  if [[ "${EUID}" -eq 0 ]]; then
    env "${environment[@]}" bash "${installer}" \
      --server-url "${server_url}" --device-id test-device --no-auto-update --docker "$@"
  else
    sudo env "${environment[@]}" bash "${installer}" \
      --server-url "${server_url}" --device-id test-device --no-auto-update --docker "$@"
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
    "XINGCHEN_AGENT_IMAGE_MIRRORS=ghcr.io"
    "XINGCHEN_AGENT_MANAGER_ROOT=${temp_dir}/manager"
    "XINGCHEN_SYSTEMD_DIR=${temp_dir}/systemd"
    "XINGCHEN_LEGACY_AGENT_UPDATER_PATH=${temp_dir}/legacy-update-agent"
    "XINGCHEN_AGENT_KEY=test-agent-key"
  )
  if [[ "${EUID}" -eq 0 ]]; then
    env "${environment[@]}" bash -s -- \
    --server-url "${server_url}" --device-id test-device --no-auto-update --docker "$@" < "${installer}"
  else
    sudo env "${environment[@]}" bash -s -- \
    --server-url "${server_url}" --device-id test-device --no-auto-update --docker "$@" < "${installer}"
  fi
}

: > "${log_file}"
server_url=https://monitor.example.com
run_installer 1
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-agent:v1.20.13' "${log_file}" >/dev/null
grep -F 'timeout 45s docker pull ghcr.io/pstarchen/monitor-for-server-agent:v1.20.13' "${log_file}" >/dev/null
grep -F 'docker run -d --name xingchen-agent --restart unless-stopped --pid host --network host' "${log_file}" >/dev/null
grep -F -- '--mount type=bind,src=/,dst=/host,readonly' "${log_file}" >/dev/null
grep -F '"host_root": "/host"' "${config_file}" >/dev/null
grep -F '"docker_socket": "/run/xingchen-agent-docker.sock"' "${config_file}" >/dev/null
grep -F '"allow_command_execution": false' "${config_file}" >/dev/null
grep -F '"allow_file_operations": false' "${config_file}" >/dev/null
run_as_root test -x "${temp_dir}/manager/update-agent.sh"
run_as_root bash -n "${temp_dir}/manager/update-agent.sh"
run_as_root grep -F 'command -v flock >/dev/null 2>&1 ||' "${temp_dir}/manager/update-agent.sh" >/dev/null
run_as_root grep -F "mirror_timeout='45'" "${temp_dir}/manager/update-agent.sh" >/dev/null
run_as_root grep -F "pull_timeout='120'" "${temp_dir}/manager/update-agent.sh" >/dev/null
run_as_root grep -F 'current="$(docker inspect --format "{{.Image}}" "${container_name}"' "${temp_dir}/manager/update-agent.sh" >/dev/null
if run_as_root grep -F 'before="$(docker image inspect' "${temp_dir}/manager/update-agent.sh" >/dev/null; then
  echo 'Agent updater still compares the local image before and after pulling.' >&2
  exit 1
fi
run_as_root grep -F 'CONTAINER_NAME=xingchen-agent' "${temp_dir}/manager/install.env" >/dev/null

: > "${log_file}"
server_url=https://monitor.example.com
TEST_USE_ENROLLMENT=1
run_installer 1
grep -F 'curl -fsS --connect-timeout 10 --max-time 30 --max-filesize 65536 --proto =https' "${log_file}" >/dev/null
grep -F '/api/agent/v1/enroll' "${log_file}" >/dev/null
grep -F '"agent_key": "enrolled-agent-key-0123456789_abcdefghijklmnopqrstuvwxyz"' "${config_file}" >/dev/null
if grep -F 'test-enrollment-token-0123456789_abcdefghijk' "${log_file}" >/dev/null; then
  echo 'Enrollment token leaked into a command log.' >&2
  exit 1
fi
TEST_USE_ENROLLMENT=0

: > "${log_file}"
manager_environment=(
  "PATH=${fake_bin}:/usr/bin:/bin"
  "TEST_LOG=${log_file}"
  "TEST_DOCKER_AVAILABLE=1"
  "TEST_CONTAINER_EXISTS=1"
  "TEST_CONTROLLER_RELEASE=1"
  "XINGCHEN_AGENT_MANAGER_ROOT=${temp_dir}/manager"
  "XINGCHEN_SYSTEMD_DIR=${temp_dir}/systemd"
  "XINGCHEN_LEGACY_AGENT_UPDATER_PATH=${temp_dir}/legacy-update-agent"
)
if [[ "${EUID}" -eq 0 ]]; then
  env "${manager_environment[@]}" bash "${installer}" update
else
  sudo env "${manager_environment[@]}" bash "${installer}" update
fi
grep -F 'docker image inspect --format {{.Id}} ghcr.io/pstarchen/monitor-for-server-agent:v1.20.13' "${log_file}" >/dev/null
grep -F 'docker inspect --format {{.Image}} xingchen-agent' "${log_file}" >/dev/null
grep -F 'docker rename xingchen-agent xingchen-agent.previous' "${log_file}" >/dev/null
grep -F 'docker rename xingchen-agent.update xingchen-agent' "${log_file}" >/dev/null

: > "${log_file}"
server_url=https://monitor.example.com
TEST_FAIL_AGENT_PULLS=1
TEST_FAIL_GITEE_BUILD=1
TEST_REPOSITORY_URLS='https://gitee.com/starchen520/monitor-for-server.git,https://github.com/Pstarchen/monitor-for-server.git'
run_installer 1
grep -F 'docker build --pull --build-arg VERSION=v1.20.13 --tag ghcr.io/pstarchen/monitor-for-server-agent:v1.20.13 https://gitee.com/starchen520/monitor-for-server.git#v1.20.13:agent' "${log_file}" >/dev/null
grep -F 'docker build --pull --build-arg VERSION=v1.20.13 --tag ghcr.io/pstarchen/monitor-for-server-agent:v1.20.13 https://github.com/Pstarchen/monitor-for-server.git#v1.20.13:agent' "${log_file}" >/dev/null
TEST_FAIL_AGENT_PULLS=0
TEST_FAIL_GITEE_BUILD=0
TEST_REPOSITORY_URLS=''

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
run_installer 1 --system-logs
grep -F '"collect_system_logs": true' "${config_file}" >/dev/null

: > "${log_file}"
server_url=https://monitor.example.com
run_installer 0
grep -F 'go build -trimpath' "${log_file}" >/dev/null
grep -F 'systemctl enable --now xingchen-agent.service' "${log_file}" >/dev/null
grep -F '"host_root": ""' "${config_file}" >/dev/null
grep -F '"docker_socket": "' "${config_file}" >/dev/null
if grep -q '^docker pull ' "${log_file}"; then
  echo 'Local fallback unexpectedly pulled the Agent image.' >&2
  exit 1
fi

: > "${log_file}"
release_fixture="${temp_dir}/release-fixture"
mkdir -p "${release_fixture}/content"
printf '#!/usr/bin/env bash\nexit 0\n' > "${release_fixture}/content/xingchen-agent"
chmod +x "${release_fixture}/content/xingchen-agent"
TEST_RELEASE_FILE=xingchen-agent_1.20.13_linux_amd64.tar.gz
TEST_RELEASE_ARCHIVE="${release_fixture}/${TEST_RELEASE_FILE}"
tar -czf "${TEST_RELEASE_ARCHIVE}" -C "${release_fixture}/content" xingchen-agent
TEST_RELEASE_SHA256="$(sha256sum "${TEST_RELEASE_ARCHIVE}" | awk '{print $1}')"
TEST_RELEASE_SIZE="$(wc -c < "${TEST_RELEASE_ARCHIVE}" | tr -d '[:space:]')"
TEST_CONTROLLER_RELEASE=1
server_url=https://monitor.example.com
run_installer 0 --native
grep -F 'api/setup/agent-release?os=linux&arch=amd64' "${log_file}" >/dev/null
grep -F 'api/setup/agent-artifact?os=linux&arch=amd64&version=v1.20.13' "${log_file}" >/dev/null
if grep -F 'api.github.com' "${log_file}" >/dev/null || grep -q '^go ' "${log_file}"; then
  echo 'Controller-served native install unexpectedly used GitHub API or a source build.' >&2
  exit 1
fi
TEST_CONTROLLER_RELEASE=0

: > "${log_file}"
bad_release="${release_fixture}/bad"
mkdir -p "${bad_release}"
printf '#!/usr/bin/env bash\nexit 0\n' > "${bad_release}/xingchen-agent"
printf 'unexpected\n' > "${bad_release}/extra-file"
TEST_RELEASE_ARCHIVE="${release_fixture}/bad-extra.tar.gz"
tar -czf "${TEST_RELEASE_ARCHIVE}" -C "${bad_release}" xingchen-agent extra-file
TEST_RELEASE_SHA256="$(sha256sum "${TEST_RELEASE_ARCHIVE}" | awk '{print $1}')"
TEST_RELEASE_SIZE="$(wc -c < "${TEST_RELEASE_ARCHIVE}" | tr -d '[:space:]')"
TEST_CONTROLLER_RELEASE=1
server_url=https://monitor.example.com
run_installer 0 --native
grep -F 'go build -trimpath' "${log_file}" >/dev/null
TEST_CONTROLLER_RELEASE=0

: > "${log_file}"
binary_path="${temp_dir}/prebuilt-agent"
touch "${binary_path}"
server_url=https://monitor.example.com
run_installer 1 --no-docker --binary "${binary_path}"
grep -F 'systemctl enable --now xingchen-agent.service' "${log_file}" >/dev/null
if grep -Eq '^(docker pull|go )' "${log_file}"; then
  echo 'Explicit binary path did not select the local Agent.' >&2
  exit 1
fi

: > "${log_file}"
server_url=https://monitor.example.com
run_installer 1 --binary "${binary_path}"
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-agent:v1.20.13' "${log_file}" >/dev/null
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
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-agent:v1.20.13' "${log_file}" >/dev/null
grep -F '"host_root": "/host"' "${config_file}" >/dev/null

: > "${log_file}"
server_url=monitor.example.com
TEST_HTTPS_PROBE=1
TEST_HTTP_PROBE=0
run_installer 1
grep -F 'curl -4 --fail --silent --show-error --location --max-redirs 0 --max-time 10 --connect-timeout 5 --proto =https' "${log_file}" >/dev/null
grep -F '"server_url": "https://monitor.example.com"' "${config_file}" >/dev/null

: > "${log_file}"
server_url=https://monitor.example.com
auto_update_environment=(
  "PATH=${fake_bin}:/usr/bin:/bin"
  "TEST_LOG=${log_file}"
  "TEST_CONFIG=${config_file}"
  "TEST_DOCKER_AVAILABLE=1"
  "XINGCHEN_AGENT_IMAGE_MIRRORS=ghcr.io"
  "XINGCHEN_AGENT_MANAGER_ROOT=${temp_dir}/manager"
  "XINGCHEN_SYSTEMD_DIR=${temp_dir}/systemd"
  "XINGCHEN_LEGACY_AGENT_UPDATER_PATH=${temp_dir}/legacy-update-agent"
  "XINGCHEN_AGENT_KEY=test-agent-key"
)
if [[ "${EUID}" -eq 0 ]]; then
  env "${auto_update_environment[@]}" bash "${installer}" \
    --server-url "${server_url}" --device-id test-device --docker
else
  sudo env "${auto_update_environment[@]}" bash "${installer}" \
    --server-url "${server_url}" --device-id test-device
fi
grep -F 'systemctl enable --now xingchen-agent-update.timer' "${log_file}" >/dev/null
grep -F 'ExecStart=' "${temp_dir}/systemd/xingchen-agent-update.service" | grep -F -- '--automatic' >/dev/null
grep -F 'pause_file="${update_state_dir}/update-paused-until"' "${temp_dir}/manager/update-agent.sh" >/dev/null
grep -F 'command -v flock >/dev/null 2>&1 ||' "${temp_dir}/manager/update-agent.sh" >/dev/null
grep -F 'version_for_update()' "${temp_dir}/manager/update-agent.sh" >/dev/null
grep -F 'image="$(versioned_image "${image}" "${version}")"' "${temp_dir}/manager/update-agent.sh" >/dev/null
grep -F 'verify_image_version "${image}" "${target_version}"' "${temp_dir}/manager/update-agent.sh" >/dev/null

: > "${log_file}"
run_as_root env \
  "PATH=${fake_bin}:/usr/bin:/bin" \
  "TEST_LOG=${log_file}" \
  "TEST_CONTROLLER_RELEASE=1" \
  "TEST_RELEASE_VERSION=v2.0.0" \
  "TEST_RELEASE_FILE=${TEST_RELEASE_FILE}" \
  "TEST_RELEASE_SHA256=${TEST_RELEASE_SHA256}" \
  "TEST_RELEASE_SIZE=${TEST_RELEASE_SIZE}" \
  "TEST_RUNNING_AGENT_VERSION=v1.20.13" \
  bash "${temp_dir}/manager/update-agent.sh" --automatic
if grep -Eq '^docker (pull|build|run) ' "${log_file}"; then
  echo 'Agent automatic update crossed a major version.' >&2
  exit 1
fi

rm -f "${temp_dir}/manager/update-failures" "${temp_dir}/manager/update-paused-until"
: > "${log_file}"
set +e
for attempt in 1 2 3 4 5; do
  env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "TEST_FAIL_AGENT_PULLS=1" "TEST_CONTROLLER_RELEASE=1" bash "${temp_dir}/manager/update-agent.sh" --automatic
  if [[ $? -eq 0 ]]; then
    echo "Automatic Agent update failure ${attempt} unexpectedly succeeded." >&2
    exit 1
  fi
done
set -e
grep -Fx '5' "${temp_dir}/manager/update-failures" >/dev/null
test -s "${temp_dir}/manager/update-paused-until"
pull_count_before="$(grep -c '^docker pull ' "${log_file}")"
env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "TEST_FAIL_AGENT_PULLS=1" "TEST_CONTROLLER_RELEASE=1" bash "${temp_dir}/manager/update-agent.sh" --automatic
pull_count_after="$(grep -c '^docker pull ' "${log_file}")"
if [[ "${pull_count_after}" -ne "${pull_count_before}" ]]; then
  echo 'Paused automatic Agent update still contacted an image source.' >&2
  exit 1
fi

failure_count_before="$(cat "${temp_dir}/manager/update-failures")"
pause_before="$(cat "${temp_dir}/manager/update-paused-until")"
set +e
env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "TEST_FAIL_AGENT_PULLS=1" "TEST_CONTROLLER_RELEASE=1" bash "${temp_dir}/manager/update-agent.sh"
manual_status=$?
set -e
if [[ "${manual_status}" -eq 0 ]]; then
  echo 'Manual Agent update failure unexpectedly succeeded.' >&2
  exit 1
fi
if [[ "$(cat "${temp_dir}/manager/update-failures")" != "${failure_count_before}" || "$(cat "${temp_dir}/manager/update-paused-until")" != "${pause_before}" ]]; then
  echo 'Manual Agent update failure changed automatic breaker state.' >&2
  exit 1
fi

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
if run_installer 1; then
  echo 'Remote HTTP fallback succeeded without explicit opt-in.' >&2
  exit 1
fi
if grep -Eq -- '(^|[[:space:]])--proto[[:space:]]+=http([[:space:]]|$)' "${log_file}"; then
  echo 'Installer probed remote HTTP before explicit opt-in.' >&2
  exit 1
fi
: > "${log_file}"
run_installer 1 --allow-insecure-http
grep -Eq 'curl -4 --fail --silent --show-error --location --max-redirs 0 --max-time 10 --connect-timeout 5 --proto =http([[:space:]]|$)' "${log_file}" >/dev/null
grep -F '"server_url": "http://monitor.example.com"' "${config_file}" >/dev/null
grep -F '"allow_insecure_http": true' "${config_file}" >/dev/null

: > "${log_file}"
server_url=http://monitor.example.com
if run_installer 1; then
  echo 'Explicit remote HTTP URL succeeded without explicit opt-in.' >&2
  exit 1
fi
run_installer 1 --allow-insecure-http
grep -F '"server_url": "http://monitor.example.com"' "${config_file}" >/dev/null
grep -F '"allow_insecure_http": true' "${config_file}" >/dev/null

echo 'install-agent.sh behavior tests passed.'
