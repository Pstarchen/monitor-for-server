#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_updater="${script_dir}/update-controller.sh"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT
base_root="${temp_dir}/base-project"
mkdir -p "${base_root}/deploy"
cp "${source_updater}" "${base_root}/deploy/update-controller.sh"
printf '%s\n' 'POSTGRES_PASSWORD="test-only"' > "${base_root}/.env"
updater="${base_root}/deploy/update-controller.sh"
fake_bin="${temp_dir}/bin"
log_file="${temp_dir}/commands.log"
mkdir -p "${fake_bin}"

cat > "${fake_bin}/docker" <<'SCRIPT'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${TEST_LOG}"
if [[ "${1:-}" == "compose" && "$*" == *' ps -q '* && -n "${TEST_RUNNING_VERSION:-}" ]]; then
  printf 'container-%s\n' "${@: -1}"
  exit 0
fi
if [[ "${1:-}" == "inspect" && "${2:-}" == "--format" ]]; then
  if [[ "${3:-}" == *'org.opencontainers.image.version'* && -n "${TEST_RUNNING_VERSION:-}" ]]; then
    printf '%s\n' "${TEST_RUNNING_VERSION}"
  elif [[ "${3:-}" == *'.Image'* ]]; then
    printf 'sha256:old-image\n'
  fi
  exit 0
fi
if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  inspected="${@: -1}"
  if [[ "${TEST_MISSING_LOCAL_IMAGE:-false}" == "true" || ( -n "${TEST_MISSING_LOCAL_IMAGE_MATCH:-}" && "${inspected}" == *"${TEST_MISSING_LOCAL_IMAGE_MATCH}"* ) ]]; then
    exit 1
  fi
fi
if [[ "${1:-}" == "pull" && "${TEST_FAIL_ALL_PULLS:-false}" == "true" ]]; then
  exit 1
fi
if [[ "${1:-}" == "build" && "${TEST_FAIL_GITEE_BUILD:-false}" == "true" && "$*" == *gitee.com* ]]; then
  exit 1
fi
if [[ "${1:-}" == "pull" && ( "${2:-}" == ghcr.nju.edu.cn/* || "${2:-}" == ghcr.1ms.run/* || "${2:-}" == registry.internal.example/* ) ]]; then
  exit 1
fi
if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  if [[ "${4:-}" == *'.Id'* ]]; then
    printf 'sha256:old-image\n'
  else
    printf '%s\n' "${TEST_IMAGE_VERSION:-v1.20.5}"
  fi
  exit 0
fi
if [[ "${1:-}" == "compose" && "$*" == *' up '* ]]; then
  if [[ "${TEST_FAIL_COMPOSE_MODE:-}" == always ]]; then
    exit 1
  fi
  if [[ "${TEST_FAIL_COMPOSE_MODE:-}" == once && ! -f "${TEST_COMPOSE_STATE}" ]]; then
    : > "${TEST_COMPOSE_STATE}"
    exit 1
  fi
fi
exit 0
SCRIPT
chmod +x "${fake_bin}/docker"

cat > "${fake_bin}/timeout" <<'SCRIPT'
#!/usr/bin/env bash
printf 'timeout %s\n' "$*" >> "${TEST_LOG}"
shift
"$@"
SCRIPT
chmod +x "${fake_bin}/timeout"

cat > "${fake_bin}/flock" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${TEST_FLOCK_BUSY:-false}" == true ]]; then
  exit 1
fi
exit 0
SCRIPT
chmod +x "${fake_bin}/flock"

cat > "${fake_bin}/uname" <<'SCRIPT'
#!/usr/bin/env bash
printf 'Linux\n'
SCRIPT
chmod +x "${fake_bin}/uname"

cat > "${fake_bin}/df" <<'SCRIPT'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'testfs 4194304 1 %s 1%% /\n' "${TEST_FREE_KB:-2097152}"
SCRIPT
chmod +x "${fake_bin}/df"

run_update() {
  env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=${TEST_CONTROLLER_AGENT_ENABLED:-false}" \
    "TEST_FAIL_COMPOSE_MODE=${TEST_FAIL_COMPOSE_MODE:-}" "TEST_COMPOSE_STATE=${TEST_COMPOSE_STATE:-${temp_dir}/compose-state}" \
    "TEST_RUNNING_VERSION=${TEST_RUNNING_VERSION:-}" "TEST_MISSING_LOCAL_IMAGE_MATCH=${TEST_MISSING_LOCAL_IMAGE_MATCH:-}" \
    "TEST_FREE_KB=${TEST_FREE_KB:-2097152}" "TEST_FLOCK_BUSY=${TEST_FLOCK_BUSY:-false}" \
    "XINGCHEN_SOURCE_REPOSITORIES=${TEST_SOURCE_REPOSITORIES:-}" bash "${updater}" "$@"
}

: > "${log_file}"
run_update --check
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-server:v1.20.12' "${log_file}" >/dev/null
grep -F 'timeout 180s docker pull ghcr.io/pstarchen/monitor-for-server-server:v1.20.12' "${log_file}" >/dev/null
if grep -Eq 'ghcr\.(m\.daocloud\.io|1ms\.run|nju\.edu\.cn)' "${log_file}"; then
  echo 'Default update path still uses an unconfigured public mirror.' >&2
  exit 1
fi
if grep -q ' compose .* up ' "${log_file}"; then
  echo 'Check mode unexpectedly restarted controller services.' >&2
  exit 1
fi

: > "${log_file}"
set +e
TEST_FLOCK_BUSY=true run_update --check
lock_status=$?
set -e
if [[ "${lock_status}" -ne 75 ]]; then
  echo "Concurrent update lock returned ${lock_status}, want 75." >&2
  exit 1
fi
if grep -Eq '^docker (pull|build) ' "${log_file}"; then
  echo 'Concurrent update lock was checked after network image preparation.' >&2
  exit 1
fi

: > "${log_file}"
if TEST_FREE_KB=1 run_update --check; then
  echo 'Update continued with insufficient free disk space.' >&2
  exit 1
fi
if grep -Eq '^docker (pull|build) ' "${log_file}"; then
  echo 'Disk preflight ran after network image preparation.' >&2
  exit 1
fi

timeout_root="${temp_dir}/timeout-project"
mkdir -p "${timeout_root}/deploy"
cp "${updater}" "${timeout_root}/deploy/update-controller.sh"
printf '%s\n' \
  'POSTGRES_PASSWORD="test-only"' \
  'XINGCHEN_UPDATE_MIRROR_TIMEOUT_SECONDS="7"' \
  'XINGCHEN_CONTROLLER_IMAGE_MIRRORS="registry.internal.example"' \
  'XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS="11"' > "${timeout_root}/.env"
: > "${log_file}"
env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" bash "${timeout_root}/deploy/update-controller.sh" --check
grep -F 'timeout 7s docker pull registry.internal.example/pstarchen/monitor-for-server-server:v1.20.12' "${log_file}" >/dev/null
grep -F 'timeout 11s docker pull ghcr.io/pstarchen/monitor-for-server-server:v1.20.12' "${log_file}" >/dev/null

: > "${log_file}"
TEST_SOURCE_REPOSITORIES='https://gitee.com/starchen520/monitor-for-server.git,https://github.com/Pstarchen/monitor-for-server.git' \
  TEST_FAIL_ALL_PULLS=true TEST_FAIL_GITEE_BUILD=true run_update --check
grep -E 'docker build --pull --build-arg VERSION=dev --tag xingchen-controller-source-[^ ]+-0:candidate https://gitee.com/starchen520/monitor-for-server.git#main:setup' "${log_file}" >/dev/null
grep -E 'docker build --pull --build-arg VERSION=dev --tag xingchen-controller-source-[^ ]+-0:candidate https://github.com/Pstarchen/monitor-for-server.git#main:setup' "${log_file}" >/dev/null
grep -E 'docker tag xingchen-controller-source-[^ ]+-1:candidate ghcr.io/pstarchen/monitor-for-server-server:v1.20.12' "${log_file}" >/dev/null

: > "${log_file}"
if TEST_FAIL_ALL_PULLS=true run_update --check --no-source-fallback; then
  echo 'Update succeeded even though image pulls failed and source fallback was disabled.' >&2
  exit 1
fi
if grep -q 'docker build ' "${log_file}"; then
  echo 'Disabled source fallback still invoked docker build.' >&2
  exit 1
fi

: > "${log_file}"
run_update --apply --no-mirror
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-web:v1.20.12' "${log_file}" >/dev/null
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

: > "${log_file}"
rm -f "${temp_dir}/compose-state"
if TEST_FAIL_COMPOSE_MODE=once TEST_COMPOSE_STATE="${temp_dir}/compose-state" run_update --apply --no-mirror; then
  echo 'Update reported success even though the candidate health check failed.' >&2
  exit 1
fi
grep -F 'docker tag sha256:old-image ghcr.io/pstarchen/monitor-for-server-server:v1.20.12' "${log_file}" >/dev/null
if [[ "$(grep -c '^docker compose .* up -d --force-recreate --wait' "${log_file}")" -ne 2 ]]; then
  echo 'Rollback did not perform a second Compose health check.' >&2
  exit 1
fi

: > "${log_file}"
set +e
TEST_FAIL_COMPOSE_MODE=always run_update --apply --no-mirror
rollback_status=$?
set -e
if [[ "${rollback_status}" -ne 11 ]]; then
  echo "Rollback failure returned ${rollback_status}, want 11." >&2
  exit 1
fi

: > "${log_file}"
XINGCHEN_TARGET_VERSION=v1.20.5 TEST_IMAGE_VERSION=v1.20.5 run_update --apply --no-mirror
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-server:v1.20.5' "${log_file}" >/dev/null
grep -F 'docker image inspect --format {{index .Config.Labels "org.opencontainers.image.version"}} ghcr.io/pstarchen/monitor-for-server-server:v1.20.5' "${log_file}" >/dev/null
grep -F 'XINGCHEN_SERVER_IMAGE="ghcr.io/pstarchen/monitor-for-server-server:v1.20.5"' "${base_root}/.env" >/dev/null
grep -F 'XINGCHEN_TARGET_VERSION="v1.20.5"' "${base_root}/.env" >/dev/null
for key in XINGCHEN_SETUP_IMAGE XINGCHEN_SERVER_IMAGE XINGCHEN_WEB_IMAGE XINGCHEN_TARGET_VERSION; do
  if [[ "$(grep -c "^${key}=" "${base_root}/.env")" -ne 1 ]]; then
    echo "Update settings contain duplicate ${key} entries." >&2
    exit 1
  fi
done

: > "${log_file}"
if XINGCHEN_TARGET_VERSION=v1.20.5 TEST_IMAGE_VERSION=v1.20.4 run_update --check --no-mirror --no-source-fallback; then
  echo 'Update accepted an image from a different release.' >&2
  exit 1
fi

: > "${log_file}"
TEST_SOURCE_REPOSITORIES='https://gitee.com/starchen520/monitor-for-server.git,https://github.com/Pstarchen/monitor-for-server.git' \
  XINGCHEN_TARGET_VERSION=v1.20.5 TEST_FAIL_ALL_PULLS=true TEST_FAIL_GITEE_BUILD=true run_update --check
grep -E 'docker build --pull --build-arg VERSION=v1.20.5 --tag xingchen-controller-source-[^ ]+-0:candidate https://gitee.com/starchen520/monitor-for-server.git#v1.20.5:setup' "${log_file}" >/dev/null
grep -E 'docker build --pull --build-arg VERSION=v1.20.5 --tag xingchen-controller-source-[^ ]+-0:candidate https://github.com/Pstarchen/monitor-for-server.git#v1.20.5:setup' "${log_file}" >/dev/null

offline_root="${temp_dir}/offline-project"
mkdir -p "${offline_root}/deploy"
cp "${updater}" "${offline_root}/deploy/update-controller.sh"
printf '%s\n' 'POSTGRES_PASSWORD="test-only"' 'XINGCHEN_TARGET_VERSION="v1.20.12"' > "${offline_root}/.env"
: > "${log_file}"
env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" \
  "TEST_FAIL_ALL_PULLS=true" "TEST_IMAGE_VERSION=v1.20.12" bash "${offline_root}/deploy/update-controller.sh" --check --offline
if grep -Eq '^docker (pull|build) ' "${log_file}"; then
  echo 'Offline check attempted a registry pull or remote build.' >&2
  exit 1
fi
grep -F 'docker image inspect ghcr.io/pstarchen/monitor-for-server-server:v1.20.12' "${log_file}" >/dev/null

: > "${log_file}"
if env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" \
  "TEST_MISSING_LOCAL_IMAGE=true" "TEST_IMAGE_VERSION=v1.20.12" bash "${offline_root}/deploy/update-controller.sh" --check --offline; then
  echo 'Offline check succeeded with missing local images.' >&2
  exit 1
fi
if grep -Eq '^docker (pull|build) ' "${log_file}"; then
  echo 'Offline failure attempted a registry pull or remote build.' >&2
  exit 1
fi

: > "${log_file}"
if env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" \
  "TEST_MISSING_LOCAL_IMAGE_MATCH=postgres:16-alpine" "TEST_IMAGE_VERSION=v1.20.12" bash "${offline_root}/deploy/update-controller.sh" --check --offline; then
  echo 'Offline check succeeded without the PostgreSQL image.' >&2
  exit 1
fi
grep -F 'docker image inspect postgres:16-alpine' "${log_file}" >/dev/null
grep -F 'docker image inspect redis:7.4-alpine' "${log_file}" >/dev/null

downgrade_root="${temp_dir}/downgrade-project"
mkdir -p "${downgrade_root}/deploy"
cp "${updater}" "${downgrade_root}/deploy/update-controller.sh"
printf '%s\n' 'POSTGRES_PASSWORD="test-only"' 'XINGCHEN_TARGET_VERSION="v1.20.10"' > "${downgrade_root}/.env"
: > "${log_file}"
if env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" \
  "TEST_RUNNING_VERSION=v1.20.12" bash "${downgrade_root}/deploy/update-controller.sh" --check --no-mirror; then
  echo 'Controller downgrade was not rejected.' >&2
  exit 1
fi
if grep -Eq '^docker (pull|build) ' "${log_file}"; then
  echo 'Downgrade rejection happened after an image pull or build.' >&2
  exit 1
fi

same_root="${temp_dir}/same-version-project"
mkdir -p "${same_root}/deploy"
cp "${updater}" "${same_root}/deploy/update-controller.sh"
printf '%s\n' 'POSTGRES_PASSWORD="test-only"' 'XINGCHEN_TARGET_VERSION="v1.20.12"' > "${same_root}/.env"
: > "${log_file}"
env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" \
  "TEST_RUNNING_VERSION=v1.20.12" bash "${same_root}/deploy/update-controller.sh" --apply --no-mirror
if grep -Eq '^docker (pull|build) |^docker compose .* up ' "${log_file}"; then
  echo 'Same-version apply pulled images or restarted services.' >&2
  exit 1
fi

digest_root="${temp_dir}/digest-project"
mkdir -p "${digest_root}/deploy"
cp "${updater}" "${digest_root}/deploy/update-controller.sh"
digest='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
printf '%s\n' \
  'POSTGRES_PASSWORD="test-only"' \
  "XINGCHEN_SETUP_IMAGE=\"ghcr.io/pstarchen/monitor-for-server-setup@${digest}\"" \
  "XINGCHEN_SERVER_IMAGE=\"ghcr.io/pstarchen/monitor-for-server-server@${digest}\"" \
  "XINGCHEN_WEB_IMAGE=\"ghcr.io/pstarchen/monitor-for-server-web@${digest}\"" > "${digest_root}/.env"
: > "${log_file}"
rm -f "${temp_dir}/digest-compose-state"
set +e
env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" \
  "TEST_FAIL_COMPOSE_MODE=once" "TEST_COMPOSE_STATE=${temp_dir}/digest-compose-state" bash "${digest_root}/deploy/update-controller.sh" --apply --no-mirror
digest_status=$?
set -e
if [[ "${digest_status}" -ne 10 ]]; then
  echo "Digest rollback returned ${digest_status}, want 10." >&2
  exit 1
fi
if grep -F "docker tag sha256:old-image ghcr.io/pstarchen/monitor-for-server-server@${digest}" "${log_file}" >/dev/null; then
  echo 'Digest rollback attempted to retag an immutable reference.' >&2
  exit 1
fi
grep -E '^docker tag sha256:old-image xingchen-controller-rollback-server:[0-9]+$' "${log_file}" >/dev/null
grep -E '^XINGCHEN_SERVER_IMAGE="xingchen-controller-rollback-server:[0-9]+"$' "${digest_root}/.env" >/dev/null
if [[ "$(grep -c '^docker compose .* up -d --force-recreate --wait' "${log_file}")" -ne 2 ]]; then
  echo 'Digest rollback did not perform a second health check.' >&2
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
