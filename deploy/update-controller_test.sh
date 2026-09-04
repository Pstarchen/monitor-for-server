#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_dir}/.." && pwd)"
source_updater="${script_dir}/update-controller.sh"
source_installer="${script_dir}/install-controller.sh"
grep -F 'COPY deploy/update-controller.sh /usr/local/share/xingchen/updaters/update-controller.sh' "${repository_root}/setup/Dockerfile" >/dev/null
grep -Fx '!deploy/update-controller.sh' "${repository_root}/.dockerignore" >/dev/null
for build_option in --build --source-build; do
  if bash "${source_installer}" --network-mode internal "${build_option}" >/dev/null 2>&1; then
    echo "Controller installer accepted ${build_option} in internal mode." >&2
    exit 1
  fi
done
(
  source <(awk '/^host_matches\(\)/ { capture = 1 } /^# Registry downloads/ { exit } capture { print }' "${source_updater}")
  network_mode=internal
  allow_gitee=false
  for source_url in \
    https://api.github.com/example/repo.git \
    https://raw.githubusercontent.com/example/repo/main/file \
    https://cdn.githubassets.com/example/asset \
    https://cache.ghcr.io/example/repo.git \
    https://hub.docker.com/example/repo.git; do
    if validate_source_repository_policy "${source_url}" >/dev/null 2>&1; then
      echo "Internal Controller policy accepted public source: ${source_url}" >&2
      exit 1
    fi
  done
  validate_source_repository_policy https://github.com.evil.example/example/repo.git
  if validate_internal_image_reference registry.gitee.com/example/controller:v1.20.14 >/dev/null 2>&1; then
    echo 'Controller policy accepted a Gitee Registry without explicit opt-in.' >&2
    exit 1
  fi
  allow_gitee=true
  validate_internal_image_reference registry.gitee.com/example/controller:v1.20.14
)
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT
base_root="${temp_dir}/base-project"
mkdir -p "${base_root}/deploy"
cp "${source_updater}" "${base_root}/deploy/update-controller.sh"
printf '%s\n' 'POSTGRES_PASSWORD="test-only"' > "${base_root}/.env"
printf '%s\n' 'services: {}' > "${base_root}/docker-compose.yml"
updater="${base_root}/deploy/update-controller.sh"
fake_bin="${temp_dir}/bin"
log_file="${temp_dir}/commands.log"
mkdir -p "${fake_bin}"

cat > "${fake_bin}/docker" <<'SCRIPT'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${TEST_LOG}"
if [[ "${1:-}" == "compose" && "$*" == *' ps -q '* ]]; then
  service="${@: -1}"
  if [[ "${service}" == postgres && "${TEST_POSTGRES_CONTAINER_MISSING:-false}" != true ]]; then
    printf 'container-postgres\n'
  elif [[ -n "${TEST_RUNNING_VERSION:-}" ]]; then
    printf 'container-%s\n' "${service}"
  fi
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
if [[ "${1:-}" == "load" && "${TEST_FAIL_LOAD:-false}" == true ]]; then
  exit 1
fi
if [[ "${1:-}" == "compose" && "$*" == *' exec '* && "$*" == *'pg_dump'* && "${TEST_FAIL_BACKUP:-false}" == true ]]; then
  exit 1
fi
if [[ "${1:-}" == "cp" ]]; then
  if [[ "${TEST_FAIL_BACKUP_COPY:-false}" == true ]]; then
    exit 1
  fi
  destination="${@: -1}"
  printf '%s\n' '-- test PostgreSQL backup' > "${destination}"
  exit 0
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
  elif [[ "${4:-}" == *'.Architecture'* ]]; then
    printf '%s\n' "${TEST_IMAGE_ARCH:-amd64}"
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
if [[ "${1:-}" == -m ]]; then
  printf '%s\n' "${TEST_UNAME_MACHINE:-x86_64}"
else
  printf 'Linux\n'
fi
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
    "TEST_MISSING_LOCAL_IMAGE=${TEST_MISSING_LOCAL_IMAGE:-false}" "TEST_IMAGE_VERSION=${TEST_IMAGE_VERSION:-v1.20.5}" \
    "TEST_IMAGE_ARCH=${TEST_IMAGE_ARCH:-amd64}" \
    "TEST_FAIL_BACKUP=${TEST_FAIL_BACKUP:-false}" "TEST_FAIL_BACKUP_COPY=${TEST_FAIL_BACKUP_COPY:-false}" \
    "TEST_FAIL_LOAD=${TEST_FAIL_LOAD:-false}" "TEST_POSTGRES_CONTAINER_MISSING=${TEST_POSTGRES_CONTAINER_MISSING:-false}" \
    "TEST_UNAME_MACHINE=${TEST_UNAME_MACHINE:-x86_64}" \
    "TEST_FREE_KB=${TEST_FREE_KB:-2097152}" "TEST_FLOCK_BUSY=${TEST_FLOCK_BUSY:-false}" \
    "XINGCHEN_SOURCE_REPOSITORIES=${TEST_SOURCE_REPOSITORIES:-}" \
    "XINGCHEN_NETWORK_MODE=${TEST_NETWORK_MODE:-}" "XINGCHEN_ALLOW_GITEE=${TEST_ALLOW_GITEE:-}" \
    "CONTROLLER_UPDATE_RUNNER=${TEST_CONTROLLER_UPDATE_RUNNER:-false}" "SETUP_WORKSPACE=${TEST_SETUP_WORKSPACE:-}" \
    bash "${TEST_UPDATER:-${updater}}" "$@"
}

create_upgrade_project() {
  local root="$1"
  mkdir -p "${root}/deploy"
  cp "${source_updater}" "${root}/deploy/update-controller.sh"
  cp "${script_dir}/update-controller.ps1" "${root}/deploy/update-controller.ps1"
  chmod 755 "${root}/deploy/update-controller.sh"
  printf '%s\n' \
    '# preserve this file byte-for-byte on failure' \
    'POSTGRES_PASSWORD="test-only"' \
    'COMPOSE_PROJECT_NAME="xingchen-monitor"' \
    'SITE_NAME="离线升级测试"' > "${root}/.env"
  printf '%s\n' 'name: old-controller' 'services: {}' > "${root}/docker-compose.yml"
}

create_agent_release() {
  local root="$1" version="$2" version_number="${2#v}" index separator="" asset hash size os_name arch
  local platforms=(linux:amd64 linux:arm64 windows:amd64 windows:arm64)
  local files=()
  mkdir -p "${root}/assets"
  for index in "${!platforms[@]}"; do
    IFS=: read -r os_name arch <<< "${platforms[${index}]}"
    if [[ "${os_name}" == linux ]]; then
      asset="xingchen-agent_${version_number}_${os_name}_${arch}.tar.gz"
    else
      asset="xingchen-agent_${version_number}_${os_name}_${arch}.zip"
    fi
    printf 'Agent fixture for %s/%s\n' "${os_name}" "${arch}" > "${root}/assets/${asset}"
    files+=("${asset}")
  done
  (
    cd "${root}/assets"
    sha256sum "${files[@]}" > checksums.txt
  )
  {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "version": "%s",\n' "${version}"
    printf '  "publishedAt": "2026-09-04T00:00:00Z",\n'
    printf '  "minimumCompatibleControllerVersion": "v1.20.0",\n'
    printf '  "assets": [\n'
    for index in "${!platforms[@]}"; do
      IFS=: read -r os_name arch <<< "${platforms[${index}]}"
      asset="${files[${index}]}"
      hash="$(sha256sum "${root}/assets/${asset}" | awk '{print $1}')"
      size="$(wc -c < "${root}/assets/${asset}" | tr -d '[:space:]')"
      [[ "${index}" -eq 3 ]] && separator='' || separator=','
      printf '    {\n'
      printf '      "os": "%s",\n' "${os_name}"
      printf '      "arch": "%s",\n' "${arch}"
      printf '      "file": "%s",\n' "${asset}"
      printf '      "url": "https://releases.example.invalid/%s/%s",\n' "${version}" "${asset}"
      printf '      "sha256": "%s",\n' "${hash}"
      printf '      "size": %s\n' "${size}"
      printf '    }%s\n' "${separator}"
    done
    printf '  ]\n}\n'
  } > "${root}/manifest.json"
}

create_test_image_archive() {
  local output="$1" version="$2" omitted_component="${3:-}" extra_component="${4:-}" component image config layer separator=""
  local image_root="${temp_dir}/docker-archive-$RANDOM-$RANDOM"
  local archive_files=()
  local components=(setup server web agent postgres redis)
  [[ -z "${extra_component}" ]] || components+=("${extra_component}")
  mkdir -p "${image_root}"
  printf '[' > "${image_root}/manifest.json"
  for component in "${components[@]}"; do
    [[ "${component}" != "${omitted_component}" ]] || continue
    case "${component}" in
      setup|server|web|agent) image="ghcr.io/pstarchen/monitor-for-server-${component}:${version}" ;;
      postgres) image='postgres:16-alpine' ;;
      redis) image='redis:7.4-alpine' ;;
      *) image="registry.internal.example/xingchen/${component}:${version}" ;;
    esac
    config="${component}.json"
    layer="${component}/layer.tar"
    mkdir -p "${image_root}/${component}"
    printf '{"architecture":"amd64"}\n' > "${image_root}/${config}"
    printf 'layer for %s\n' "${component}" > "${image_root}/${layer}"
    printf '%s{"Config":"%s","RepoTags":["%s"],"Layers":["%s"]}' \
      "${separator}" "${config}" "${image}" "${layer}" >> "${image_root}/manifest.json"
    separator=,
    archive_files+=("${config}" "${layer}")
  done
  printf ']\n' >> "${image_root}/manifest.json"
  tar -C "${image_root}" -cf "${output}" manifest.json "${archive_files[@]}"
}

refresh_offline_bundle_checksums() {
  local root="$1"
  (
    cd "${root}"
    find deploy images release -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS
    sha256sum bundle-metadata.txt docker-compose.yml upgrade-offline.sh upgrade-offline.ps1 >> SHA256SUMS
  )
}

create_offline_bundle() {
  local root="$1" architecture="$2"
  mkdir -p "${root}/deploy" "${root}/images" "${root}/release/assets"
  cp "${source_updater}" "${root}/deploy/update-controller.sh"
  cp "${script_dir}/update-controller.ps1" "${root}/deploy/update-controller.ps1"
  cp "${script_dir}/offline-bundle-integrity.sh" "${root}/deploy/offline-bundle-integrity.sh"
  printf '%s\n' 'name: bundled-controller' 'services: {}' > "${root}/docker-compose.yml"
  printf 'schema=1\nversion=v1.20.14\narchitecture=%s\n' "${architecture}" > "${root}/bundle-metadata.txt"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${root}/upgrade-offline.sh"
  printf '%s\n' "\$ErrorActionPreference = 'Stop'" > "${root}/upgrade-offline.ps1"
  create_agent_release "${root}/release" v1.20.14
  create_test_image_archive "${root}/images/controller-images.tar" v1.20.14
  refresh_offline_bundle_checksums "${root}"
}

packaged_root="${temp_dir}/image/usr/local/share/xingchen"
packaged_updater="${packaged_root}/updaters/update-controller.sh"
runner_root="${temp_dir}/runner-project"
mkdir -p "${packaged_root}/updaters" "${runner_root}"
cp "${source_updater}" "${packaged_updater}"
printf '%s\n' 'POSTGRES_PASSWORD="test-only"' 'XINGCHEN_TARGET_VERSION="v1.20.5"' > "${runner_root}/.env"
printf '%s\n' 'services: {}' > "${runner_root}/docker-compose.yml"
: > "${log_file}"
TEST_UPDATER="${packaged_updater}" TEST_CONTROLLER_UPDATE_RUNNER=true TEST_SETUP_WORKSPACE="${runner_root}" run_update --check --no-mirror
grep -F "docker compose -f ${runner_root}/docker-compose.yml --project-directory ${runner_root} --env-file ${runner_root}/.env" "${log_file}" >/dev/null
if [[ ! -f "${runner_root}/.controller-update.lock" || -e "${packaged_root}/.controller-update.lock" ]]; then
  echo 'Packaged updater did not keep mutable update state in SETUP_WORKSPACE.' >&2
  exit 1
fi

if TEST_UPDATER="${packaged_updater}" TEST_CONTROLLER_UPDATE_RUNNER=true TEST_SETUP_WORKSPACE=relative run_update --check --no-mirror; then
  echo 'Update runner accepted a relative SETUP_WORKSPACE.' >&2
  exit 1
fi
missing_compose_root="${temp_dir}/missing-compose-project"
mkdir -p "${missing_compose_root}"
printf '%s\n' 'POSTGRES_PASSWORD="test-only"' > "${missing_compose_root}/.env"
if TEST_UPDATER="${packaged_updater}" TEST_CONTROLLER_UPDATE_RUNNER=true TEST_SETUP_WORKSPACE="${missing_compose_root}" run_update --check --no-mirror; then
  echo 'Update runner accepted SETUP_WORKSPACE without docker-compose.yml.' >&2
  exit 1
fi

: > "${log_file}"
run_update --check
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-server:v1.20.15' "${log_file}" >/dev/null
grep -F 'timeout 180s docker pull ghcr.io/pstarchen/monitor-for-server-server:v1.20.15' "${log_file}" >/dev/null
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
grep -F 'timeout 7s docker pull registry.internal.example/pstarchen/monitor-for-server-server:v1.20.15' "${log_file}" >/dev/null
grep -F 'timeout 11s docker pull ghcr.io/pstarchen/monitor-for-server-server:v1.20.15' "${log_file}" >/dev/null

: > "${log_file}"
TEST_SOURCE_REPOSITORIES='https://gitee.com/starchen520/monitor-for-server.git,https://github.com/Pstarchen/monitor-for-server.git' \
  TEST_ALLOW_GITEE=true TEST_FAIL_ALL_PULLS=true TEST_FAIL_GITEE_BUILD=true run_update --check
grep -E 'docker build --pull --file setup/Dockerfile --build-arg VERSION=dev --tag xingchen-controller-source-[^ ]+-0:candidate https://gitee.com/starchen520/monitor-for-server.git#main$' "${log_file}" >/dev/null
grep -E 'docker build --pull --file setup/Dockerfile --build-arg VERSION=dev --tag xingchen-controller-source-[^ ]+-0:candidate https://github.com/Pstarchen/monitor-for-server.git#main$' "${log_file}" >/dev/null
grep -E 'docker tag xingchen-controller-source-[^ ]+-1:candidate ghcr.io/pstarchen/monitor-for-server-server:v1.20.15' "${log_file}" >/dev/null

: > "${log_file}"
if TEST_FAIL_ALL_PULLS=true run_update --check --no-mirror; then
  echo 'Update succeeded even though image pulls failed and no source repositories were configured.' >&2
  exit 1
fi
if grep -Eiq '^docker build |github\.com|gitee\.com' "${log_file}"; then
  echo 'Empty source repository configuration invoked an implicit public source fallback.' >&2
  exit 1
fi

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
if TEST_NETWORK_MODE=internal run_update --check --no-source-fallback; then
  echo 'Internal mode accepted default GHCR and hostless base image references.' >&2
  exit 1
fi
if grep -Eq '^docker (pull|build) ' "${log_file}"; then
  echo 'Internal policy rejection happened after a network operation.' >&2
  exit 1
fi

internal_root="${temp_dir}/internal-project"
create_upgrade_project "${internal_root}"
printf '%s\n' \
  'XINGCHEN_NETWORK_MODE="internal"' \
  'XINGCHEN_TARGET_VERSION="v1.20.5"' \
  'XINGCHEN_SETUP_IMAGE="registry.corp.example/xingchen/setup:v1.20.4"' \
  'XINGCHEN_SERVER_IMAGE="registry.corp.example/xingchen/server:v1.20.4"' \
  'XINGCHEN_WEB_IMAGE="registry.corp.example/xingchen/web:v1.20.4"' \
  'XINGCHEN_POSTGRES_IMAGE="registry.corp.example/base/postgres:16"' \
  'XINGCHEN_REDIS_IMAGE="registry.corp.example/base/redis:7.4"' >> "${internal_root}/.env"
: > "${log_file}"
TEST_IMAGE_VERSION=v1.20.5 env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" \
  bash "${internal_root}/deploy/update-controller.sh" --check --no-mirror --no-source-fallback
grep -F 'docker pull registry.corp.example/xingchen/server:v1.20.5' "${log_file}" >/dev/null
if grep -Eiq 'docker (pull|build) .*github|docker pull ghcr\.io|docker pull (postgres|redis):' "${log_file}"; then
  echo 'Internal mode attempted a forbidden public endpoint.' >&2
  exit 1
fi

for build_option in --build --source-build; do
  : > "${log_file}"
  if env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" \
    bash "${internal_root}/deploy/update-controller.sh" --check "${build_option}"; then
    echo "Internal Controller updater accepted ${build_option}." >&2
    exit 1
  fi
  if grep -Eq '^docker (pull|build) ' "${log_file}"; then
    echo "Internal ${build_option} rejection occurred after a network/build operation." >&2
    exit 1
  fi
done

: > "${log_file}"
if TEST_FAIL_ALL_PULLS=true env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" \
  bash "${internal_root}/deploy/update-controller.sh" --check --no-mirror; then
  echo 'Internal Controller pull failure unexpectedly succeeded.' >&2
  exit 1
fi
if grep -Eq '^docker build ' "${log_file}"; then
  echo 'Internal Controller pull failure invoked source fallback.' >&2
  exit 1
fi

internal_mirror_root="${temp_dir}/internal-mirror-project"
create_upgrade_project "${internal_mirror_root}"
printf '%s\n' \
  'XINGCHEN_NETWORK_MODE="internal"' \
  'XINGCHEN_TARGET_VERSION="v1.20.5"' \
  'XINGCHEN_CONTROLLER_IMAGE_MIRRORS="registry.corp.example"' \
  'XINGCHEN_POSTGRES_IMAGE="registry.corp.example/base/postgres:16"' \
  'XINGCHEN_REDIS_IMAGE="registry.corp.example/base/redis:7.4"' >> "${internal_mirror_root}/.env"
: > "${log_file}"
TEST_IMAGE_VERSION=v1.20.5 env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" \
  bash "${internal_mirror_root}/deploy/update-controller.sh" --check
grep -F 'docker pull registry.corp.example/pstarchen/monitor-for-server-server:v1.20.5' "${log_file}" >/dev/null
if grep -Eq '^docker pull ghcr\.io/' "${log_file}"; then
  echo 'Internal mirror flow fell back to GHCR.' >&2
  exit 1
fi

internal_hostless_root="${temp_dir}/internal-hostless-project"
create_upgrade_project "${internal_hostless_root}"
printf '%s\n' \
  'XINGCHEN_NETWORK_MODE="internal"' \
  'XINGCHEN_TARGET_VERSION="v1.20.5"' \
  'XINGCHEN_CONTROLLER_IMAGE_MIRRORS="registry.corp.example"' >> "${internal_hostless_root}/.env"
: > "${log_file}"
if env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" \
  bash "${internal_hostless_root}/deploy/update-controller.sh" --check; then
  echo 'Internal mode accepted hostless PostgreSQL/Redis images.' >&2
  exit 1
fi
if grep -Eq '^docker (pull|build) ' "${log_file}"; then
  echo 'Hostless dependency rejection happened after a network operation.' >&2
  exit 1
fi

: > "${log_file}"
if TEST_SOURCE_REPOSITORIES='https://gitee.com/starchen520/monitor-for-server.git' \
  TEST_FAIL_ALL_PULLS=true run_update --check; then
  echo 'Gitee source was accepted without XINGCHEN_ALLOW_GITEE=true.' >&2
  exit 1
fi
if grep -Eq '^docker (pull|build) ' "${log_file}"; then
  echo 'Gitee policy rejection happened after a network operation.' >&2
  exit 1
fi

: > "${log_file}"
run_update --apply --no-mirror
grep -F 'docker pull ghcr.io/pstarchen/monitor-for-server-web:v1.20.15' "${log_file}" >/dev/null
grep -q 'docker compose .* up -d --force-recreate --wait --wait-timeout 300 --remove-orphans' "${log_file}"
if grep -q 'controller-agent' "${log_file}"; then
  echo 'Update unexpectedly enabled controller Agent.' >&2
  exit 1
fi

: > "${log_file}"
TEST_CONTROLLER_AGENT_ENABLED=true run_update --apply --no-mirror
grep -q 'docker compose --profile host-monitoring .* up -d --force-recreate --wait --wait-timeout 300 --remove-orphans setup server web controller-agent' "${log_file}"

: > "${log_file}"
TEST_CONTROLLER_UPDATE_RUNNER=true TEST_SETUP_WORKSPACE="${base_root}" run_update --apply --no-mirror
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
grep -F 'docker tag sha256:old-image ghcr.io/pstarchen/monitor-for-server-server:v1.20.15' "${log_file}" >/dev/null
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
if XINGCHEN_TARGET_VERSION=v01.20.5 TEST_IMAGE_VERSION=v1.20.5 run_update --check --no-mirror --no-source-fallback; then
  echo 'Controller updater accepted a leading-zero target version.' >&2
  exit 1
fi
if grep -Eq '^docker (pull|build) ' "${log_file}"; then
  echo 'Controller updater accessed an image source before rejecting a leading-zero version.' >&2
  exit 1
fi

: > "${log_file}"
if XINGCHEN_TARGET_VERSION=v1.20.5 TEST_IMAGE_VERSION=v1.20.4 run_update --check --no-mirror --no-source-fallback; then
  echo 'Update accepted an image from a different release.' >&2
  exit 1
fi

: > "${log_file}"
TEST_SOURCE_REPOSITORIES='https://gitee.com/starchen520/monitor-for-server.git,https://github.com/Pstarchen/monitor-for-server.git' \
  TEST_ALLOW_GITEE=true XINGCHEN_TARGET_VERSION=v1.20.5 TEST_FAIL_ALL_PULLS=true TEST_FAIL_GITEE_BUILD=true run_update --check
grep -E 'docker build --pull --file setup/Dockerfile --build-arg VERSION=v1.20.5 --tag xingchen-controller-source-[^ ]+-0:candidate https://gitee.com/starchen520/monitor-for-server.git#v1.20.5$' "${log_file}" >/dev/null
grep -E 'docker build --pull --file setup/Dockerfile --build-arg VERSION=v1.20.5 --tag xingchen-controller-source-[^ ]+-0:candidate https://github.com/Pstarchen/monitor-for-server.git#v1.20.5$' "${log_file}" >/dev/null

offline_root="${temp_dir}/offline-project"
mkdir -p "${offline_root}/deploy"
cp "${updater}" "${offline_root}/deploy/update-controller.sh"
printf '%s\n' 'POSTGRES_PASSWORD="test-only"' 'XINGCHEN_TARGET_VERSION="v1.20.14"' > "${offline_root}/.env"
: > "${log_file}"
env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" \
  "TEST_FAIL_ALL_PULLS=true" "TEST_IMAGE_VERSION=v1.20.14" bash "${offline_root}/deploy/update-controller.sh" --check --offline
if grep -Eq '^docker (pull|build) ' "${log_file}"; then
  echo 'Offline check attempted a registry pull or remote build.' >&2
  exit 1
fi
grep -F 'docker image inspect ghcr.io/pstarchen/monitor-for-server-server:v1.20.14' "${log_file}" >/dev/null

: > "${log_file}"
if env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" \
  "TEST_MISSING_LOCAL_IMAGE=true" "TEST_IMAGE_VERSION=v1.20.14" bash "${offline_root}/deploy/update-controller.sh" --check --offline; then
  echo 'Offline check succeeded with missing local images.' >&2
  exit 1
fi
if grep -Eq '^docker (pull|build) ' "${log_file}"; then
  echo 'Offline failure attempted a registry pull or remote build.' >&2
  exit 1
fi

: > "${log_file}"
if env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" \
  "TEST_MISSING_LOCAL_IMAGE_MATCH=postgres:16-alpine" "TEST_IMAGE_VERSION=v1.20.14" bash "${offline_root}/deploy/update-controller.sh" --check --offline; then
  echo 'Offline check succeeded without the PostgreSQL image.' >&2
  exit 1
fi
grep -F 'docker image inspect postgres:16-alpine' "${log_file}" >/dev/null
grep -F 'docker image inspect redis:7.4-alpine' "${log_file}" >/dev/null

bundle_root="${temp_dir}/offline-bundle"
create_offline_bundle "${bundle_root}" amd64

bundle_check_root="${temp_dir}/bundle-check-project"
create_upgrade_project "${bundle_check_root}"
cp "${bundle_check_root}/.env" "${temp_dir}/bundle-check.env.before"
cp "${bundle_check_root}/docker-compose.yml" "${temp_dir}/bundle-check.compose.before"
: > "${log_file}"
TEST_RUNNING_VERSION=v1.20.13 TEST_IMAGE_VERSION=v1.20.14 run_update \
  --project-root "${bundle_check_root}" --offline-bundle "${bundle_root}"
cmp -s "${temp_dir}/bundle-check.env.before" "${bundle_check_root}/.env"
cmp -s "${temp_dir}/bundle-check.compose.before" "${bundle_check_root}/docker-compose.yml"
if grep -Eq '^docker (load|pull|build|cp) |pg_dump|^docker compose .* up ' "${log_file}"; then
  echo 'Default bundle check performed a mutating or network operation.' >&2
  exit 1
fi
if [[ -e "${bundle_check_root}/release/versions/v1.20.14" ]]; then
  echo 'Default bundle check copied release files.' >&2
  exit 1
fi
if [[ -e "${bundle_check_root}/.controller-update.lock" || -e "${bundle_check_root}/backups" ]] \
  || compgen -G "${bundle_check_root}/.controller-update-snapshot.*" >/dev/null; then
  echo 'Default bundle check wrote transaction state.' >&2
  exit 1
fi

tampered_bundle="${temp_dir}/tampered-bundle"
cp -R "${bundle_root}" "${tampered_bundle}"
printf '%s\n' '# tampered' >> "${tampered_bundle}/docker-compose.yml"
: > "${log_file}"
if TEST_RUNNING_VERSION=v1.20.13 TEST_IMAGE_VERSION=v1.20.14 run_update \
  --project-root "${bundle_check_root}" --offline-bundle "${tampered_bundle}"; then
  echo 'Tampered offline bundle passed verification.' >&2
  exit 1
fi
if grep -Eq '^docker (load|pull|build) ' "${log_file}"; then
  echo 'Tampered bundle reached image preparation.' >&2
  exit 1
fi

missing_archive_image_bundle="${temp_dir}/missing-archive-image-bundle"
cp -R "${bundle_root}" "${missing_archive_image_bundle}"
create_test_image_archive "${missing_archive_image_bundle}/images/controller-images.tar" v1.20.14 redis
refresh_offline_bundle_checksums "${missing_archive_image_bundle}"
: > "${log_file}"
if TEST_RUNNING_VERSION=v1.20.13 TEST_IMAGE_VERSION=v1.20.14 run_update \
  --project-root "${bundle_check_root}" --offline-bundle "${missing_archive_image_bundle}"; then
  echo 'Bundle check accepted an image archive without Redis.' >&2
  exit 1
fi
if grep -Eq '^docker (load|pull|build) ' "${log_file}"; then
  echo 'Missing archive image was detected only after image preparation.' >&2
  exit 1
fi

extra_archive_image_bundle="${temp_dir}/extra-archive-image-bundle"
cp -R "${bundle_root}" "${extra_archive_image_bundle}"
create_test_image_archive "${extra_archive_image_bundle}/images/controller-images.tar" v1.20.14 '' unexpected
refresh_offline_bundle_checksums "${extra_archive_image_bundle}"
: > "${log_file}"
if TEST_RUNNING_VERSION=v1.20.13 TEST_IMAGE_VERSION=v1.20.14 run_update \
  --project-root "${bundle_check_root}" --offline-bundle "${extra_archive_image_bundle}"; then
  echo 'Bundle check accepted an image archive with an unexpected seventh image.' >&2
  exit 1
fi
if grep -Eq '^docker (load|pull|build) ' "${log_file}"; then
  echo 'Unexpected archive image was detected only after image preparation.' >&2
  exit 1
fi

manifest_size_bundle="${temp_dir}/manifest-size-bundle"
cp -R "${bundle_root}" "${manifest_size_bundle}"
awk 'BEGIN { changed = 0 } !changed && /"size": [0-9]+/ { sub(/"size": [0-9]+/, "\"size\": 999999"); changed = 1 } { print }' \
  "${bundle_root}/release/manifest.json" > "${manifest_size_bundle}/release/manifest.json"
refresh_offline_bundle_checksums "${manifest_size_bundle}"
: > "${log_file}"
if TEST_RUNNING_VERSION=v1.20.13 TEST_IMAGE_VERSION=v1.20.14 run_update \
  --project-root "${bundle_check_root}" --offline-bundle "${manifest_size_bundle}"; then
  echo 'Bundle check accepted an Agent manifest with an incorrect size.' >&2
  exit 1
fi
if grep -Eq '^docker (load|pull|build) ' "${log_file}"; then
  echo 'Agent manifest mismatch was detected only after image preparation.' >&2
  exit 1
fi

checksums_mismatch_bundle="${temp_dir}/checksums-mismatch-bundle"
cp -R "${bundle_root}" "${checksums_mismatch_bundle}"
awk 'NR == 1 { $1 = "0000000000000000000000000000000000000000000000000000000000000000" } { print }' \
  "${bundle_root}/release/assets/checksums.txt" > "${checksums_mismatch_bundle}/release/assets/checksums.txt"
refresh_offline_bundle_checksums "${checksums_mismatch_bundle}"
: > "${log_file}"
if TEST_RUNNING_VERSION=v1.20.13 TEST_IMAGE_VERSION=v1.20.14 run_update \
  --project-root "${bundle_check_root}" --offline-bundle "${checksums_mismatch_bundle}"; then
  echo 'Bundle check accepted checksums.txt that disagrees with the Agent manifest.' >&2
  exit 1
fi
if grep -Eq '^docker (load|pull|build) ' "${log_file}"; then
  echo 'Agent checksum mismatch was detected only after image preparation.' >&2
  exit 1
fi

arm_bundle="${temp_dir}/arm-bundle"
create_offline_bundle "${arm_bundle}" arm64
: > "${log_file}"
if TEST_RUNNING_VERSION=v1.20.13 TEST_IMAGE_VERSION=v1.20.14 run_update \
  --project-root "${bundle_check_root}" --offline-bundle "${arm_bundle}"; then
  echo 'Bundle for the wrong architecture passed verification.' >&2
  exit 1
fi
if grep -Eq '^docker (load|pull|build) ' "${log_file}"; then
  echo 'Architecture rejection happened after image preparation.' >&2
  exit 1
fi

deploy_symlink_root="${temp_dir}/bundle-deploy-symlink-project"
deploy_symlink_outside="${temp_dir}/bundle-deploy-symlink-outside"
create_upgrade_project "${deploy_symlink_root}"
mkdir -p "${deploy_symlink_outside}"
printf '%s\n' 'outside Bash updater must remain unchanged' > "${deploy_symlink_outside}/update-controller.sh"
printf '%s\n' 'outside PowerShell updater must remain unchanged' > "${deploy_symlink_outside}/update-controller.ps1"
cp "${deploy_symlink_outside}/update-controller.sh" "${temp_dir}/deploy-symlink.sh.before"
cp "${deploy_symlink_outside}/update-controller.ps1" "${temp_dir}/deploy-symlink.ps1.before"
rm -rf -- "${deploy_symlink_root}/deploy"
ln -s "${deploy_symlink_outside}" "${deploy_symlink_root}/deploy"
if [[ -L "${deploy_symlink_root}/deploy" ]]; then
  : > "${log_file}"
  if TEST_RUNNING_VERSION=v1.20.13 TEST_IMAGE_VERSION=v1.20.14 run_update --apply \
    --project-root "${deploy_symlink_root}" --offline-bundle "${bundle_root}"; then
    echo 'Bundle apply accepted a deploy ancestor symlink.' >&2
    exit 1
  fi
  cmp -s "${temp_dir}/deploy-symlink.sh.before" "${deploy_symlink_outside}/update-controller.sh"
  cmp -s "${temp_dir}/deploy-symlink.ps1.before" "${deploy_symlink_outside}/update-controller.ps1"
  if grep -Eq '^docker (load|cp|tag) |^docker compose .* (exec|up) ' "${log_file}"; then
    echo 'Deploy symlink rejection happened after a mutating Docker operation.' >&2
    exit 1
  fi
else
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) echo 'Skipping Bash deploy symlink regression: this environment cannot create native symlinks.' >&2 ;;
    *) echo 'Test environment failed to create the required deploy symlink.' >&2; exit 1 ;;
  esac
fi

release_symlink_root="${temp_dir}/bundle-release-symlink-project"
release_symlink_outside="${temp_dir}/bundle-release-symlink-outside"
create_upgrade_project "${release_symlink_root}"
mkdir -p "${release_symlink_outside}"
printf '%s\n' 'outside release must remain unchanged' > "${release_symlink_outside}/marker.txt"
ln -s "${release_symlink_outside}" "${release_symlink_root}/release"
if [[ -L "${release_symlink_root}/release" ]]; then
  : > "${log_file}"
  if TEST_RUNNING_VERSION=v1.20.13 TEST_IMAGE_VERSION=v1.20.14 run_update --apply \
    --project-root "${release_symlink_root}" --offline-bundle "${bundle_root}"; then
    echo 'Bundle apply accepted a release ancestor symlink.' >&2
    exit 1
  fi
  grep -Fx 'outside release must remain unchanged' "${release_symlink_outside}/marker.txt" >/dev/null
  if [[ -e "${release_symlink_outside}/versions" ]]; then
    echo 'Bundle apply wrote through a release ancestor symlink.' >&2
    exit 1
  fi
  if grep -Eq '^docker (load|cp|tag) |^docker compose .* (exec|up) ' "${log_file}"; then
    echo 'Release symlink rejection happened after a mutating Docker operation.' >&2
    exit 1
  fi
else
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) echo 'Skipping Bash release symlink regression: this environment cannot create native symlinks.' >&2 ;;
    *) echo 'Test environment failed to create the required release symlink.' >&2; exit 1 ;;
  esac
fi

bundle_apply_root="${temp_dir}/bundle-apply-project"
create_upgrade_project "${bundle_apply_root}"
: > "${log_file}"
TEST_RUNNING_VERSION=v1.20.13 TEST_IMAGE_VERSION=v1.20.14 run_update --apply \
  --project-root "${bundle_apply_root}" --offline-bundle "${bundle_root}"
grep -F "docker load --input ${bundle_root}/images/controller-images.tar" "${log_file}" >/dev/null
grep -F 'pg_dump --format=plain' "${log_file}" >/dev/null
grep -F 'docker cp container-postgres:' "${log_file}" >/dev/null
grep -q '^docker compose .* up -d --force-recreate --wait --wait-timeout 300 --pull never --remove-orphans setup server web$' "${log_file}"
if grep -Eq '^docker (pull|build) ' "${log_file}"; then
  echo 'Offline bundle apply attempted a network image operation.' >&2
  exit 1
fi
for image in \
  ghcr.io/pstarchen/monitor-for-server-setup:v1.20.14 \
  ghcr.io/pstarchen/monitor-for-server-server:v1.20.14 \
  ghcr.io/pstarchen/monitor-for-server-web:v1.20.14 \
  ghcr.io/pstarchen/monitor-for-server-agent:v1.20.14 \
  postgres:16-alpine redis:7.4-alpine; do
  grep -F "docker image inspect --format {{.Architecture}} ${image}" "${log_file}" >/dev/null
done
[[ -s "$(find "${bundle_apply_root}/backups" -maxdepth 1 -type f -name 'xingchen-monitor-*.sql' -print -quit)" ]]
cmp -s "${bundle_root}/docker-compose.yml" "${bundle_apply_root}/docker-compose.yml"
cmp -s "${bundle_root}/deploy/update-controller.sh" "${bundle_apply_root}/deploy/update-controller.sh"
cmp -s "${bundle_root}/deploy/update-controller.ps1" "${bundle_apply_root}/deploy/update-controller.ps1"
cmp -s "${bundle_root}/release/manifest.json" "${bundle_apply_root}/release/versions/v1.20.14/manifest.json"
grep -F 'XINGCHEN_RELEASE_MANIFEST_PATH="/workspace/release/versions/v1.20.14/manifest.json"' "${bundle_apply_root}/.env" >/dev/null
grep -F 'XINGCHEN_AGENT_OFFLINE_DIR="/workspace/release/versions/v1.20.14/assets"' "${bundle_apply_root}/.env" >/dev/null
grep -F 'XINGCHEN_NETWORK_MODE="offline"' "${bundle_apply_root}/.env" >/dev/null

missing_image_root="${temp_dir}/bundle-missing-image-project"
create_upgrade_project "${missing_image_root}"
cp "${missing_image_root}/.env" "${temp_dir}/missing-image.env.before"
: > "${log_file}"
if TEST_RUNNING_VERSION=v1.20.13 TEST_IMAGE_VERSION=v1.20.14 TEST_MISSING_LOCAL_IMAGE_MATCH=monitor-for-server-agent \
  run_update --apply --project-root "${missing_image_root}" --offline-bundle "${bundle_root}"; then
  echo 'Bundle apply accepted a missing Agent image.' >&2
  exit 1
fi
cmp -s "${temp_dir}/missing-image.env.before" "${missing_image_root}/.env"
grep -F 'docker tag sha256:old-image ghcr.io/pstarchen/monitor-for-server-server:v1.20.15' "${log_file}" >/dev/null
if grep -q '^docker compose .* up -d ' "${log_file}"; then
  echo 'Missing-image failure attempted to switch services.' >&2
  exit 1
fi

backup_failure_root="${temp_dir}/bundle-backup-failure-project"
create_upgrade_project "${backup_failure_root}"
cp "${backup_failure_root}/.env" "${temp_dir}/backup-failure.env.before"
cp "${backup_failure_root}/docker-compose.yml" "${temp_dir}/backup-failure.compose.before"
: > "${log_file}"
if TEST_RUNNING_VERSION=v1.20.13 TEST_IMAGE_VERSION=v1.20.14 TEST_FAIL_BACKUP=true \
  run_update --apply --project-root "${backup_failure_root}" --offline-bundle "${bundle_root}"; then
  echo 'Bundle apply continued after a database backup failure.' >&2
  exit 1
fi
cmp -s "${temp_dir}/backup-failure.env.before" "${backup_failure_root}/.env"
cmp -s "${temp_dir}/backup-failure.compose.before" "${backup_failure_root}/docker-compose.yml"
if grep -Eq '^docker (load|pull|build) |^docker compose .* up ' "${log_file}"; then
  echo 'Backup failure reached image loading or service switching.' >&2
  exit 1
fi

load_failure_root="${temp_dir}/bundle-load-failure-project"
create_upgrade_project "${load_failure_root}"
cp "${load_failure_root}/.env" "${temp_dir}/load-failure.env.before"
cp "${load_failure_root}/docker-compose.yml" "${temp_dir}/load-failure.compose.before"
cp "${load_failure_root}/deploy/update-controller.sh" "${temp_dir}/load-failure.updater.before"
: > "${log_file}"
if TEST_RUNNING_VERSION=v1.20.13 TEST_IMAGE_VERSION=v1.20.14 TEST_FAIL_LOAD=true \
  run_update --apply --project-root "${load_failure_root}" --offline-bundle "${bundle_root}"; then
  echo 'Bundle apply continued after docker load failed.' >&2
  exit 1
fi
cmp -s "${temp_dir}/load-failure.env.before" "${load_failure_root}/.env"
cmp -s "${temp_dir}/load-failure.compose.before" "${load_failure_root}/docker-compose.yml"
cmp -s "${temp_dir}/load-failure.updater.before" "${load_failure_root}/deploy/update-controller.sh"
grep -F 'docker tag sha256:old-image ghcr.io/pstarchen/monitor-for-server-server:v1.20.15' "${log_file}" >/dev/null
if grep -q '^docker compose .* up -d ' "${log_file}"; then
  echo 'Load failure attempted to switch services.' >&2
  exit 1
fi

bundle_rollback_root="${temp_dir}/bundle-rollback-project"
create_upgrade_project "${bundle_rollback_root}"
cp "${bundle_rollback_root}/.env" "${temp_dir}/bundle-rollback.env.before"
cp "${bundle_rollback_root}/docker-compose.yml" "${temp_dir}/bundle-rollback.compose.before"
cp "${bundle_rollback_root}/deploy/update-controller.sh" "${temp_dir}/bundle-rollback.updater.before"
: > "${log_file}"
rm -f "${temp_dir}/bundle-rollback-compose-state"
set +e
TEST_RUNNING_VERSION=v1.20.13 TEST_IMAGE_VERSION=v1.20.14 TEST_FAIL_COMPOSE_MODE=once \
  TEST_COMPOSE_STATE="${temp_dir}/bundle-rollback-compose-state" run_update --apply \
  --project-root "${bundle_rollback_root}" --offline-bundle "${bundle_root}"
bundle_rollback_status=$?
set -e
if [[ "${bundle_rollback_status}" -ne 10 ]]; then
  echo "Bundle rollback returned ${bundle_rollback_status}, want 10." >&2
  exit 1
fi
cmp -s "${temp_dir}/bundle-rollback.env.before" "${bundle_rollback_root}/.env"
cmp -s "${temp_dir}/bundle-rollback.compose.before" "${bundle_rollback_root}/docker-compose.yml"
cmp -s "${temp_dir}/bundle-rollback.updater.before" "${bundle_rollback_root}/deploy/update-controller.sh"
if [[ -e "${bundle_rollback_root}/release/versions/v1.20.14" ]]; then
  echo 'Failed bundle release directory was not removed during rollback.' >&2
  exit 1
fi
if [[ "$(grep -c '^docker compose .* up -d --force-recreate --wait' "${log_file}")" -ne 2 ]]; then
  echo 'Bundle rollback did not perform a second health check.' >&2
  exit 1
fi
grep -F 'docker tag sha256:old-image ghcr.io/pstarchen/monitor-for-server-server:v1.20.15' "${log_file}" >/dev/null
[[ -s "$(find "${bundle_rollback_root}/backups" -maxdepth 1 -type f -name 'xingchen-monitor-*.sql' -print -quit)" ]]

downgrade_root="${temp_dir}/downgrade-project"
mkdir -p "${downgrade_root}/deploy"
cp "${updater}" "${downgrade_root}/deploy/update-controller.sh"
printf '%s\n' 'POSTGRES_PASSWORD="test-only"' 'XINGCHEN_TARGET_VERSION="v1.20.10"' > "${downgrade_root}/.env"
: > "${log_file}"
if env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" \
  "TEST_RUNNING_VERSION=v1.20.14" bash "${downgrade_root}/deploy/update-controller.sh" --check --no-mirror; then
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
printf '%s\n' 'POSTGRES_PASSWORD="test-only"' 'XINGCHEN_TARGET_VERSION="v1.20.14"' > "${same_root}/.env"
: > "${log_file}"
env "PATH=${fake_bin}:/usr/bin:/bin" "TEST_LOG=${log_file}" "CONTROLLER_AGENT_ENABLED=false" \
  "TEST_RUNNING_VERSION=v1.20.14" bash "${same_root}/deploy/update-controller.sh" --apply --no-mirror
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
