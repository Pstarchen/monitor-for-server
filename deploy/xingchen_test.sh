#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
manager="${script_dir}/xingchen.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

fail() {
  echo "$*" >&2
  exit 1
}

[[ -f "${manager}" ]] || fail "Missing manager script: ${manager}"

fake_bin="${test_root}/fake-bin"
mkdir -p "${fake_bin}"

cat > "${fake_bin}/git" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >> "${TEST_LOG}"

commit_for_version() {
  case "$1" in
    v1.9.9) printf '%s' '1111111111111111111111111111111111111111' ;;
    v1.20.16) printf '%s' '2222222222222222222222222222222222222222' ;;
    v1.20.17) printf '%s' '3333333333333333333333333333333333333333' ;;
    v2.0.0) printf '%s' '4444444444444444444444444444444444444444' ;;
    *) return 1 ;;
  esac
}

case " $* " in
  *' ls-remote '*)
    if [[ " $* " == *' --tags --refs '* ]]; then
      cat <<'TAGS'
1111111111111111111111111111111111111111	refs/tags/v1.9.9
2222222222222222222222222222222222222222	refs/tags/v1.20.16
3333333333333333333333333333333333333333	refs/tags/v1.20.17
4444444444444444444444444444444444444444	refs/tags/v2.0.0
5555555555555555555555555555555555555555	refs/tags/v9.0.0-rc.1
6666666666666666666666666666666666666666	refs/tags/latest
TAGS
    else
      requested=""
      for argument in "$@"; do
        case "${argument}" in
          refs/tags/v*) requested="${argument#refs/tags/}"; requested="${requested%%^*}" ;;
        esac
      done
      commit="$(commit_for_version "${requested}")" || exit 2
      printf '%s\trefs/tags/%s\n' "${commit}" "${requested}"
    fi
    ;;
  *' clone '*)
    clone_version=""
    previous=""
    for argument in "$@"; do
      if [[ "${previous}" == --branch ]]; then
        clone_version="${argument}"
      fi
      case "${argument}" in
        --branch=*) clone_version="${argument#--branch=}" ;;
      esac
      previous="${argument}"
    done
    commit="$(commit_for_version "${clone_version}")" || exit 2
    destination="${!#}"
    mkdir -p "${destination}/.git" "${destination}/deploy"
    printf '%s\n' "${commit}" > "${destination}/.fake-commit"
    printf '%s\n' "${commit}" > "${destination}/.fake-tag-${clone_version}"
    printf '%s\n' "${@: -2:1}" > "${destination}/.fake-origin"
    printf '%s\n' 'services: {}' > "${destination}/docker-compose.yml"
    cp "${TEST_XINGCHEN_SOURCE}" "${destination}/deploy/xingchen.sh"
    cat > "${destination}/deploy/install-controller.sh" <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
printf 'installer %s\n' "$*" >> "${TEST_LOG}"
for key in \
  XINGCHEN_TARGET_VERSION XINGCHEN_NETWORK_MODE XINGCHEN_ALLOW_GITEE \
  XINGCHEN_SOURCE_REPOSITORIES XINGCHEN_SOURCE_REF XINGCHEN_CONTROLLER_ALLOW_GITHUB_API \
  XINGCHEN_RELEASE_MANIFEST_PATH XINGCHEN_RELEASE_MANIFEST_URLS XINGCHEN_RELEASE_MANIFEST_SHA256 \
  XINGCHEN_AGENT_RELEASE_BASE_URLS XINGCHEN_AGENT_OFFLINE_DIR \
  XINGCHEN_SETUP_IMAGE XINGCHEN_SERVER_IMAGE XINGCHEN_WEB_IMAGE XINGCHEN_AGENT_IMAGE \
  XINGCHEN_POSTGRES_IMAGE XINGCHEN_REDIS_IMAGE; do
  printf 'installer-env %s=%s\n' "${key}" "${!key:-}" >> "${TEST_LOG}"
done
install_status=0
if [[ -f "${TEST_CASE_ROOT}/installer-status" ]]; then
  install_status="$(cat "${TEST_CASE_ROOT}/installer-status")"
fi
exit "${install_status}"
INSTALLER
    cat > "${destination}/deploy/update-controller.sh" <<'UPDATER'
#!/usr/bin/env bash
set -euo pipefail
printf 'updater %s\n' "$*" >> "${TEST_LOG}"
UPDATER
    chmod +x "${destination}/deploy/xingchen.sh" \
      "${destination}/deploy/install-controller.sh" \
      "${destination}/deploy/update-controller.sh"
    ;;
  *' remote get-url origin '*)
    [[ "${1:-}" == -C && -f "${2:-}/.fake-origin" ]] || exit 1
    cat "${2}/.fake-origin"
    ;;
  *' remote set-url origin '*)
    [[ "${1:-}" == -C ]]
    printf '%s\n' "${!#}" > "${2}/.fake-origin"
    ;;
  *' fetch '*)
    [[ "${1:-}" == -C ]]
    refspec="${!#}"
    fetched_version="${refspec#refs/tags/}"
    fetched_version="${fetched_version%%:*}"
    commit="$(commit_for_version "${fetched_version}")" || exit 2
    printf '%s\n' "${commit}" > "${2}/.fake-tag-${fetched_version}"
    ;;
  *' rev-parse '*)
    [[ "${1:-}" == -C ]] || exit 2
    revision="${!#}"
    if [[ "${revision}" == HEAD ]]; then
      cat "${2}/.fake-commit"
    elif [[ "${revision}" == refs/tags/v* ]]; then
      tag_version="${revision#refs/tags/}"
      tag_version="${tag_version%%^*}"
      [[ -f "${2}/.fake-tag-${tag_version}" ]] || exit 1
      cat "${2}/.fake-tag-${tag_version}"
    else
      exit 1
    fi
    ;;
  *' checkout '*)
    [[ "${1:-}" == -C ]]
    checkout_target="${!#}"
    if stable_version_commit="$(commit_for_version "${checkout_target}" 2>/dev/null)"; then
      printf '%s\n' "${stable_version_commit}" > "${2}/.fake-commit"
    elif [[ "${checkout_target}" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
      printf '%s\n' "${checkout_target,,}" > "${2}/.fake-commit"
    else
      exit 2
    fi
    ;;
  *' describe '*) printf '%s\n' 'v2.0.0' ;;
  *) ;;
esac
SCRIPT

cat > "${fake_bin}/docker" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "${TEST_LOG}"
if [[ "${1:-}" == compose && "${2:-}" == version ]]; then
  printf '%s\n' 'Docker Compose version v2.27.0'
fi
SCRIPT

cat > "${fake_bin}/curl" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "${TEST_LOG}"
if [[ " $* " == *' https://github.com/Pstarchen/monitor-for-server/releases/latest '* ]]; then
  printf '%s' 'https://github.com/Pstarchen/monitor-for-server/releases/tag/v1.20.17'
  exit 0
fi
echo 'Unexpected curl call in xingchen.sh test.' >&2
exit 97
SCRIPT

for command_name in wget systemctl apt-get dnf yum apk zypper pacman; do
  cat > "${fake_bin}/${command_name}" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >> "${TEST_LOG}"
echo "Unexpected external command in xingchen.sh test: $(basename "$0")" >&2
exit 97
SCRIPT
done

cat > "${fake_bin}/sudo" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'sudo %s\n' "$*" >> "${TEST_LOG}"
echo 'Unexpected sudo call in non-root test mode.' >&2
exit 97
SCRIPT

chmod +x "${fake_bin}"/*

new_case() {
  local name="$1" root="${test_root}/${1}"
  mkdir -p "${root}/home" "${root}/tmp" "${root}/manager-bin"
  : > "${root}/commands.log"
  printf '%s' "${root}"
}

run_manager() {
  local root="$1" cn="$2"
  shift 2
  env -i \
    PATH="${fake_bin}:${PATH}" \
    HOME="${root}/home" \
    TMPDIR="${root}/tmp" \
    TEST_LOG="${root}/commands.log" \
    TEST_CASE_ROOT="${root}" \
    TEST_XINGCHEN_SOURCE="${manager}" \
    XINGCHEN_MANAGER_ALLOW_NON_ROOT=true \
    XINGCHEN_MANAGER_LINK="${root}/manager-bin/xingchen" \
    CN="${cn}" \
    bash "${manager}" "$@"
}

assert_failed_without_external_calls() {
  local root="$1" cn="$2"
  shift 2
  if run_manager "${root}" "${cn}" "$@" >"${root}/stdout.log" 2>"${root}/stderr.log"; then
    fail "Command unexpectedly succeeded: $*"
  fi
  [[ ! -s "${root}/commands.log" ]] \
    || fail "Invalid input reached an external command: $*"
}

invalid_command_root="$(new_case invalid-command)"
assert_failed_without_external_calls "${invalid_command_root}" false destroy --yes

for invalid_version in main v1.2 1.2.3 v01.2.3 v1.2.3-rc.1; do
  invalid_version_root="$(new_case "invalid-version-${invalid_version//[^A-Za-z0-9]/-}")"
  assert_failed_without_external_calls "${invalid_version_root}" false install \
    --version "${invalid_version}" \
    --install-dir "${invalid_version_root}/controller" \
    --yes
done

invalid_directory_root="$(new_case invalid-directory)"
assert_failed_without_external_calls "${invalid_directory_root}" false install \
  --version v1.20.16 \
  --install-dir relative/controller \
  --yes

help_root="$(new_case help)"
run_manager "${help_root}" false help >"${help_root}/stdout.log"
for command_name in install update status logs restart help; do
  grep -F -- "${command_name}" "${help_root}/stdout.log" >/dev/null \
    || fail "Help output does not mention ${command_name}."
done
[[ ! -s "${help_root}/commands.log" ]] || fail 'Help invoked an external command.'

cn_root="$(new_case cn-default)"
run_manager "${cn_root}" true install \
  --install-dir "${cn_root}/controller" \
  --yes
grep -E '^git ls-remote .*https://gitee\.com/starchen520/monitor-for-server(\.git)?' \
  "${cn_root}/commands.log" >/dev/null \
  || fail 'CN=true did not discover releases from Gitee.'
grep -E '^git clone .*--branch v2\.0\.0 .*https://gitee\.com/starchen520/monitor-for-server(\.git)? ' \
  "${cn_root}/commands.log" >/dev/null \
  || fail 'The newest stable tag was not cloned from Gitee.'
if grep -F 'github.com' "${cn_root}/commands.log" >/dev/null; then
  fail 'CN=true contacted GitHub.'
fi
grep -Fx 'installer --no-source-fallback' "${cn_root}/commands.log" >/dev/null \
  || fail 'CN install did not select the prebuilt-only installer path.'
if grep -E '^installer .*--build( |$)' "${cn_root}/commands.log" >/dev/null; then
  fail 'CN install unexpectedly requested a local image build.'
fi
for expected_setting in \
  'XINGCHEN_NETWORK_MODE=public' \
  'XINGCHEN_ALLOW_GITEE=true' \
  'XINGCHEN_SOURCE_REPOSITORIES=https://gitee.com/starchen520/monitor-for-server.git' \
  'XINGCHEN_SOURCE_REF=v2.0.0' \
  'XINGCHEN_CONTROLLER_ALLOW_GITHUB_API=false' \
  'XINGCHEN_RELEASE_MANIFEST_PATH=' \
  'XINGCHEN_RELEASE_MANIFEST_URLS=' \
  'XINGCHEN_RELEASE_MANIFEST_SHA256=' \
  'XINGCHEN_AGENT_RELEASE_BASE_URLS=' \
  'XINGCHEN_AGENT_OFFLINE_DIR=' \
  'XINGCHEN_SETUP_IMAGE=ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-setup:v2.0.0' \
  'XINGCHEN_SERVER_IMAGE=ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-server:v2.0.0' \
  'XINGCHEN_WEB_IMAGE=ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-web:v2.0.0' \
  'XINGCHEN_AGENT_IMAGE=ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-agent:v2.0.0' \
  'XINGCHEN_POSTGRES_IMAGE=ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-postgres:v2.0.0' \
  'XINGCHEN_REDIS_IMAGE=ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-redis:v2.0.0'; do
  grep -Fx "installer-env ${expected_setting}" "${cn_root}/commands.log" >/dev/null \
    || fail "CN install did not export ${expected_setting}."
done

source_override_root="$(new_case source-override)"
run_manager "${source_override_root}" true install \
  --version v1.20.16 \
  --install-dir "${source_override_root}/controller" \
  --source github \
  --yes
grep -E '^git clone .*--branch v1\.20\.16 .*https://github\.com/Pstarchen/monitor-for-server(\.git)? ' \
  "${source_override_root}/commands.log" >/dev/null \
  || fail 'Explicit --source github did not override CN=true.'
if grep -F 'gitee.com' "${source_override_root}/commands.log" >/dev/null; then
  fail 'Explicit GitHub source also contacted Gitee.'
fi
grep -Fx 'installer-env XINGCHEN_CONTROLLER_ALLOW_GITHUB_API=true' \
  "${source_override_root}/commands.log" >/dev/null \
  || fail 'Explicit GitHub source did not enable published Release discovery.'

github_latest_root="$(new_case github-latest-release)"
run_manager "${github_latest_root}" false install \
  --install-dir "${github_latest_root}/controller" \
  --yes
grep -F 'https://github.com/Pstarchen/monitor-for-server/releases/latest' \
  "${github_latest_root}/commands.log" >/dev/null \
  || fail 'GitHub latest-version discovery did not query the published Release.'
grep -E '^git clone .*--branch v1\.20\.17 .*https://github\.com/Pstarchen/monitor-for-server(\.git)? ' \
  "${github_latest_root}/commands.log" >/dev/null \
  || fail 'GitHub latest-version discovery did not select the published stable Release.'

retry_root="$(new_case incomplete-retry)"
printf '%s\n' '19' > "${retry_root}/installer-status"
if run_manager "${retry_root}" true install \
  --version v1.20.16 \
  --install-dir "${retry_root}/controller" \
  --yes >"${retry_root}/first.stdout.log" 2>"${retry_root}/first.stderr.log"; then
  fail 'Install unexpectedly succeeded after the installer failed.'
fi
[[ -f "${retry_root}/controller/.xingchen-install-incomplete" ]] \
  || fail 'Failed install did not preserve its incomplete marker.'
grep -Fx 'version=v1.20.16' "${retry_root}/controller/.xingchen-install-incomplete" >/dev/null \
  || fail 'Incomplete marker did not preserve the selected version.'
grep -Fx 'repository=https://gitee.com/starchen520/monitor-for-server.git' \
  "${retry_root}/controller/.xingchen-install-incomplete" >/dev/null \
  || fail 'Incomplete marker did not preserve the selected repository.'
printf '%s\n' '0' > "${retry_root}/installer-status"
run_manager "${retry_root}" true install \
  --version v1.20.16 \
  --install-dir "${retry_root}/controller" \
  --yes
[[ ! -e "${retry_root}/controller/.xingchen-install-incomplete" ]] \
  || fail 'Successful install retry did not remove the incomplete marker.'
[[ "$(grep -c '^git clone ' "${retry_root}/commands.log")" -eq 1 ]] \
  || fail 'Install retry cloned the repository again.'
[[ "$(grep -c '^installer --no-source-fallback$' "${retry_root}/commands.log")" -eq 2 ]] \
  || fail 'Install retry did not invoke the installer exactly twice.'

existing_root="$(new_case existing-deployment)"
mkdir -p "${existing_root}/controller"
printf '%s\n' 'services: {}' > "${existing_root}/controller/docker-compose.yml"
assert_failed_without_external_calls "${existing_root}" true install \
  --version v1.20.16 \
  --install-dir "${existing_root}/controller" \
  --yes

make_update_deployment() {
  local root="$1" updater_status="$2" deployment
  deployment="${root}/controller"
  mkdir -p "${deployment}/.git" "${deployment}/deploy"
  printf '%s\n' 'services: {}' > "${deployment}/docker-compose.yml"
  printf '%s\n' \
    'XINGCHEN_TARGET_VERSION=v1.20.16' \
    'XINGCHEN_NETWORK_MODE=offline' \
    'XINGCHEN_RELEASE_MANIFEST_PATH=/workspace/release/versions/v1.20.16/manifest.json' \
    'XINGCHEN_RELEASE_MANIFEST_URLS=https://github.com/Pstarchen/monitor-for-server/releases/latest/download/manifest.json' \
    'XINGCHEN_RELEASE_MANIFEST_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'XINGCHEN_AGENT_RELEASE_BASE_URLS=https://github.com/Pstarchen/monitor-for-server/releases/download' \
    'XINGCHEN_AGENT_OFFLINE_DIR=/workspace/release/versions/v1.20.16/assets' \
    'CUSTOM_SETTING=preserve-me' > "${deployment}/.env"
  printf '%s\n' '2222222222222222222222222222222222222222' > "${deployment}/.fake-commit"
  printf '%s\n' '2222222222222222222222222222222222222222' > "${deployment}/.fake-tag-v1.20.16"
  printf '%s\n' 'https://gitee.com/starchen520/monitor-for-server.git' > "${deployment}/.fake-origin"
  printf '%s\n' "${updater_status}" > "${deployment}/.fake-updater-status"
  cp "${manager}" "${deployment}/deploy/xingchen.sh"
  printf '%s\n' '#!/usr/bin/env bash' > "${deployment}/deploy/install-controller.sh"
  cat > "${deployment}/deploy/update-controller.sh" <<'UPDATER'
#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
printf 'updater %s\n' "$*" >> "${TEST_LOG}"
for key in \
  XINGCHEN_TARGET_VERSION XINGCHEN_NETWORK_MODE XINGCHEN_ALLOW_GITEE \
  XINGCHEN_SOURCE_REPOSITORIES XINGCHEN_SOURCE_REF XINGCHEN_CONTROLLER_ALLOW_GITHUB_API \
  XINGCHEN_RELEASE_MANIFEST_PATH XINGCHEN_RELEASE_MANIFEST_URLS XINGCHEN_RELEASE_MANIFEST_SHA256 \
  XINGCHEN_AGENT_RELEASE_BASE_URLS XINGCHEN_AGENT_OFFLINE_DIR \
  XINGCHEN_SETUP_IMAGE XINGCHEN_SERVER_IMAGE XINGCHEN_WEB_IMAGE XINGCHEN_AGENT_IMAGE \
  XINGCHEN_POSTGRES_IMAGE XINGCHEN_REDIS_IMAGE; do
  printf 'updater-env %s=%s\n' "${key}" "${!key:-}" >> "${TEST_LOG}"
done
exit "$(cat "${project_root}/.fake-updater-status")"
UPDATER
  chmod +x "${deployment}/deploy/xingchen.sh" \
    "${deployment}/deploy/install-controller.sh" \
    "${deployment}/deploy/update-controller.sh"
}

update_success_root="$(new_case update-success)"
make_update_deployment "${update_success_root}" 0
run_manager "${update_success_root}" true update \
  --version v1.20.17 \
  --install-dir "${update_success_root}/controller" \
  --yes
grep -F "git -C ${update_success_root}/controller checkout --detach v1.20.17" \
  "${update_success_root}/commands.log" >/dev/null \
  || fail 'Successful update did not checkout v1.20.17.'
grep -Fx 'updater --apply --no-source-fallback' \
  "${update_success_root}/commands.log" >/dev/null \
  || fail 'Successful Gitee update did not use the required updater arguments.'
if grep -E '^updater .*--build( |$)' "${update_success_root}/commands.log" >/dev/null; then
  fail 'Successful Gitee update unexpectedly requested a local image build.'
fi
grep -Fx '3333333333333333333333333333333333333333' \
  "${update_success_root}/controller/.fake-commit" >/dev/null \
  || fail 'Successful update did not leave HEAD at v1.20.17.'
grep -Fx 'CUSTOM_SETTING=preserve-me' "${update_success_root}/controller/.env" >/dev/null \
  || fail 'Successful update removed an unrelated environment setting.'
for expected_setting in \
  'XINGCHEN_TARGET_VERSION=v1.20.17' \
  'XINGCHEN_NETWORK_MODE=public' \
  'XINGCHEN_ALLOW_GITEE=true' \
  'XINGCHEN_SOURCE_REPOSITORIES=https://gitee.com/starchen520/monitor-for-server.git' \
  'XINGCHEN_SOURCE_REF=v1.20.17' \
  'XINGCHEN_CONTROLLER_ALLOW_GITHUB_API=false' \
  'XINGCHEN_RELEASE_MANIFEST_PATH=' \
  'XINGCHEN_RELEASE_MANIFEST_URLS=' \
  'XINGCHEN_RELEASE_MANIFEST_SHA256=' \
  'XINGCHEN_AGENT_RELEASE_BASE_URLS=' \
  'XINGCHEN_AGENT_OFFLINE_DIR=' \
  'XINGCHEN_SETUP_IMAGE=ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-setup:v1.20.17' \
  'XINGCHEN_SERVER_IMAGE=ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-server:v1.20.17' \
  'XINGCHEN_WEB_IMAGE=ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-web:v1.20.17' \
  'XINGCHEN_AGENT_IMAGE=ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-agent:v1.20.17' \
  'XINGCHEN_POSTGRES_IMAGE=ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-postgres:v1.20.17' \
  'XINGCHEN_REDIS_IMAGE=ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-redis:v1.20.17'; do
  grep -Fx "${expected_setting}" "${update_success_root}/controller/.env" >/dev/null \
    || fail "Successful update did not persist ${expected_setting}."
  grep -Fx "updater-env ${expected_setting}" "${update_success_root}/commands.log" >/dev/null \
    || fail "Successful updater did not receive ${expected_setting}."
done

same_version_root="$(new_case update-same-version)"
make_update_deployment "${same_version_root}" 0
run_manager "${same_version_root}" true update \
  --version v1.20.16 \
  --install-dir "${same_version_root}/controller" \
  --yes
grep -Fx 'updater --apply --no-source-fallback' \
  "${same_version_root}/commands.log" >/dev/null \
  || fail 'Same-version update skipped the updater.'
grep -F "git -C ${same_version_root}/controller checkout --detach v1.20.16" \
  "${same_version_root}/commands.log" >/dev/null \
  || fail 'Same-version update did not verify and checkout its stable tag.'

update_failure_root="$(new_case update-failure)"
make_update_deployment "${update_failure_root}" 23
cp "${update_failure_root}/controller/.env" "${update_failure_root}/env.before"
if run_manager "${update_failure_root}" true update \
  --version v1.20.17 \
  --install-dir "${update_failure_root}/controller" \
  --source github \
  --yes >"${update_failure_root}/stdout.log" 2>"${update_failure_root}/stderr.log"; then
  fail 'Update unexpectedly succeeded after the updater failed.'
fi
grep -F "git -C ${update_failure_root}/controller checkout --detach v1.20.17" \
  "${update_failure_root}/commands.log" >/dev/null \
  || fail 'Failed update never checked out the candidate tag.'
grep -Fx 'updater --apply --no-source-fallback' \
  "${update_failure_root}/commands.log" >/dev/null \
  || fail 'Failed update did not invoke the updater with the required arguments.'
grep -F "git -C ${update_failure_root}/controller remote set-url origin https://github.com/Pstarchen/monitor-for-server.git" \
  "${update_failure_root}/commands.log" >/dev/null \
  || fail 'Failure fixture never switched origin before invoking the updater.'
grep -F "git -C ${update_failure_root}/controller checkout --detach 2222222222222222222222222222222222222222" \
  "${update_failure_root}/commands.log" >/dev/null \
  || fail 'Updater failure did not checkout the previous commit.'
grep -Fx '2222222222222222222222222222222222222222' \
  "${update_failure_root}/controller/.fake-commit" >/dev/null \
  || fail 'Updater failure did not restore the previous HEAD.'
grep -Fx 'https://gitee.com/starchen520/monitor-for-server.git' \
  "${update_failure_root}/controller/.fake-origin" >/dev/null \
  || fail 'Updater failure did not restore the previous origin.'
cmp -s "${update_failure_root}/env.before" "${update_failure_root}/controller/.env" \
  || fail 'Updater failure did not restore the previous .env exactly.'

compose_root="$(new_case compose-commands)"
mkdir -p "${compose_root}/controller/.git" "${compose_root}/controller/deploy"
printf '%s\n' 'services: {}' > "${compose_root}/controller/docker-compose.yml"
printf '%s\n' 'POSTGRES_PASSWORD=test-only' > "${compose_root}/controller/.env"
printf '%s\n' '#!/usr/bin/env bash' > "${compose_root}/controller/deploy/install-controller.sh"

: > "${compose_root}/commands.log"
run_manager "${compose_root}" false status --install-dir "${compose_root}/controller"
grep -E '^docker compose .*ps( |$)' "${compose_root}/commands.log" >/dev/null \
  || fail 'status did not use Docker Compose ps.'

: > "${compose_root}/commands.log"
run_manager "${compose_root}" false logs --install-dir "${compose_root}/controller"
grep -E '^docker compose .*logs( |$)' "${compose_root}/commands.log" >/dev/null \
  || fail 'logs did not use Docker Compose logs.'

: > "${compose_root}/commands.log"
run_manager "${compose_root}" false restart --install-dir "${compose_root}/controller"
grep -E '^docker compose .*up .*--force-recreate( |$)' "${compose_root}/commands.log" >/dev/null \
  || fail 'restart did not recreate services with Docker Compose.'

echo 'xingchen.sh behavior tests passed.'
