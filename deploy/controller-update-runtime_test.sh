#!/usr/bin/env bash
set -euo pipefail
umask 077

fail() { echo "$*" >&2; exit 1; }
[[ "${XINGCHEN_RUNTIME_TEST_SANDBOX:-}" == 1 ]] || fail 'Run this fixture through deploy/test-controller-runtime.sh.'
[[ ! -S /var/run/docker.sock && ! -S /run/docker.sock ]] || fail 'The runtime fixture must not have a Docker socket.'
source_root=/source
old_bootstrap=/usr/local/share/xingchen/updaters/bootstrap-controller-update.sh
[[ -f "${old_bootstrap}" && -f "${source_root}/deploy/update-controller.sh" ]] || fail 'Required old bootstrap or candidate updater is missing.'
# This regression must exercise the BusyBox realpath that exposed the defect.
if realpath -e /tmp >/dev/null 2>&1; then fail 'The legacy runtime unexpectedly accepts GNU realpath -e.'; fi
[[ "$(realpath /tmp)" == /tmp ]] || fail 'The legacy realpath cannot resolve an existing path.'

test_root="$(mktemp -d /tmp/xingchen-controller-runtime.XXXXXX)"
trap 'rm -rf -- "${test_root}"' EXIT
mkdir -p "${test_root}/bin" "${test_root}/package/deploy"
package="${test_root}/package"
target_version=v99.0.0
old_version=v1.20.20
registry=ccr.ccs.tencentyun.com/xc_monitor
cp "${source_root}/docker-compose.yml" "${package}/docker-compose.yml"
for relative in update-controller.sh update-controller.ps1 bootstrap-controller-update.sh xingchen.sh; do
  cp "${source_root}/deploy/${relative}" "${package}/deploy/${relative}"
done
printf '%s\n' "${target_version}" > "${package}/version"
(
  cd "${package}"
  sha256sum version docker-compose.yml deploy/update-controller.sh deploy/update-controller.ps1 \
    deploy/bootstrap-controller-update.sh deploy/xingchen.sh > SHA256SUMS
)
chmod 700 "${package}" "${package}/deploy"
export RUNTIME_FIXTURE_PACKAGE="${package}" RUNTIME_FIXTURE_TARGET="${target_version}"
export RUNTIME_FIXTURE_OLD="${old_version}" RUNTIME_FIXTURE_REGISTRY="${registry}"
export RUNTIME_FIXTURE_IMAGE_ID="sha256:$(printf 'a%.0s' {1..64})"
export RUNTIME_FIXTURE_CONTAINER_ID="$(printf 'b%.0s' {1..64})"
case "$(uname -m)" in
  x86_64|amd64) export RUNTIME_FIXTURE_ARCH=amd64 ;;
  aarch64|arm64) export RUNTIME_FIXTURE_ARCH=arm64 ;;
  *) fail 'Unsupported runtime architecture.' ;;
esac

# Only Docker is replaced. Filesystem, locks, timeout and checksum commands are
# the actual programs shipped in the old Setup image.
cat > "${test_root}/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "${RUNTIME_FIXTURE_CASE}/calls"
bad_call() { printf 'Unexpected fixture Docker call: %s\n' "$*" >&2; exit 97; }
image_reference() { printf '%s/monitor-for-server-%s:%s' "${RUNTIME_FIXTURE_REGISTRY}" "$1" "$2"; }
old_image_id() {
  local digit
  case "$1" in setup) digit=c ;; server) digit=d ;; web) digit=e ;; agent|controller-agent) digit=f ;; *) bad_call old-image "$1" ;; esac
  printf 'sha256:%s' "$(printf "${digit}%.0s" {1..64})"
}
pulled_marker() {
  local reference="$1" leaf component
  leaf="${reference##*/}"
  component="${leaf%:*}"
  component="${component#monitor-for-server-}"
  case "${component}" in setup|server|web|agent|postgres|redis) ;; *) bad_call image "${reference}" ;; esac
  [[ "${reference}" == "$(image_reference "${component}" "${RUNTIME_FIXTURE_TARGET}")" ]] || bad_call image "${reference}"
  printf '%s/pulled-%s' "${RUNTIME_FIXTURE_CASE}" "${component}"
}
case "${1:-}" in
  info)
    [[ "$#" == 3 && "$2" == --format ]] || bad_call "$@"
    case "$3" in
      '{{.DockerRootDir}}') printf '%s\n' "${RUNTIME_FIXTURE_CASE}" ;;
      '{{.OSType}}/{{.Architecture}}') printf 'linux/%s\n' "${RUNTIME_FIXTURE_ARCH}" ;;
      *) bad_call "$@" ;;
    esac ;;
  pull)
    [[ "$#" == 2 ]] || bad_call "$@"
    : > "$(pulled_marker "$2")" ;;
  image)
    [[ "${2:-}" == inspect ]] || bad_call "$@"
    if [[ "$#" == 3 ]]; then
      [[ -f "$(pulled_marker "$3")" ]]
      exit $?
    fi
    [[ "$#" == 5 && "$3" == --format ]] || bad_call "$@"
    case "$4" in
      '{{.Id}}|{{index .Config.Labels "org.opencontainers.image.version"}}|{{.Os}}/{{.Architecture}}')
        [[ "$5" == "$(image_reference setup "${RUNTIME_FIXTURE_TARGET}")" ]] || bad_call "$@"
        [[ -f "$(pulled_marker "$5")" ]] || bad_call unprepared-image "$5"
        printf '%s|%s|linux/%s\n' "${RUNTIME_FIXTURE_IMAGE_ID}" "${RUNTIME_FIXTURE_TARGET}" "${RUNTIME_FIXTURE_ARCH}" ;;
      '{{index .Config.Labels "org.opencontainers.image.version"}}')
        [[ -f "$(pulled_marker "$5")" ]] || bad_call unprepared-image "$5"
        printf '%s\n' "${RUNTIME_FIXTURE_TARGET}" ;;
      *) bad_call "$@" ;;
    esac ;;
  create)
    [[ "$#" == 4 && "$2" == --name && "$3" == xingchen-update-extract-* && "$4" == "${RUNTIME_FIXTURE_IMAGE_ID}" ]] || bad_call "$@"
    printf '%s\n' "$3" > "${RUNTIME_FIXTURE_CASE}/extraction-name"
    printf '%s\n' "${RUNTIME_FIXTURE_CONTAINER_ID}" ;;
  cp)
    [[ "$#" == 3 && "$2" == "${RUNTIME_FIXTURE_CONTAINER_ID}:/usr/local/share/xingchen/controller-update/." && "$3" == "${RUNTIME_FIXTURE_CASE}/project/.controller-update-package."* ]] || bad_call "$@"
    cp -R -- "${RUNTIME_FIXTURE_PACKAGE}/." "$3" ;;
  rm)
    [[ "$#" == 3 && "$2" == -f && -f "${RUNTIME_FIXTURE_CASE}/extraction-name" && "$3" == "$(cat "${RUNTIME_FIXTURE_CASE}/extraction-name")" ]] || bad_call "$@"
    rm -- "${RUNTIME_FIXTURE_CASE}/extraction-name" ;;
  inspect)
    [[ "$#" == 4 && "$2" == --format && "$4" == fixture-* ]] || bad_call "$@"
    service="${4#fixture-}"
    [[ "${service}" == setup || "${service}" == server || "${service}" == web || "${service}" == controller-agent ]] || bad_call "$@"
    case "$3" in
      '{{index .Config.Labels "org.opencontainers.image.version"}}') printf '%s\n' "${RUNTIME_FIXTURE_OLD}" ;;
      '{{.Image}}') old_image_id "${service}"; printf '\n' ;;
      '{{.Config.Image}}') image_reference "${service#controller-}" "${RUNTIME_FIXTURE_OLD}"; printf '\n' ;;
      *) bad_call "$@" ;;
    esac ;;
  tag)
    [[ "$#" == 3 ]] || bad_call "$@"
    reference_leaf="${3##*/}"
    component="${reference_leaf%:*}"
    component="${component#monitor-for-server-}"
    [[ "$2" == "$(old_image_id "${component}")" && "$3" == "$(image_reference "${component}" "${RUNTIME_FIXTURE_OLD}")" ]] || bad_call "$@"
    [[ ! -e "${RUNTIME_FIXTURE_CASE}/restored-${component}" ]] || bad_call duplicate-restore "${component}"
    : > "${RUNTIME_FIXTURE_CASE}/restored-${component}" ;;
  compose)
    shift
    compose_file='' env_file='' project_directory=''
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --profile) [[ "${2:-}" == host-monitoring ]] || bad_call "$@"; shift 2 ;;
        -f) compose_file="$2"; shift 2 ;;
        --env-file) env_file="$2"; shift 2 ;;
        --project-directory) project_directory="$2"; shift 2 ;;
        *) break ;;
      esac
    done
    if [[ "${1:-}" == version && "$#" == 1 ]]; then printf 'Docker Compose version fixture\n'; exit 0; fi
    [[ -f "${compose_file}" && "${env_file}" == "${RUNTIME_FIXTURE_CASE}/project/.env" && "${project_directory}" == "${RUNTIME_FIXTURE_CASE}/project" ]] || bad_call "$@"
    case "${1:-}" in
      ps)
        [[ "$#" == 3 && "$2" == -q ]] || bad_call "$@"
        printf 'fixture-%s\n' "$3" ;;
      config)
        [[ "$#" == 2 && "$2" == --quiet && "${compose_file}" == "${RUNTIME_FIXTURE_CASE}/project/.controller-update-package."*'/docker-compose.yml' ]] || bad_call "$@" ;;
      up)
        [[ "$*" == 'up -d --force-recreate --wait --wait-timeout 300 --pull never --no-build setup server web controller-agent' ]] || bad_call "$@"
        count=0
        [[ ! -f "${RUNTIME_FIXTURE_CASE}/up-count" ]] || read -r count < "${RUNTIME_FIXTURE_CASE}/up-count"
        count=$((count + 1))
        printf '%s\n' "${count}" > "${RUNTIME_FIXTURE_CASE}/up-count"
        expected_version="${RUNTIME_FIXTURE_TARGET}"
        [[ "${count}" == 1 ]] || expected_version="${RUNTIME_FIXTURE_OLD}"
        for component in setup server web agent postgres redis; do
          key="XINGCHEN_${component^^}_IMAGE"
          if [[ -v "${key}" ]]; then
            effective_reference="${!key}"
          else
            effective_reference="$(awk -v key="${key}" 'index($0, key "=") == 1 { value=substr($0, length(key) + 2); gsub(/^"|"$/, "", value); print value; exit }' "${env_file}")"
          fi
          [[ "${effective_reference}" == "$(image_reference "${component}" "${expected_version}")" ]] || bad_call effective-image "${key}" "${effective_reference}"
          [[ -f "$(pulled_marker "$(image_reference "${component}" "${RUNTIME_FIXTURE_TARGET}")")" ]] || bad_call unprepared-image "${component}"
          printf '%s=%s\n' "${key}" "${effective_reference}" >> "${RUNTIME_FIXTURE_CASE}/effective-${count}"
        done
        if [[ -v XINGCHEN_TARGET_VERSION ]]; then
          effective_version="${XINGCHEN_TARGET_VERSION}"
        else
          effective_version="$(awk -F= '$1 == "XINGCHEN_TARGET_VERSION" { gsub(/"/, "", $2); print $2; exit }' "${env_file}")"
        fi
        [[ "${effective_version}" == "${expected_version}" ]] || bad_call effective-version "${effective_version}"
        cp "${env_file}" "${RUNTIME_FIXTURE_CASE}/env-${count}"
        cp "${compose_file}" "${RUNTIME_FIXTURE_CASE}/compose-${count}"
        if [[ "${RUNTIME_FIXTURE_SCENARIO}" == rollback && "${count}" == 1 ]]; then exit 1; fi ;;
      *) bad_call "$@" ;;
    esac ;;
  *) bad_call "$@" ;;
esac
DOCKER
chmod 700 "${test_root}/bin/docker"
export PATH="${test_root}/bin:${PATH}"
[[ "$(command -v docker)" == "${test_root}/bin/docker" ]] || fail 'Docker fixture did not take precedence in PATH.'
mkdir "${test_root}/preflight"
preflight_platform="$(RUNTIME_FIXTURE_CASE="${test_root}/preflight" docker info --format '{{.OSType}}/{{.Architecture}}')"
if [[ "${preflight_platform}" != "linux/${RUNTIME_FIXTURE_ARCH}" ]]; then
  printf 'Unexpected Docker fixture platform: %q\n' "${preflight_platform}" >&2
  fail 'Docker fixture platform preflight failed.'
fi
[[ -s "${test_root}/preflight/calls" ]] || fail 'Docker fixture did not record its preflight call.'

for scenario in success rollback symlink; do
  case_root="${test_root}/${scenario}"
  project="${case_root}/project"
  mkdir -p "${project}/deploy" "${project}/backups" "${case_root}/before/deploy"
  printf '%s\n' 'name: runtime-controller' 'services: {}' > "${project}/docker-compose.yml"
  for relative in update-controller.sh update-controller.ps1 bootstrap-controller-update.sh xingchen.sh; do
    printf '# original %s\n' "${relative}" > "${project}/deploy/${relative}"
    chmod 751 "${project}/deploy/${relative}"
  done
  {
    printf '%s\n' 'COMPOSE_PROJECT_NAME="runtime-controller"' 'CONTROLLER_AGENT_ENABLED="true"' \
      'XINGCHEN_NETWORK_MODE="public"' 'XINGCHEN_ALLOW_GITEE="true"' \
      'XINGCHEN_UPDATE_MIN_FREE_BYTES="1"' 'XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS="15"' \
      'XINGCHEN_UPDATE_COMPOSE_TIMEOUT_SECONDS="15"' 'POSTGRES_PASSWORD="runtime-fixture-secret-do-not-log"'
    printf 'XINGCHEN_TARGET_VERSION="%s"\n' "${old_version}"
    for component in setup server web agent postgres redis; do
      printf 'XINGCHEN_%s_IMAGE="%s/monitor-for-server-%s:%s"\n' "${component^^}" "${registry}" "${component}" "${old_version}"
    done
  } > "${project}/.env"
  chmod 600 "${project}/.env"
  chmod 640 "${project}/docker-compose.yml"
  backup="${project}/backups/xingchen-monitor-$(date -u +%Y%m%dT%H%M%SZ)-${BASHPID}.sql"
  printf '%s\n' '-- PostgreSQL database dump' '-- isolated runtime fixture' '-- PostgreSQL database dump complete' > "${backup}"
  chmod 600 "${backup}"
  backup_sha="$(sha256sum "${backup}")"
  backup_sha="${backup_sha%% *}"
  backup_metadata="$(stat -c '%i:%s:%Y:%a' "${backup}")"
  for relative in .env docker-compose.yml deploy/update-controller.sh deploy/update-controller.ps1 deploy/bootstrap-controller-update.sh deploy/xingchen.sh; do
    cp -p "${project}/${relative}" "${case_root}/before/${relative}"
  done
  if [[ "${scenario}" == symlink ]]; then
    mkdir "${case_root}/outside"
    printf 'keep\n' > "${case_root}/outside/marker"
    ln -s "${case_root}/outside" "${project}/release"
  fi
  : > "${case_root}/calls"
  status=0
  RUNTIME_FIXTURE_CASE="${case_root}" RUNTIME_FIXTURE_SCENARIO="${scenario}" \
    CONTROLLER_UPDATE_RUNNER=true SETUP_WORKSPACE="${project}" XINGCHEN_HOST_PROJECT_ROOT="${project}" \
    XINGCHEN_PREUPDATE_BACKUP_PATH="${backup}" XINGCHEN_PREUPDATE_BACKUP_SHA256="${backup_sha}" \
    bash "${old_bootstrap}" --version "${target_version}" --apply > "${case_root}/output" 2>&1 || status=$?
  expected_status=0
  [[ "${scenario}" != rollback ]] || expected_status=10
  [[ "${scenario}" != symlink ]] || expected_status=1
  if [[ "${status}" != "${expected_status}" ]]; then
    cat "${case_root}/output" >&2
    cat "${case_root}/calls" >&2
    fail "Legacy runtime ${scenario}: exit ${status}, expected ${expected_status}."
  fi
  [[ "$(stat -c '%i:%s:%Y:%a' "${backup}")" == "${backup_metadata}" ]] || fail 'Prepared backup metadata changed.'
  [[ "$(sha256sum "${backup}")" == "${backup_sha}  ${backup}" ]] || fail 'Prepared backup content changed.'
  [[ "$(find "${project}/backups" -type f | wc -l)" -eq 1 ]] || fail 'The updater created an extra database backup.'
  if grep -Eq 'pg_dump|^docker compose .* exec ' "${case_root}/calls"; then fail 'The updater did not reuse the prepared backup.'; fi
  if grep -F 'runtime-fixture-secret-do-not-log' "${case_root}/output" "${case_root}/calls" >/dev/null; then fail 'The updater exposed fixture credentials.'; fi
  [[ ! -e "${case_root}/extraction-name" ]] || fail 'Bootstrap did not remove its extraction container.'
  [[ -z "$(find "${project}" -maxdepth 1 \( -name '.controller-update-snapshot.*' -o -name '.controller-update-package.*' \) -print -quit)" ]] || fail 'The update left a transaction or package directory.'
  if [[ "${scenario}" != symlink ]]; then
    cmp -s "${case_root}/compose-1" "${package}/docker-compose.yml" || fail 'The candidate did not use the packaged Compose file.'
    grep -Fx "XINGCHEN_TARGET_VERSION=\"${target_version}\"" "${case_root}/env-1" >/dev/null || fail 'Compose did not receive the target release version.'
    for component in setup server web agent postgres redis; do
      grep -Fx "XINGCHEN_${component^^}_IMAGE=\"${registry}/monitor-for-server-${component}:${target_version}\"" "${case_root}/env-1" >/dev/null || fail "Compose did not receive the target image: ${component}"
    done
  fi
  if [[ "${scenario}" == success ]]; then
    [[ "$(cat "${case_root}/up-count")" == 1 ]] || fail 'Successful update did not apply exactly once.'
    for relative in docker-compose.yml deploy/update-controller.sh deploy/update-controller.ps1 deploy/bootstrap-controller-update.sh deploy/xingchen.sh; do
      cmp -s "${project}/${relative}" "${package}/${relative}" || fail "Candidate file was not installed: ${relative}"
    done
    grep -Fx "XINGCHEN_TARGET_VERSION=\"${target_version}\"" "${project}/.env" >/dev/null || fail 'Candidate version was not persisted.'
    for component in setup server web agent postgres redis; do
      grep -Fx "XINGCHEN_${component^^}_IMAGE=\"${registry}/monitor-for-server-${component}:${target_version}\"" "${project}/.env" >/dev/null || fail "Candidate image was not persisted: ${component}"
    done
  else
    for relative in .env docker-compose.yml deploy/update-controller.sh deploy/update-controller.ps1 deploy/bootstrap-controller-update.sh deploy/xingchen.sh; do
      cmp -s "${project}/${relative}" "${case_root}/before/${relative}" || fail "Original file was not preserved: ${relative}"
      [[ "$(stat -c '%a' "${project}/${relative}")" == "$(stat -c '%a' "${case_root}/before/${relative}")" ]] || fail "Original file mode was not preserved: ${relative}"
    done
    if [[ "${scenario}" == rollback ]]; then
      [[ "$(cat "${case_root}/up-count")" == 2 ]] || fail 'Candidate failure did not reapply the original deployment.'
      cmp -s "${case_root}/compose-1" "${package}/docker-compose.yml" || fail 'The failed candidate did not use the candidate Compose file.'
      cmp -s "${case_root}/compose-2" "${case_root}/before/docker-compose.yml" || fail 'Rollback did not use the original Compose file.'
      cmp -s "${case_root}/env-2" "${case_root}/before/.env" || fail 'Rollback did not use the original environment.'
      [[ "$(grep -c '^docker tag ' "${case_root}/calls")" -eq 4 ]] || fail 'Rollback did not restore all four managed service images.'
    else
      [[ ! -e "${case_root}/up-count" && "$(cat "${case_root}/outside/marker")" == keep ]] || fail 'An unsafe deployment path reached service switching or modified its target.'
    fi
  fi
  printf 'PASS: legacy Setup runtime %s, real BusyBox tools, prepared backup preserved.\n' "${scenario}"
done
echo 'Controller update legacy runtime integration tests passed.'
