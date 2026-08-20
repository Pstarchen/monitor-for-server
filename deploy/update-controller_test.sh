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
if [[ "${1:-}" == "pull" && ( "${2:-}" == ghcr.nju.edu.cn/* || "${2:-}" == ghcr.m.daocloud.io/* || "${2:-}" == ghcr.1ms.run/* ) ]]; then
  exit 1
fi
exit 0
SCRIPT
chmod +x "${fake_bin}/docker"

run_update() {
  env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" bash "${updater}" "$@"
}

: > "${log_file}"
run_update --check
grep -F 'docker pull ghcr.nju.edu.cn/pstarchen/monitor-for-server-server:latest' "${log_file}" >/dev/null
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-server:latest' "${log_file}" >/dev/null
if grep -q ' compose .* up ' "${log_file}"; then
  echo 'Check mode unexpectedly restarted controller services.' >&2
  exit 1
fi

: > "${log_file}"
run_update --apply --no-mirror
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-web:latest' "${log_file}" >/dev/null
grep -q 'docker compose .* up -d --remove-orphans' "${log_file}"

echo 'update-controller.sh behavior tests passed.'
