#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
updater="${script_dir}/update-controller.sh"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT
fake_bin="${temp_dir}/bin"
log_file="${temp_dir}/commands.log"
mkdir -p "${fake_bin}"

cat > "${fake_bin}/docker" <<'SCRIPT'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${TEST_LOG}"
if [[ "${1:-}" == "pull" && ( "${2:-}" == ghcr.nju.edu.cn/* || "${2:-}" == ghcr.1ms.run/* ) ]]; then
  exit 1
fi
exit 0
SCRIPT
chmod +x "${fake_bin}/docker"

cat > "${fake_bin}/uname" <<'SCRIPT'
#!/usr/bin/env bash
printf 'Linux\n'
SCRIPT
chmod +x "${fake_bin}/uname"

run_update() {
  env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=${TEST_CONTROLLER_AGENT_ENABLED:-false}" bash "${updater}" "$@"
}

: > "${log_file}"
run_update --check
grep -F 'docker pull ghcr.nju.edu.cn/pstarchen/monitor-for-server-server:latest' "${log_file}" >/dev/null
grep -F 'docker pull ghcr.1ms.run/pstarchen/monitor-for-server-server:latest' "${log_file}" >/dev/null
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-server:latest' "${log_file}" >/dev/null
if grep -q 'ghcr.m.daocloud.io' "${log_file}"; then
  echo 'Default mirror list still uses the unavailable DaoCloud public mirror.' >&2
  exit 1
fi
if grep -q ' compose .* up ' "${log_file}"; then
  echo 'Check mode unexpectedly restarted controller services.' >&2
  exit 1
fi

: > "${log_file}"
run_update --apply --no-mirror
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-web:latest' "${log_file}" >/dev/null
grep -q 'docker compose .* up -d --force-recreate --wait --wait-timeout 300 --remove-orphans' "${log_file}"
if grep -q 'controller-agent' "${log_file}"; then
  echo 'Update unexpectedly enabled controller Agent.' >&2
  exit 1
fi

: > "${log_file}"
TEST_CONTROLLER_AGENT_ENABLED=true run_update --apply --no-mirror
grep -q 'docker compose --profile host-monitoring .* up -d --force-recreate --wait --wait-timeout 300 --remove-orphans setup server web controller-agent' "${log_file}"

: > "${log_file}"
CONTROLLER_UPDATE_RUNNER=true run_update --apply --no-mirror
grep -q 'docker compose .* up -d --force-recreate --wait --wait-timeout 300 setup server web' "${log_file}"
if grep -q 'remove-orphans' "${log_file}"; then
  echo 'Update runner unexpectedly removed orphan containers.' >&2
  exit 1
fi

auto_root="${temp_dir}/auto-project"
mkdir -p "${auto_root}/deploy"
cp "${updater}" "${auto_root}/deploy/update-controller.sh"
printf '%s\n' 'POSTGRES_PASSWORD="test-only"' 'CONTROLLER_AUTO_UPDATE="false"' > "${auto_root}/.env"
: > "${log_file}"
env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" bash "${auto_root}/deploy/update-controller.sh" --auto
grep -F 'CONTROLLER_AUTO_UPDATE="true"' "${auto_root}/.env" >/dev/null
grep -q 'docker compose .* up -d --no-deps --wait --wait-timeout 300 setup' "${log_file}"

echo 'update-controller.sh behavior tests passed.'
