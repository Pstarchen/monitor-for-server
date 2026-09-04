#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
installer="${script_dir}/install-controller.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

fail() {
  echo "$*" >&2
  exit 1
}

make_fixture() {
  local name="$1" root="${test_root}/$1"
  mkdir -p "${root}/deploy"
  cp "${installer}" "${root}/deploy/install-controller.sh"
  printf '%s\n' 'services: {}' > "${root}/docker-compose.yml"
  cat > "${root}/deploy/update-controller.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf 'updater mode=%s allow_gitee=%s args=%s\n' \
  "${XINGCHEN_NETWORK_MODE:-}" "${XINGCHEN_ALLOW_GITEE:-}" "$*" >> "${TEST_LOG}"
SCRIPT
  chmod +x "${root}/deploy/update-controller.sh"
  printf '%s' "${root}"
}

make_fake_runtime() {
  local root="$1"
  mkdir -p "${root}"
  cat > "${root}/docker" <<'SCRIPT'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${TEST_LOG}"
if [[ "${1:-}" == volume && "${2:-}" == inspect ]]; then
  exit 1
fi
exit 0
SCRIPT
  cat > "${root}/curl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${TEST_LOG}"
exit 0
SCRIPT
  chmod +x "${root}/docker" "${root}/curl"
}

run_installer() {
  local root="$1"
  shift
  env -i PATH="${root}/bin:${PATH}" TEST_LOG="${root}/commands.log" "$@" \
    bash "${root}/deploy/install-controller.sh" --no-install-dependencies
}

assert_installer_policy_rejected() {
  local root="$1" expected_error="$2"
  cp "${root}/.env" "${root}/env.before"
  if run_installer "${root}" env >"${root}/stdout.log" 2>"${root}/stderr.log"; then
    fail "Installer accepted unsafe network policy fixture: ${root}."
  fi
  cmp -s "${root}/env.before" "${root}/.env" \
    || fail "Installer modified a rejected network policy file: ${root}."
  [[ ! -s "${root}/commands.log" ]] \
    || fail "Installer reached a runtime or network command before rejecting ${root}."
  grep -F -- "${expected_error}" "${root}/stderr.log" >/dev/null \
    || fail "Installer did not report the expected network policy error for ${root}."
}

existing_root="$(make_fixture existing-policy)"
make_fake_runtime "${existing_root}/bin"
cat > "${existing_root}/.env" <<'ENV'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE="internal"
XINGCHEN_ALLOW_GITEE="true"
CUSTOM_SETTING="preserve-me"
ENV
run_installer "${existing_root}" env
grep -Fx 'XINGCHEN_NETWORK_MODE=internal' "${existing_root}/.env" >/dev/null \
  || fail 'Existing internal network mode was not preserved.'
grep -Fx 'XINGCHEN_ALLOW_GITEE=true' "${existing_root}/.env" >/dev/null \
  || fail 'Existing Gitee policy was not preserved.'
grep -Fx 'CUSTOM_SETTING="preserve-me"' "${existing_root}/.env" >/dev/null \
  || fail 'Unrelated existing settings were changed.'
grep -F 'updater mode=internal allow_gitee=true' "${existing_root}/commands.log" >/dev/null \
  || fail 'Inherited network policy was not passed to the updater.'

process_root="$(make_fixture process-policy)"
make_fake_runtime "${process_root}/bin"
cat > "${process_root}/.env" <<'ENV'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE="offline"
XINGCHEN_ALLOW_GITEE="false"
ENV
run_installer "${process_root}" env XINGCHEN_NETWORK_MODE=public XINGCHEN_ALLOW_GITEE=true
grep -Fx 'XINGCHEN_NETWORK_MODE=public' "${process_root}/.env" >/dev/null \
  || fail 'Process network mode did not override the existing file.'
grep -Fx 'XINGCHEN_ALLOW_GITEE=true' "${process_root}/.env" >/dev/null \
  || fail 'Process Gitee policy did not override the existing file.'

argument_root="$(make_fixture argument-policy)"
make_fake_runtime "${argument_root}/bin"
cat > "${argument_root}/.env" <<'ENV'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE="offline"
ENV
env -i PATH="${argument_root}/bin:${PATH}" TEST_LOG="${argument_root}/commands.log" \
  XINGCHEN_NETWORK_MODE=internal bash "${argument_root}/deploy/install-controller.sh" \
  --network-mode public --no-install-dependencies
grep -Fx 'XINGCHEN_NETWORK_MODE=public' "${argument_root}/.env" >/dev/null \
  || fail 'Explicit network mode did not override the process environment.'

duplicate_mode_root="$(make_fixture duplicate-network-mode)"
make_fake_runtime "${duplicate_mode_root}/bin"
cat > "${duplicate_mode_root}/.env" <<'ENV'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE="internal"
XINGCHEN_NETWORK_MODE="public"
ENV
assert_installer_policy_rejected "${duplicate_mode_root}" 'XINGCHEN_NETWORK_MODE 重复'

invalid_mode_root="$(make_fixture invalid-network-mode)"
make_fake_runtime "${invalid_mode_root}/bin"
cat > "${invalid_mode_root}/.env" <<'ENV'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE="restricted"
ENV
assert_installer_policy_rejected "${invalid_mode_root}" '--network-mode 必须是'

malformed_mode_root="$(make_fixture malformed-network-mode)"
make_fake_runtime "${malformed_mode_root}/bin"
cat > "${malformed_mode_root}/.env" <<'ENV'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE internal
ENV
assert_installer_policy_rejected "${malformed_mode_root}" 'XINGCHEN_NETWORK_MODE 无法解析'

nonregular_env_root="$(make_fixture nonregular-network-policy)"
make_fake_runtime "${nonregular_env_root}/bin"
mkdir "${nonregular_env_root}/.env"
if run_installer "${nonregular_env_root}" env >"${nonregular_env_root}/stdout.log" 2>"${nonregular_env_root}/stderr.log"; then
  fail 'Installer accepted a non-regular .env file.'
fi
[[ ! -s "${nonregular_env_root}/commands.log" ]] \
  || fail 'Installer reached a runtime or network command with a non-regular .env file.'
grep -F '.env 不可读或不是普通文件' "${nonregular_env_root}/stderr.log" >/dev/null \
  || fail 'Installer did not report the unusable .env file.'

unreadable_env_root="$(make_fixture unreadable-network-policy)"
make_fake_runtime "${unreadable_env_root}/bin"
cat > "${unreadable_env_root}/.env" <<'ENV'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE="internal"
ENV
chmod 000 "${unreadable_env_root}/.env"
if [[ ! -r "${unreadable_env_root}/.env" ]]; then
  set +e
  run_installer "${unreadable_env_root}" env >"${unreadable_env_root}/stdout.log" 2>"${unreadable_env_root}/stderr.log"
  unreadable_status=$?
  set -e
  chmod 600 "${unreadable_env_root}/.env"
  [[ "${unreadable_status}" -ne 0 ]] || fail 'Installer accepted an unreadable .env file.'
  [[ ! -s "${unreadable_env_root}/commands.log" ]] \
    || fail 'Installer reached a runtime or network command with an unreadable .env file.'
  grep -F '.env 不可读或不是普通文件' "${unreadable_env_root}/stderr.log" >/dev/null \
    || fail 'Installer did not report the unreadable .env file.'
else
  chmod 600 "${unreadable_env_root}/.env"
fi

missing_password_root="$(make_fixture missing-password)"
make_fake_runtime "${missing_password_root}/bin"
cat > "${missing_password_root}/.env" <<'ENV'
XINGCHEN_NETWORK_MODE="public"
WEB_PORT="19090"
CUSTOM_SETTING="preserve-me"
ENV
run_installer "${missing_password_root}" env
grep -Fx 'WEB_PORT="19090"' "${missing_password_root}/.env" >/dev/null \
  || fail 'Adding a password removed the configured Web port.'
grep -Fx 'CUSTOM_SETTING="preserve-me"' "${missing_password_root}/.env" >/dev/null \
  || fail 'Adding a password removed an unrelated setting.'
[[ "$(grep -c '^POSTGRES_PASSWORD=' "${missing_password_root}/.env")" -eq 1 ]] \
  || fail 'A missing PostgreSQL password was not added exactly once.'
grep -Eq '^POSTGRES_PASSWORD=[0-9a-f]{64}$' "${missing_password_root}/.env" \
  || fail 'The generated PostgreSQL password is invalid.'

invalid_password_root="$(make_fixture invalid-password)"
make_fake_runtime "${invalid_password_root}/bin"
cat > "${invalid_password_root}/.env" <<'ENV'
POSTGRES_PASSWORD=""
XINGCHEN_NETWORK_MODE="public"
CUSTOM_SETTING="preserve-me"
ENV
cp "${invalid_password_root}/.env" "${invalid_password_root}/env.before"
if run_installer "${invalid_password_root}" env >"${invalid_password_root}/stdout.log" 2>"${invalid_password_root}/stderr.log"; then
  fail 'An invalid existing PostgreSQL password was accepted.'
fi
cmp -s "${invalid_password_root}/env.before" "${invalid_password_root}/.env" \
  || fail 'The invalid existing environment file was modified.'
grep -F 'POSTGRES_PASSWORD 非法或重复' "${invalid_password_root}/stderr.log" >/dev/null \
  || fail 'The invalid password error was not actionable.'

make_minimal_path() {
  local destination="$1" command_path command_name
  mkdir -p "${destination}"
  for command_name in awk bash cat chmod cut dirname grep head mktemp mv openssl sleep tr uname; do
    command_path="$(command -v "${command_name}")"
    printf '#!/bin/sh\nexec %q "$@"\n' "${command_path}" > "${destination}/${command_name}"
    chmod +x "${destination}/${command_name}"
  done
}

restricted_root="$(make_fixture restricted-dependencies)"
restricted_bin="${restricted_root}/minimal-bin"
make_minimal_path "${restricted_bin}"
cat > "${restricted_bin}/awk" <<'SCRIPT'
#!/bin/sh
printf 'awk must not parse network policy\n' >> "${TEST_LOG}"
exit 91
SCRIPT
cat > "${restricted_bin}/apt-get" <<'SCRIPT'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${TEST_LOG}"
exit 0
SCRIPT
chmod +x "${restricted_bin}/awk" "${restricted_bin}/apt-get"
cat > "${restricted_root}/.env" <<'ENV'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE="internal"
ENV
if env -i PATH="${restricted_bin}" TEST_LOG="${restricted_root}/commands.log" \
  "${restricted_bin}/bash" "${restricted_root}/deploy/install-controller.sh" \
  >"${restricted_root}/stdout.log" 2>"${restricted_root}/stderr.log"; then
  fail 'Internal mode accepted missing runtime dependencies.'
fi
[[ ! -e "${restricted_root}/commands.log" ]] \
  || fail 'Internal mode invoked a package manager.'
if ! grep -F 'internal' "${restricted_root}/stderr.log" >/dev/null; then
  cat "${restricted_root}/stderr.log" >&2
  fail 'Internal dependency failure did not explain the network restriction.'
fi

public_disabled_root="$(make_fixture public-disabled-dependencies)"
public_disabled_bin="${public_disabled_root}/minimal-bin"
make_minimal_path "${public_disabled_bin}"
cat > "${public_disabled_bin}/apt-get" <<'SCRIPT'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${TEST_LOG}"
exit 0
SCRIPT
chmod +x "${public_disabled_bin}/apt-get"
cat > "${public_disabled_root}/.env" <<'ENV'
POSTGRES_PASSWORD="existing-password"
XINGCHEN_NETWORK_MODE="public"
ENV
if env -i PATH="${public_disabled_bin}" TEST_LOG="${public_disabled_root}/commands.log" \
  "${public_disabled_bin}/bash" "${public_disabled_root}/deploy/install-controller.sh" --no-install-dependencies \
  >"${public_disabled_root}/stdout.log" 2>"${public_disabled_root}/stderr.log"; then
  fail 'The dependency-install opt-out accepted missing dependencies.'
fi
[[ ! -e "${public_disabled_root}/commands.log" ]] \
  || fail 'The dependency-install opt-out invoked a package manager.'

public_root="$(make_fixture public-dependencies)"
public_bin="${public_root}/minimal-bin"
make_minimal_path "${public_bin}"
cat > "${public_bin}/sudo" <<'SCRIPT'
#!/usr/bin/env bash
"$@"
SCRIPT
cat > "${public_bin}/apt-get" <<'SCRIPT'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${TEST_LOG}"
if [[ "${1:-}" == install ]]; then
  printf '%s\n' '#!/usr/bin/env bash' 'printf "docker %s\\n" "$*" >> "${TEST_LOG}"' \
    '[[ "${1:-}" == volume && "${2:-}" == inspect ]] && exit 1' 'exit 0' > "${FAKE_BIN}/docker"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "curl %s\\n" "$*" >> "${TEST_LOG}"' 'exit 0' > "${FAKE_BIN}/curl"
  chmod +x "${FAKE_BIN}/docker" "${FAKE_BIN}/curl"
fi
exit 0
SCRIPT
chmod +x "${public_bin}/sudo" "${public_bin}/apt-get"
env -i PATH="${public_bin}" TEST_LOG="${public_root}/commands.log" FAKE_BIN="${public_bin}" \
  "${public_bin}/bash" "${public_root}/deploy/install-controller.sh"
grep -F 'apt-get update' "${public_root}/commands.log" >/dev/null \
  || fail 'Public mode did not refresh package metadata.'
grep -F 'apt-get install -y curl docker.io docker-compose-v2' "${public_root}/commands.log" >/dev/null \
  || fail 'Public mode did not install Docker, Compose, and curl.'

echo 'install-controller.sh behavior tests passed.'
