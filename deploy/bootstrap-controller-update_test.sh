#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bootstrap="${script_dir}/bootstrap-controller-update.sh"
temp_dir="$(mktemp -d)"
trap 'rm -rf -- "${temp_dir}"' EXIT
mkdir -p "${temp_dir}/bin" "${temp_dir}/package/deploy" "${temp_dir}/project/.controller-update-package.keep" "${temp_dir}/docker-root"
export BOOTSTRAP_TEST_DIR="${temp_dir}"
export BOOTSTRAP_TEST_IMAGE_ID="sha256:$(printf 'a%.0s' {1..64})"
export BOOTSTRAP_TEST_CONTAINER_ID="$(printf 'b%.0s' {1..64})"
export BOOTSTRAP_TEST_REAL_STAT="$(command -v stat)"
export PATH="${temp_dir}/bin:${PATH}"
target_version=v1.20.19
setup_repository=ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-setup
project_root="${temp_dir}/project"
package="${temp_dir}/package"
printf '%s\n' 'services: {}' > "${project_root}/docker-compose.yml"
printf '%s\n' keep > "${project_root}/.controller-update-package.keep/marker"
printf '%s\n' "${target_version}" > "${package}/version"
printf '%s\n' 'services: {}' > "${package}/docker-compose.yml"
printf '%s\n' '# fixture PowerShell updater' > "${package}/deploy/update-controller.ps1"
printf '%s\n' '# fixture bootstrap' > "${package}/deploy/bootstrap-controller-update.sh"
printf '%s\n' '# fixture manager' > "${package}/deploy/xingchen.sh"

cat > "${package}/deploy/update-controller.sh" <<'UPDATER'
#!/usr/bin/env bash
set -euo pipefail
: >&9
printf 'updater %s\n' "$*" >> "${BOOTSTRAP_TEST_DIR}/calls"
[[ "${XINGCHEN_TARGET_VERSION:-}" == v1.20.19 ]] || exit 91
[[ "${1:-}" == --apply || "${1:-}" == --check ]] || exit 92
[[ "${2:-}" == --online-release && -f "${3:-}/version" ]] || exit 93
[[ "${BASH_SOURCE[0]}" == "$3/deploy/update-controller.sh" ]] || exit 94
if [[ "${CONTROLLER_UPDATE_RUNNER:-false}" == true ]]; then
  [[ "$#" == 3 && "${SETUP_WORKSPACE}" == "${BOOTSTRAP_TEST_DIR}/project" ]] || exit 95
else
  [[ "$#" == 5 && "$4" == --project-root && "$5" == "${BOOTSTRAP_TEST_DIR}/project" ]] || exit 96
fi
case "${BOOTSTRAP_TEST_SCENARIO}" in
  child-hup) kill -s HUP "${PPID}" ;;
  child-rollback) exit 10 ;;
  child-rollback-error) exit 11 ;;
  nested-term-rollback|nested-term-rollback-error|nested-term-zero)
    package_path="$3"
    child_status=10
    [[ "${BOOTSTRAP_TEST_SCENARIO}" != nested-term-rollback-error ]] || child_status=11
    [[ "${BOOTSTRAP_TEST_SCENARIO}" != nested-term-zero ]] || child_status=0
    finish_rollback() {
      trap '' TERM
      sleep 0.1
      [[ -f "${package_path}/version" && -f "${package_path}/deploy/update-controller.sh" ]] || exit 97
      printf '%s\n' restored > "${BOOTSTRAP_TEST_DIR}/rollback-complete"
      exit "${child_status}"
    }
    trap finish_rollback TERM
    process_group="$(ps -o pgid= -p "${BASHPID}" | tr -d '[:space:]')"
    [[ "${process_group}" =~ ^[1-9][0-9]*$ && "${process_group}" == "${PPID}" ]] || exit 98
    bash -c 'sleep 0.05; kill -TERM -- "-$1"; sleep 5' _ "${process_group}"
    exit 99 ;;
esac
UPDATER

write_checksums() {
  (
    cd -- "$1"
    sha256sum version docker-compose.yml deploy/update-controller.sh deploy/update-controller.ps1 deploy/bootstrap-controller-update.sh deploy/xingchen.sh | sed 's/ \*/  /' > SHA256SUMS
  )
}
write_checksums "${package}"
chmod 700 "${package}" "${package}/deploy"

cat > "${temp_dir}/bin/flock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-n 9' ]] || exit 98
: >&9
printf 'flock %s\n' "$*" >> "${BOOTSTRAP_TEST_DIR}/calls"
[[ "${BOOTSTRAP_TEST_SCENARIO}" != lock-busy ]]
MOCK
cat > "${temp_dir}/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'timeout %s\n' "$*" >> "${BOOTSTRAP_TEST_DIR}/calls"
if [[ "${1:-}" == --help ]]; then
  if [[ "${BOOTSTRAP_TEST_SCENARIO}" == busybox-timeout ]]; then printf 'Usage: timeout -s SIGNAL -k KILL_SECS SECS PROG ARGS\n'; else printf '%s\n' 'Usage: timeout [--foreground] -s SIGNAL -k KILL_SECS SECS PROG ARGS'; fi
  exit 0
fi
if [[ "${BOOTSTRAP_TEST_SCENARIO}" != busybox-timeout ]]; then
  [[ "${1:-}" == --foreground ]] || exit 98
  shift
fi
[[ "${1:-}" == -s && "${2:-}" == TERM && "${3:-}" == -k && "${4:-}" =~ ^[1-9][0-9]*$ && "${5:-}" =~ ^[1-9][0-9]*$ ]] || exit 98
shift 5
if [[ "${BOOTSTRAP_TEST_SCENARIO}" == pull-timeout && "${2:-}" == pull ]]; then exit 124; fi
exec "$@"
MOCK
cat > "${temp_dir}/bin/stat" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${BOOTSTRAP_TEST_SCENARIO:-}" == wrong-owner && "${2:-}" == '%a %u' ]]; then
  printf '700 %s\n' "$((EUID + 1))"
elif [[ "${BOOTSTRAP_TEST_SCENARIO:-}" == wrong-directory-mode && "${2:-}" == '%a %u' && "${*: -1}" == */deploy ]]; then
  printf '755 %s\n' "${EUID}"
else
  exec "${BOOTSTRAP_TEST_REAL_STAT}" "$@"
fi
MOCK
cat > "${temp_dir}/bin/df" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 2 && "$1" == -Pk ]] || exit 98
printf 'df %s\n' "$*" >> "${BOOTSTRAP_TEST_DIR}/calls"
available_kb=2097152
case "${BOOTSTRAP_TEST_SCENARIO}" in
  low-project-space) [[ "$2" != "${BOOTSTRAP_TEST_DIR}/project" ]] || available_kb=1048575 ;;
  low-docker-space) [[ "$2" != "${BOOTSTRAP_TEST_DIR}/docker-root" ]] || available_kb=1048575 ;;
  space-boundary) available_kb=1048576 ;;
  one-kilobyte) available_kb=1 ;;
  df-error) exit 1 ;;
  invalid-df-output) available_kb=invalid ;;
esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/test 4194304 0 %s 0%% %s\n' "${available_kb}" "$2"
MOCK
cat > "${temp_dir}/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
: >&9
printf 'docker %s\n' "$*" >> "${BOOTSTRAP_TEST_DIR}/calls"
case "${1:-}" in
  info)
    if [[ "${2:-}" == --format && "${3:-}" == '{{.DockerRootDir}}' ]]; then
      [[ "${BOOTSTRAP_TEST_SCENARIO}" != daemon-error ]] || exit 1
      if [[ "${BOOTSTRAP_TEST_SCENARIO}" == missing-docker-root ]]; then printf '%s/not-a-docker-root\n' "${BOOTSTRAP_TEST_DIR}"; else printf '%s/docker-root\n' "${BOOTSTRAP_TEST_DIR}"; fi
      exit 0
    fi
    [[ "${2:-}" == --format && "${3:-}" == '{{.OSType}}/{{.Architecture}}' ]] || exit 98
    case "${BOOTSTRAP_TEST_SCENARIO}" in
      daemon-error) exit 1 ;;
      unsupported-daemon) printf 'windows/amd64\n' ;;
      arm64) printf 'linux/aarch64\n' ;;
      *) printf 'linux/x86_64\n' ;;
    esac ;;
  pull) [[ "${BOOTSTRAP_TEST_SCENARIO}" != pull-error ]] ;;
  image)
    [[ "${2:-}" == inspect && "${3:-}" == --format ]] || exit 98
    case "${BOOTSTRAP_TEST_SCENARIO}" in
      inspect-error) exit 1 ;;
      wrong-version) printf '%s|v1.20.18|linux/amd64\n' "${BOOTSTRAP_TEST_IMAGE_ID}" ;;
      wrong-platform) printf '%s|v1.20.19|linux/arm64\n' "${BOOTSTRAP_TEST_IMAGE_ID}" ;;
      wrong-os) printf '%s|v1.20.19|windows/amd64\n' "${BOOTSTRAP_TEST_IMAGE_ID}" ;;
      invalid-image-id) printf 'sha256:invalid|v1.20.19|linux/amd64\n' ;;
      extra-metadata) printf '%s|v1.20.19|linux/amd64|unexpected\n' "${BOOTSTRAP_TEST_IMAGE_ID}" ;;
      arm64) printf '%s|v1.20.19|linux/arm64\n' "${BOOTSTRAP_TEST_IMAGE_ID}" ;;
      *) printf '%s|v1.20.19|linux/amd64\n' "${BOOTSTRAP_TEST_IMAGE_ID}" ;;
    esac ;;
  create)
    [[ "$#" == 4 && "$2" == --name && "$3" =~ ^xingchen-update-extract-[a-zA-Z0-9]{6}-[0-9]+$ && "$4" == "${BOOTSTRAP_TEST_IMAGE_ID}" ]] || exit 99
    printf '%s' "$3" > "${BOOTSTRAP_TEST_DIR}/container-name"
    [[ "${BOOTSTRAP_TEST_SCENARIO}" != create-error ]] || exit 1
    touch "${BOOTSTRAP_TEST_DIR}/created-container"
    [[ "${BOOTSTRAP_TEST_SCENARIO}" != create-without-response ]] || exit 130
    if [[ "${BOOTSTRAP_TEST_SCENARIO}" == invalid-container-id ]]; then printf 'invalid\n'; exit 0; fi
    printf '%s\n' "${BOOTSTRAP_TEST_CONTAINER_ID}" ;;
  cp)
    [[ "$#" == 3 && "$2" == "${BOOTSTRAP_TEST_CONTAINER_ID}:/usr/local/share/xingchen/controller-update/." ]] || exit 98
    [[ "${BOOTSTRAP_TEST_SCENARIO}" != copy-error ]] || exit 1
    cp -R -- "${BOOTSTRAP_TEST_DIR}/package/." "$3"
    if [[ "${BOOTSTRAP_TEST_SCENARIO}" == damaged-extraction ]]; then printf '%s\n' damaged >> "$3/docker-compose.yml"; fi ;;
  rm)
    [[ "$#" == 3 && "$2" == -f && "$3" == "$(cat "${BOOTSTRAP_TEST_DIR}/container-name")" ]] || exit 98
    if [[ "${BOOTSTRAP_TEST_SCENARIO}" == nested-term-* ]]; then
      [[ -f "${BOOTSTRAP_TEST_DIR}/rollback-complete" ]] || exit 99
    fi
    rm -f "${BOOTSTRAP_TEST_DIR}/created-container"
    [[ "${BOOTSTRAP_TEST_SCENARIO}" != remove-error ]] ;;
  *) exit 97 ;;
esac
MOCK
chmod +x "${temp_dir}/bin/"*

reset_env() {
  printf '%s\n' 'POSTGRES_PASSWORD="fixture-only-do-not-log"' "XINGCHEN_SETUP_IMAGE=\"${setup_repository}:v1.20.18\"" > "${project_root}/.env"
}
reset_env
case_count=0
invoke_bootstrap() {
  local scenario="$1" expected_status="$2"
  shift 2
  : > "${temp_dir}/calls"
  rm -f "${temp_dir}/container-name" "${temp_dir}/rollback-complete"
  local status=0 env_before
  env_before="$(sha256sum "${project_root}/.env")"
  env -u XINGCHEN_NETWORK_MODE -u XINGCHEN_ALLOW_GITEE -u XINGCHEN_SETUP_IMAGE \
    -u XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS -u XINGCHEN_UPDATE_MIN_FREE_BYTES -u XINGCHEN_TARGET_VERSION \
    -u CONTROLLER_UPDATE_RUNNER -u SETUP_WORKSPACE \
    "BOOTSTRAP_TEST_SCENARIO=${scenario}" "$@" > "${temp_dir}/output" 2> "${temp_dir}/error" || status=$?
  if [[ "${status}" != "${expected_status}" ]]; then
    cat "${temp_dir}/error" >&2
    echo "Unexpected exit status for ${scenario}: ${status}, expected ${expected_status}." >&2
    exit 1
  fi
  [[ "$(sha256sum "${project_root}/.env")" == "${env_before}" ]] || { echo 'Bootstrap modified deployment .env.' >&2; exit 1; }
  [[ "$(cat "${project_root}/.controller-update-package.keep/marker")" == keep ]] || { echo 'Bootstrap removed another staging directory.' >&2; exit 1; }
  [[ ! -f "${temp_dir}/created-container" ]] || { echo 'Bootstrap leaked an extraction container.' >&2; exit 1; }
  [[ -z "$(find "${project_root}" -maxdepth 1 -type d -name '.controller-update-package.*' ! -name '.controller-update-package.keep' -print)" ]] || { echo "Bootstrap leaked a staging directory: ${scenario}" >&2; exit 1; }
  if grep -F 'fixture-only-do-not-log' "${temp_dir}/output" "${temp_dir}/error" "${temp_dir}/calls" >/dev/null; then
    echo 'Bootstrap exposed deployment secrets.' >&2
    exit 1
  fi
  case_count=$((case_count + 1))
}

assert_calls() {
  local expected="$1" pulls creates copies removals children
  pulls="$(awk '/^docker pull / { n++ } END { print n+0 }' "${temp_dir}/calls")"
  creates="$(awk '/^docker create / { n++ } END { print n+0 }' "${temp_dir}/calls")"
  copies="$(awk '/^docker cp / { n++ } END { print n+0 }' "${temp_dir}/calls")"
  removals="$(awk '/^docker rm / { n++ } END { print n+0 }' "${temp_dir}/calls")"
  children="$(awk '/^updater / { n++ } END { print n+0 }' "${temp_dir}/calls")"
  [[ "${pulls}/${creates}/${copies}/${removals}/${children}" == "${expected}" ]] || {
    echo "Unexpected pull/create/cp/rm/updater counts: ${pulls}/${creates}/${copies}/${removals}/${children}, expected ${expected}." >&2
    exit 1
  }
}

run_online() {
  local scenario="$1" expected_status="$2" expected_calls="$3"
  shift 3
  invoke_bootstrap "${scenario}" "${expected_status}" bash "${bootstrap}" --project-root "${project_root}" --version "${target_version}" "$@"
  assert_calls "${expected_calls}"
}

run_online default-apply 0 1/1/1/1/1
grep -Fx "docker pull ${setup_repository}:${target_version}" "${temp_dir}/calls" >/dev/null
grep -E '^updater --apply --online-release .+ --project-root ' "${temp_dir}/calls" >/dev/null
[[ "$(head -n 1 "${temp_dir}/calls")" == 'flock -n 9' ]]
run_online explicit-check 0 1/1/1/1/1 --check
grep '^updater --check --online-release ' "${temp_dir}/calls" >/dev/null
run_online arm64 0 1/1/1/1/1 --apply
run_online child-rollback 10 1/1/1/1/1
run_online child-rollback-error 11 1/1/1/1/1
if [[ "$(uname -s)" == Linux ]]; then
  command -v setsid >/dev/null || { echo 'Native Linux signal tests require setsid.' >&2; exit 1; }
  for scenario in nested-term-rollback nested-term-rollback-error nested-term-zero; do
    expected_status=10
    [[ "${scenario}" != nested-term-rollback-error ]] || expected_status=11
    [[ "${scenario}" != nested-term-zero ]] || expected_status=143
    invoke_bootstrap "${scenario}" "${expected_status}" setsid bash "${bootstrap}" --project-root "${project_root}" --version "${target_version}"
    assert_calls 1/1/1/1/1
    [[ "$(cat "${temp_dir}/rollback-complete")" == restored ]] || { echo 'Bootstrap exited before child rollback finished.' >&2; exit 1; }
  done
else
  echo 'Skipping nested process-group cancellation regressions: native Linux is required.'
fi
run_online child-hup 129 1/1/1/1/1
run_online busybox-timeout 0 1/1/1/1/1
grep -Fx "timeout -s TERM -k 10 180 docker pull ${setup_repository}:${target_version}" "${temp_dir}/calls" >/dev/null
run_online remove-error 0 1/1/1/1/1
run_online lock-busy 75 0/0/0/0/0
for scenario in low-project-space low-docker-space df-error invalid-df-output; do run_online "${scenario}" 1 0/0/0/0/0; done
run_online space-boundary 0 1/1/1/1/1
run_online missing-docker-root 0 1/1/1/1/1
[[ "$(awk '/^df / { n++ } END { print n+0 }' "${temp_dir}/calls")" == 1 ]]
printf '%s\n' 'XINGCHEN_UPDATE_MIN_FREE_BYTES="1025"' >> "${project_root}/.env"
run_online one-kilobyte 1 0/0/0/0/0
invoke_bootstrap one-kilobyte 0 XINGCHEN_UPDATE_MIN_FREE_BYTES=1024 bash "${bootstrap}" --project-root "${project_root}" --version "${target_version}"
assert_calls 1/1/1/1/1
reset_env
printf '%s\n' 'XINGCHEN_UPDATE_MIN_FREE_BYTES="9223372036854775808"' >> "${project_root}/.env"
run_online exceeds-integer-range 1 0/0/0/0/0
reset_env
for scenario in daemon-error unsupported-daemon; do run_online "${scenario}" 1 0/0/0/0/0; done
run_online pull-error 1 1/0/0/0/0
run_online pull-timeout 1 0/0/0/0/0
for scenario in inspect-error wrong-version wrong-platform wrong-os invalid-image-id extra-metadata; do run_online "${scenario}" 1 1/0/0/0/0; done
run_online create-error 1 1/1/0/1/0
run_online create-without-response 1 1/1/0/1/0
run_online invalid-container-id 1 1/1/0/1/0
run_online copy-error 1 1/1/1/1/0
run_online damaged-extraction 1 1/1/1/1/0

invoke_bootstrap runner 0 CONTROLLER_UPDATE_RUNNER=true "SETUP_WORKSPACE=${project_root}" bash "${bootstrap}" --version "${target_version}" --check
assert_calls 1/1/1/1/1
if grep '^updater .* --project-root ' "${temp_dir}/calls" >/dev/null; then echo 'Runner received --project-root.' >&2; exit 1; fi
invoke_bootstrap runner-project-root 1 CONTROLLER_UPDATE_RUNNER=true "SETUP_WORKSPACE=${project_root}" bash "${bootstrap}" --project-root "${project_root}" --version "${target_version}"
assert_calls 0/0/0/0/0

printf '%s\n' 'POSTGRES_PASSWORD="fixture-only-do-not-log"' > "${project_root}/.env"
run_online default-registry 0 1/1/1/1/1
grep -Fx "docker pull ghcr.io/pstarchen/monitor-for-server-setup:${target_version}" "${temp_dir}/calls" >/dev/null
printf '%s\n' 'XINGCHEN_NETWORK_MODE="internal"' >> "${project_root}/.env"
run_online internal-unconfigured 1 0/0/0/0/0

reset_env
printf '%s\n' 'XINGCHEN_NETWORK_MODE="internal"' >> "${project_root}/.env"
run_online internal-tencent 0 1/1/1/1/1
for public_host in ghcr.io cache.ghcr.io docker.io registry-1.docker.io github.com api.github.com raw.githubusercontent.com cdn.githubassets.com ghcr.1ms.run ghcr.nju.edu.cn ghcr.m.daocloud.io; do
  printf '%s\n' 'XINGCHEN_NETWORK_MODE="internal"' 'XINGCHEN_ALLOW_GITEE="true"' "XINGCHEN_SETUP_IMAGE=\"${public_host}/example/setup:v1.20.18\"" > "${project_root}/.env"
  run_online "internal-${public_host}" 1 0/0/0/0/0
  if grep '^docker ' "${temp_dir}/calls" >/dev/null; then echo 'Internal policy was checked after Docker access.' >&2; exit 1; fi
done
printf '%s\n' 'XINGCHEN_NETWORK_MODE="internal"' 'XINGCHEN_SETUP_IMAGE="github.com.evil.example/setup:v1.20.18"' > "${project_root}/.env"
run_online internal-lookalike-host 0 1/1/1/1/1
printf '%s\n' 'XINGCHEN_NETWORK_MODE="internal"' 'XINGCHEN_ALLOW_GITEE="true"' 'XINGCHEN_SETUP_IMAGE="registry.gitee.com/example/setup:v1.20.18"' > "${project_root}/.env"
run_online internal-gitee-opt-in 0 1/1/1/1/1
sed -i 's/XINGCHEN_ALLOW_GITEE="true"/XINGCHEN_ALLOW_GITEE="false"/' "${project_root}/.env"
run_online internal-gitee-no-opt-in 1 0/0/0/0/0
printf '%s\n' 'XINGCHEN_SETUP_IMAGE="registry.gitee.com/example/setup:v1.20.18"' > "${project_root}/.env"
run_online gitee-no-opt-in 1 0/0/0/0/0
printf '%s\n' 'XINGCHEN_ALLOW_GITEE="true"' >> "${project_root}/.env"
run_online gitee-opt-in 0 1/1/1/1/1

reset_env
printf '%s\n' 'XINGCHEN_NETWORK_MODE="offline"' >> "${project_root}/.env"
run_online offline 1 0/0/0/0/0
if grep '^docker ' "${temp_dir}/calls" >/dev/null; then echo 'Offline bootstrap accessed Docker.' >&2; exit 1; fi
invoke_bootstrap environment-precedence 0 XINGCHEN_NETWORK_MODE=internal 'XINGCHEN_SETUP_IMAGE=registry.internal.example:5000/monitor/setup:old' bash "${bootstrap}" --project-root "${project_root}" --version "${target_version}"
assert_calls 1/1/1/1/1
grep -Fx "docker pull registry.internal.example:5000/monitor/setup:${target_version}" "${temp_dir}/calls" >/dev/null

printf '%s\n' "XINGCHEN_SETUP_IMAGE=\"${setup_repository}@${BOOTSTRAP_TEST_IMAGE_ID}\"" > "${project_root}/.env"
run_online pinned-digest 0 1/1/1/1/1
grep -Fx "docker pull ${setup_repository}@${BOOTSTRAP_TEST_IMAGE_ID}" "${temp_dir}/calls" >/dev/null
run_online wrong-version 1 1/0/0/0/0

reset_env
printf '%s\n' 'XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS="7"' >> "${project_root}/.env"
run_online custom-timeout 0 1/1/1/1/1
grep -Fx "timeout --foreground -s TERM -k 10 7 docker pull ${setup_repository}:${target_version}" "${temp_dir}/calls" >/dev/null
for invalid_setting in 'XINGCHEN_NETWORK_MODE="unrecognized"' 'XINGCHEN_ALLOW_GITEE="yes"' 'XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS="0"' 'XINGCHEN_UPDATE_MIN_FREE_BYTES="0"' 'XINGCHEN_UPDATE_MIN_FREE_BYTES="-1"' 'XINGCHEN_UPDATE_MIN_FREE_BYTES="1.5"' 'XINGCHEN_UPDATE_MIN_FREE_BYTES="invalid"' 'XINGCHEN_NETWORK_MODE =offline' 'export XINGCHEN_NETWORK_MODE=offline' 'XINGCHEN_NETWORK_MODE="offline' 'XINGCHEN_SETUP_IMAGE="$(touch should-never-exist)"'; do
  reset_env
  printf '%s\n' "${invalid_setting}" >> "${project_root}/.env"
  run_online invalid-setting 1 0/0/0/0/0
done
reset_env
printf '%s\n' 'XINGCHEN_NETWORK_MODE=public' 'XINGCHEN_NETWORK_MODE=offline' >> "${project_root}/.env"
run_online duplicate-setting 1 0/0/0/0/0
reset_env
run_online invalid-version 1 0/0/0/0/0 --version v1.20.20
run_online duplicate-mode 1 0/0/0/0/0 --check --apply
invoke_bootstrap relative-project 1 bash "${bootstrap}" --project-root . --version "${target_version}"
assert_calls 0/0/0/0/0

verify_fixture="${temp_dir}/verify-case"
for scenario in valid-package wrong-owner wrong-directory-mode missing-file extra-file extra-directory checksum-mismatch duplicate-checksum missing-checksum unexpected-checksum traversal-checksum absolute-checksum invalid-checksum wrong-package-version extra-version-line; do
  rm -rf -- "${verify_fixture}"
  mkdir "${verify_fixture}"
  cp -R -- "${package}/." "${verify_fixture}/"
  chmod 700 "${verify_fixture}" "${verify_fixture}/deploy"
  expected_status=1
  case "${scenario}" in
    valid-package) expected_status=0 ;;
    wrong-owner) ;;
    wrong-directory-mode) ;;
    missing-file) rm "${verify_fixture}/deploy/xingchen.sh" ;;
    extra-file) touch "${verify_fixture}/.unexpected" ;;
    extra-directory) mkdir "${verify_fixture}/deploy/extra" ;;
    checksum-mismatch) printf '%s\n' changed >> "${verify_fixture}/docker-compose.yml" ;;
    duplicate-checksum) head -n 1 "${verify_fixture}/SHA256SUMS" >> "${verify_fixture}/SHA256SUMS" ;;
    missing-checksum) sed -i '$d' "${verify_fixture}/SHA256SUMS" ;;
    unexpected-checksum) printf '%s  SHA256SUMS\n' "${BOOTSTRAP_TEST_CONTAINER_ID}" >> "${verify_fixture}/SHA256SUMS" ;;
    traversal-checksum) printf '%s  ../version\n' "${BOOTSTRAP_TEST_CONTAINER_ID}" > "${verify_fixture}/SHA256SUMS" ;;
    absolute-checksum) printf '%s  /etc/passwd\n' "${BOOTSTRAP_TEST_CONTAINER_ID}" > "${verify_fixture}/SHA256SUMS" ;;
    invalid-checksum) printf '%s\n' 'invalid  version' > "${verify_fixture}/SHA256SUMS" ;;
    wrong-package-version) printf '%s\n' v1.20.18 > "${verify_fixture}/version"; write_checksums "${verify_fixture}" ;;
    extra-version-line) printf '\n' >> "${verify_fixture}/version"; write_checksums "${verify_fixture}" ;;
  esac
  invoke_bootstrap "${scenario}" "${expected_status}" bash "${bootstrap}" --verify-package "${verify_fixture}" --version "${target_version}"
  [[ ! -s "${temp_dir}/calls" ]] || { echo 'Package verification invoked Docker or flock.' >&2; exit 1; }
done

rm -rf -- "${verify_fixture}"
mkdir "${verify_fixture}"
cp -R -- "${package}/." "${verify_fixture}/"
chmod 700 "${verify_fixture}" "${verify_fixture}/deploy"
rm "${verify_fixture}/deploy/xingchen.sh"
ln -s "${package}/deploy/xingchen.sh" "${verify_fixture}/deploy/xingchen.sh" 2>/dev/null || true
if [[ -L "${verify_fixture}/deploy/xingchen.sh" ]]; then
  invoke_bootstrap symlink-file 1 bash "${bootstrap}" --verify-package "${verify_fixture}" --version "${target_version}"
else
  echo 'Skipping package symlink regression: this environment cannot create native symlinks.'
fi
echo "Controller update bootstrap tests passed (${case_count} cases)."
