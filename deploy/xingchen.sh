#!/usr/bin/env bash
set -euo pipefail

GITEE_REPOSITORY="https://gitee.com/starchen520/monitor-for-server.git"
GITHUB_REPOSITORY="https://github.com/Pstarchen/monitor-for-server.git"
TCR_IMAGE_PREFIX="ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server"
DEFAULT_INSTALL_DIR="/opt/guanlan-monitor"

usage() {
  cat <<'USAGE'
Usage: xingchen.sh [install|update|status|logs|restart|help] [options]

Commands:
  install   install a new Controller with Docker Compose
  update    update an existing Controller to a stable version
  status    show Controller service status
  logs      show the latest Controller logs
  restart   recreate Controller services and wait for health checks
  help      show this help

Options:
  --version vX.Y.Z       install or update to an exact stable version
  --install-dir PATH     Controller directory (default: /opt/guanlan-monitor)
  --source gitee|github  source used for tags and repository content
  --yes                  skip an interactive confirmation

Environment:
  CN=true selects Gitee when --source is omitted. An existing installation
  keeps using the host configured as its git origin.
USAGE
}

command_name=""
requested_version="${XINGCHEN_VERSION:-}"
install_dir="${XINGCHEN_INSTALL_DIR:-${DEFAULT_INSTALL_DIR}}"
source_name="${XINGCHEN_SOURCE:-}"
source_explicit=false
assume_yes=false
menu_selection=false

if [[ -n "${source_name}" ]]; then
  source_explicit=true
fi

while (($# > 0)); do
  case "$1" in
    install|update|status|logs|restart|help)
      [[ -z "${command_name}" ]] || { echo "只能指定一个命令。" >&2; exit 2; }
      command_name="$1"
      shift
      ;;
    --version)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--version 需要版本值。" >&2; exit 2; }
      requested_version="$2"
      shift 2
      ;;
    --install-dir)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--install-dir 需要绝对路径。" >&2; exit 2; }
      install_dir="$2"
      shift 2
      ;;
    --source)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--source 需要 gitee 或 github。" >&2; exit 2; }
      source_name="${2,,}"
      source_explicit=true
      shift 2
      ;;
    --yes|-y)
      assume_yes=true
      shift
      ;;
    --help|-h)
      command_name=help
      shift
      ;;
    *)
      echo "未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

stable_version() {
  [[ "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

validate_install_dir() {
  [[ "${install_dir}" == /* ]] || { echo "--install-dir 必须是绝对路径。" >&2; exit 2; }
  [[ "${install_dir}" != / && "${install_dir}" != /opt && "${install_dir}" != /usr && "${install_dir}" != /var && "${install_dir}" != /home ]] \
    || { echo "--install-dir 不能指向系统顶级目录。" >&2; exit 2; }
  [[ "${install_dir}" != *$'\n'* && "${install_dir}" != *$'\r'* && "/${install_dir#/}/" != */../* && "/${install_dir#/}/" != */./* ]] \
    || { echo "--install-dir 包含不安全的路径片段。" >&2; exit 2; }
}

if [[ -n "${requested_version}" ]] && ! stable_version "${requested_version}"; then
  echo "--version 必须是稳定语义版本，例如 v1.20.17。" >&2
  exit 2
fi
validate_install_dir

infer_source_from_installation() {
  [[ "${source_explicit}" == false && -d "${install_dir}/.git" ]] || return 0
  local origin
  origin="$(git -C "${install_dir}" remote get-url origin 2>/dev/null || true)"
  case "${origin,,}" in
    *gitee.com/*) source_name=gitee ;;
    *github.com/*) source_name=github ;;
  esac
}

infer_source_from_installation
if [[ -z "${source_name}" ]]; then
  case "${CN:-false}" in
    true|TRUE|True|1|yes|YES|Yes) source_name=gitee ;;
    *) source_name=github ;;
  esac
fi
if [[ "${source_name}" != gitee && "${source_name}" != github ]]; then
  echo "--source 只能是 gitee 或 github。" >&2
  exit 2
fi

if [[ "${source_name}" == gitee ]]; then
  repository_url="${GITEE_REPOSITORY}"
else
  repository_url="${GITHUB_REPOSITORY}"
fi

deployment_exists() {
  [[ -d "${install_dir}/.git" && -f "${install_dir}/docker-compose.yml" && -f "${install_dir}/deploy/install-controller.sh" ]]
}

install_marker_path() {
  printf '%s/.xingchen-install-incomplete' "${install_dir}"
}

current_version() {
  local value=""
  if [[ -f "${install_dir}/.env" ]]; then
    value="$(awk -F= '$1 == "XINGCHEN_TARGET_VERSION" {value=$0; sub(/^[^=]*=/, "", value); gsub(/^"|"$/, "", value); print value; exit}' "${install_dir}/.env")"
  fi
  if ! stable_version "${value}" && [[ -d "${install_dir}/.git" ]]; then
    value="$(git -C "${install_dir}" describe --tags --exact-match 2>/dev/null || true)"
  fi
  stable_version "${value}" && printf '%s' "${value}"
}

show_menu() {
  local installed="未安装" version choice
  if deployment_exists; then
    version="$(current_version || true)"
    installed="${version:-已安装}"
  fi
  cat <<MENU

星辰监控总控管理脚本
当前状态：${installed}
安装目录：${install_dir}
在线源：${source_name}

  1) 安装总控
  2) 更新总控
  3) 查看状态
  4) 查看日志
  5) 重启服务
  0) 退出
MENU
  read -r -p "请选择 [0-5]: " choice
  case "${choice}" in
    1) command_name=install ;;
    2) command_name=update ;;
    3) command_name=status ;;
    4) command_name=logs ;;
    5) command_name=restart ;;
    0) exit 0 ;;
    *) echo "无效选择。" >&2; exit 2 ;;
  esac
  menu_selection=true
}

if [[ -z "${command_name}" ]]; then
  if [[ ! -t 0 ]]; then
    usage
    exit 2
  fi
  show_menu
fi
if [[ "${command_name}" == help ]]; then
  usage
  exit 0
fi

require_root() {
  [[ "${XINGCHEN_MANAGER_ALLOW_NON_ROOT:-false}" == true ]] && return 0
  if ((EUID != 0)); then
    echo "${command_name} 需要 root 权限，请使用 sudo 重新运行。" >&2
    exit 1
  fi
}

confirm_action() {
  local prompt="$1" answer
  [[ "${assume_yes}" == true || "${menu_selection}" == true || ! -t 0 ]] && return 0
  read -r -p "${prompt} [y/N]: " answer
  [[ "${answer}" == y || "${answer}" == Y || "${answer}" == yes || "${answer}" == YES ]]
}

install_bootstrap_dependencies() {
  local missing=()
  command -v git >/dev/null 2>&1 || missing+=(git)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  ((${#missing[@]} > 0)) || return 0
  echo "正在补齐在线安装依赖：${missing[*]}..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl git
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl git
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates curl git
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install ca-certificates curl git
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm ca-certificates curl git
  else
    echo "未找到受支持的包管理器，请先安装 git、curl 和 CA 证书。" >&2
    return 1
  fi
  hash -r
  command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
    || { echo "在线安装依赖补齐失败。" >&2; return 1; }
}

latest_stable_version() {
  local tags latest location
  if [[ "${source_name}" == github ]]; then
    location="$(curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --max-redirs 5 --max-time 30 -o /dev/null -w '%{url_effective}' \
      'https://github.com/Pstarchen/monitor-for-server/releases/latest')" \
      || { echo "无法从 GitHub 获取已公开 Release。" >&2; return 1; }
    case "${location}" in
      https://github.com/Pstarchen/monitor-for-server/releases/tag/v*) latest="${location##*/}" ;;
      *) echo "GitHub 最新 Release 返回了非预期地址。" >&2; return 1 ;;
    esac
    stable_version "${latest}" || { echo "GitHub 没有可用的稳定 Release。" >&2; return 1; }
    printf '%s' "${latest}"
    return 0
  fi
  tags="$(git ls-remote --tags --refs "${repository_url}" 'refs/tags/v*')" \
    || { echo "无法从 ${source_name} 获取版本标签。" >&2; return 1; }
  latest="$(printf '%s\n' "${tags}" \
    | sed -n 's#^[0-9a-fA-F]\{40,64\}[[:space:]]\+refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' \
    | awk '/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/' \
    | sort -V | tail -n 1)"
  stable_version "${latest}" || { echo "${source_name} 没有可用的稳定版本标签。" >&2; return 1; }
  printf '%s' "${latest}"
}

resolve_target_version() {
  if [[ -n "${requested_version}" ]]; then
    printf '%s' "${requested_version}"
  else
    latest_stable_version
  fi
}

remote_tag_commit() {
  local version="$1" refs commit
  refs="$(git ls-remote "${repository_url}" "refs/tags/${version}" "refs/tags/${version}^{}")" \
    || { echo "无法验证 ${source_name} 标签 ${version}。" >&2; return 1; }
  commit="$(printf '%s\n' "${refs}" | awk '$2 ~ /\^\{\}$/ {print $1; exit}')"
  [[ -n "${commit}" ]] || commit="$(printf '%s\n' "${refs}" | awk 'NR == 1 {print $1}')"
  [[ "${commit}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] \
    || { echo "${source_name} 不存在稳定标签 ${version}。" >&2; return 1; }
  printf '%s' "${commit,,}"
}

version_less() {
  local left="${1#v}" right="${2#v}" l1 l2 l3 r1 r2 r3
  IFS=. read -r l1 l2 l3 <<< "${left}"
  IFS=. read -r r1 r2 r3 <<< "${right}"
  ((10#${l1} < 10#${r1} ||
    (10#${l1} == 10#${r1} && 10#${l2} < 10#${r2}) ||
    (10#${l1} == 10#${r1} && 10#${l2} == 10#${r2} && 10#${l3} < 10#${r3})))
}

install_manager_link() {
  local link="${XINGCHEN_MANAGER_LINK:-/usr/local/bin/xingchen}" target="${install_dir}/deploy/xingchen.sh"
  [[ -x "${target}" ]] || chmod 0755 "${target}"
  mkdir -p "$(dirname -- "${link}")"
  if [[ -e "${link}" && ! -L "${link}" ]]; then
    echo "管理命令未创建：${link} 已存在且不是符号链接。" >&2
    return 0
  fi
  if [[ -L "${link}" && "$(readlink -- "${link}")" != "${target}" ]]; then
    echo "管理命令未更新：${link} 已指向其他位置。" >&2
    return 0
  fi
  ln -sfn "${target}" "${link}"
}

configure_release_environment() {
  local version="$1"

  export XINGCHEN_TARGET_VERSION="${version}"
  export XINGCHEN_NETWORK_MODE=public
  export XINGCHEN_SOURCE_REPOSITORIES="${repository_url}"
  export XINGCHEN_SOURCE_REF="${version}"
  export XINGCHEN_RELEASE_MANIFEST_PATH=""
  export XINGCHEN_RELEASE_MANIFEST_URLS=""
  export XINGCHEN_RELEASE_MANIFEST_SHA256=""
  export XINGCHEN_AGENT_RELEASE_BASE_URLS=""
  export XINGCHEN_AGENT_OFFLINE_DIR=""
  if [[ "${source_name}" == gitee ]]; then
    export XINGCHEN_ALLOW_GITEE=true
    export XINGCHEN_CONTROLLER_ALLOW_GITHUB_API=false
    export XINGCHEN_SETUP_IMAGE="${TCR_IMAGE_PREFIX}-setup:${version}"
    export XINGCHEN_SERVER_IMAGE="${TCR_IMAGE_PREFIX}-server:${version}"
    export XINGCHEN_WEB_IMAGE="${TCR_IMAGE_PREFIX}-web:${version}"
    export XINGCHEN_AGENT_IMAGE="${TCR_IMAGE_PREFIX}-agent:${version}"
    export XINGCHEN_POSTGRES_IMAGE="${TCR_IMAGE_PREFIX}-postgres:${version}"
    export XINGCHEN_REDIS_IMAGE="${TCR_IMAGE_PREFIX}-redis:${version}"
  else
    export XINGCHEN_ALLOW_GITEE=false
    export XINGCHEN_CONTROLLER_ALLOW_GITHUB_API=true
    export XINGCHEN_SETUP_IMAGE="ghcr.io/pstarchen/monitor-for-server-setup:${version}"
    export XINGCHEN_SERVER_IMAGE="ghcr.io/pstarchen/monitor-for-server-server:${version}"
    export XINGCHEN_WEB_IMAGE="ghcr.io/pstarchen/monitor-for-server-web:${version}"
    export XINGCHEN_AGENT_IMAGE="ghcr.io/pstarchen/monitor-for-server-agent:${version}"
    export XINGCHEN_POSTGRES_IMAGE="postgres:16-alpine"
    export XINGCHEN_REDIS_IMAGE="redis:7.4-alpine"
  fi
}

persist_manager_settings() {
  local env_file="${install_dir}/.env" settings_file temporary key value
  local keys=(
    XINGCHEN_TARGET_VERSION XINGCHEN_NETWORK_MODE XINGCHEN_ALLOW_GITEE
    XINGCHEN_SOURCE_REPOSITORIES XINGCHEN_SOURCE_REF XINGCHEN_CONTROLLER_ALLOW_GITHUB_API
    XINGCHEN_RELEASE_MANIFEST_PATH XINGCHEN_RELEASE_MANIFEST_URLS XINGCHEN_RELEASE_MANIFEST_SHA256
    XINGCHEN_AGENT_RELEASE_BASE_URLS XINGCHEN_AGENT_OFFLINE_DIR
    XINGCHEN_SETUP_IMAGE XINGCHEN_SERVER_IMAGE XINGCHEN_WEB_IMAGE XINGCHEN_AGENT_IMAGE
    XINGCHEN_POSTGRES_IMAGE XINGCHEN_REDIS_IMAGE
  )
  [[ -f "${env_file}" && ! -L "${env_file}" ]] \
    || { echo "无法安全持久化管理设置：${env_file} 不存在或是符号链接。" >&2; return 1; }
  settings_file="$(mktemp "${install_dir}/.xingchen-settings.XXXXXX")"
  temporary="$(mktemp "${install_dir}/.env.xingchen.XXXXXX")"
  chmod 600 "${settings_file}" "${temporary}"
  for key in "${keys[@]}"; do
    value="${!key}"
    if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* || "${value}" == *$'\t'* ]]; then
      rm -f -- "${settings_file}" "${temporary}"
      echo "${key} 包含不安全的控制字符。" >&2
      return 1
    fi
    printf '%s\t%s\n' "${key}" "${value}" >> "${settings_file}"
  done
  if ! awk -F '\t' '
    NR == FNR { values[$1] = substr($0, index($0, "\t") + 1); order[++count] = $1; next }
    {
      separator = index($0, "=")
      key = separator ? substr($0, 1, separator - 1) : ""
      if (key in values) {
        if (!(key in written)) { print key "=" values[key]; written[key] = 1 }
        next
      }
      print
    }
    END {
      for (position = 1; position <= count; position++) {
        key = order[position]
        if (!(key in written)) print key "=" values[key]
      }
    }
  ' "${settings_file}" "${env_file}" > "${temporary}"; then
    rm -f -- "${settings_file}" "${temporary}"
    return 1
  fi
  rm -f -- "${settings_file}"
  mv -- "${temporary}" "${env_file}"
}

run_install() {
  require_root
  local version expected actual origin parent stage marker marker_version marker_repository install_status
  local resume_install=false installer_args=(--no-source-fallback)
  if [[ -e "${install_dir}" || -L "${install_dir}" ]]; then
    marker="$(install_marker_path)"
    if [[ ! -L "${install_dir}" && -f "${marker}" && ! -L "${marker}" ]] && deployment_exists; then
      resume_install=true
    else
      echo "安装目录已存在，拒绝覆盖：${install_dir}。已有总控请运行 update。" >&2
      exit 1
    fi
  fi
  install_bootstrap_dependencies
  if [[ "${resume_install}" == true ]]; then
    marker_version="$(awk -F= '$1 == "version" { print substr($0, index($0, "=") + 1); exit }' "${marker}")"
    marker_repository="$(awk -F= '$1 == "repository" { print substr($0, index($0, "=") + 1); exit }' "${marker}")"
    stable_version "${marker_version}" \
      || { echo "未完成安装标记中的版本无效，拒绝续装。" >&2; exit 1; }
    [[ "${marker_repository}" == "${repository_url}" ]] \
      || { echo "未完成安装来自其他在线源；请使用对应的 --source 后重试。" >&2; exit 1; }
    if [[ -n "${requested_version}" && "${requested_version}" != "${marker_version}" ]]; then
      echo "未完成安装固定为 ${marker_version}，不能直接改装 ${requested_version}。" >&2
      exit 1
    fi
    version="${marker_version}"
    expected="$(remote_tag_commit "${version}")"
    actual="$(git -C "${install_dir}" rev-parse HEAD)"
    origin="$(git -C "${install_dir}" remote get-url origin)"
    [[ "${actual,,}" == "${expected}" && "${origin}" == "${repository_url}" ]] \
      || { echo "未完成安装的源码状态与已验证标签不一致，拒绝续装。" >&2; exit 1; }
    confirm_action "将继续从 ${source_name} 安装星辰监控 ${version}" || { echo "已取消。"; return 0; }
  else
    version="$(resolve_target_version)"
    expected="$(remote_tag_commit "${version}")"
    confirm_action "将从 ${source_name} 安装星辰监控 ${version}" || { echo "已取消。"; return 0; }

    parent="$(dirname -- "${install_dir}")"
    mkdir -p "${parent}"
    parent="$(cd -- "${parent}" && pwd -P)"
    stage="$(mktemp -d "${parent}/.xingchen-install.XXXXXX")"
    cleanup_stage() {
      if [[ -n "${stage:-}" && -d "${stage}" && ! -L "${stage}" && "$(dirname -- "${stage}")" == "${parent}" && "$(basename -- "${stage}")" == .xingchen-install.* ]]; then
        rm -rf -- "${stage}"
      fi
    }
    trap cleanup_stage EXIT
    git clone --depth 1 --branch "${version}" --single-branch "${repository_url}" "${stage}"
    actual="$(git -C "${stage}" rev-parse HEAD)"
    [[ "${actual,,}" == "${expected}" ]] \
      || { echo "下载的源码提交与远端标签不一致，拒绝安装。" >&2; return 1; }
    mv -- "${stage}" "${install_dir}"
    stage=""
    trap - EXIT
    marker="$(install_marker_path)"
    umask 077
    printf 'version=%s\nrepository=%s\n' "${version}" "${repository_url}" > "${marker}"
  fi

  configure_release_environment "${version}"
  set +e
  bash "${install_dir}/deploy/install-controller.sh" "${installer_args[@]}"
  install_status=$?
  set -e
  if ((install_status != 0)); then
    echo "安装未完成，修复网络或配置后可用同一条 install 命令安全续装。" >&2
    return "${install_status}"
  fi
  rm -f -- "$(install_marker_path)"
  install_manager_link
  echo "在线安装完成。以后可运行 xingchen update、xingchen status 或 xingchen logs。"
}

require_deployment() {
  deployment_exists \
    || { echo "未在 ${install_dir} 找到有效总控部署。" >&2; exit 1; }
}

update_transaction_active=false
update_old_commit=""
update_old_origin=""
update_env_snapshot=""
update_env_existed=false
update_was_interrupted=false

cleanup_update_snapshot() {
  if [[ -n "${update_env_snapshot}" && -f "${update_env_snapshot}" && ! -L "${update_env_snapshot}" ]]; then
    rm -f -- "${update_env_snapshot}"
  fi
  update_env_snapshot=""
}

restore_update_state() {
  local failed=false
  if ! git -C "${install_dir}" checkout --detach "${update_old_commit}" >/dev/null 2>&1; then
    echo "恢复更新前源码提交失败：${update_old_commit}" >&2
    failed=true
  fi
  if ! git -C "${install_dir}" remote set-url origin "${update_old_origin}"; then
    echo "恢复更新前 Git origin 失败。" >&2
    failed=true
  fi
  if [[ "${update_env_existed}" == true ]]; then
    if ! cp -p -- "${update_env_snapshot}" "${install_dir}/.env"; then
      echo "恢复更新前 .env 失败。" >&2
      failed=true
    fi
  elif ! rm -f -- "${install_dir}/.env"; then
    echo "移除更新期间创建的 .env 失败。" >&2
    failed=true
  fi
  cleanup_update_snapshot
  [[ "${failed}" == false ]]
}

handle_update_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "${update_transaction_active}" == true ]]; then
    ((status != 0)) || status=1
    echo "总控更新未完成，正在恢复更新前源码与配置。" >&2
    if restore_update_state; then
      echo "更新前源码与配置已恢复。" >&2
    else
      echo "自动恢复不完整，需要人工检查部署目录。" >&2
      status=12
    fi
    if [[ "${update_was_interrupted}" == true ]]; then
      echo "更新曾被系统信号中断；请运行 xingchen status 确认实际容器状态。" >&2
    fi
  else
    cleanup_update_snapshot
  fi
  exit "${status}"
}

handle_update_signal() {
  update_was_interrupted=true
  exit "$1"
}

run_update() {
  require_root
  require_deployment
  install_bootstrap_dependencies
  if [[ -n "$(git -C "${install_dir}" status --porcelain --untracked-files=no)" ]]; then
    echo "部署目录存在已修改的受版本控制文件，拒绝覆盖；请先处理这些改动。" >&2
    exit 1
  fi

  local version current expected existing update_status installer_args=(--apply --no-source-fallback)
  version="$(resolve_target_version)"
  current="$(current_version || true)"
  if [[ -n "${current}" ]] && version_less "${version}" "${current}"; then
    echo "拒绝从 ${current} 降级到 ${version}。" >&2
    exit 1
  fi
  expected="$(remote_tag_commit "${version}")"
  existing="$(git -C "${install_dir}" rev-parse -q --verify "refs/tags/${version}^{commit}" 2>/dev/null || true)"
  if [[ -n "${existing}" && "${existing,,}" != "${expected}" ]]; then
    echo "本地标签 ${version} 与 ${source_name} 不一致，拒绝更新。" >&2
    exit 1
  fi
  confirm_action "将总控从 ${current:-未知版本} 更新到 ${version}" || { echo "已取消。"; return 0; }

  update_old_commit="$(git -C "${install_dir}" rev-parse HEAD)"
  update_old_origin="$(git -C "${install_dir}" remote get-url origin)"
  update_env_snapshot="$(mktemp "${install_dir}/.env.xingchen-update.XXXXXX")"
  chmod 600 "${update_env_snapshot}"
  if [[ -f "${install_dir}/.env" && ! -L "${install_dir}/.env" ]]; then
    cp -p -- "${install_dir}/.env" "${update_env_snapshot}"
    update_env_existed=true
  elif [[ -e "${install_dir}/.env" || -L "${install_dir}/.env" ]]; then
    cleanup_update_snapshot
    echo "部署 .env 不是安全的普通文件，拒绝更新。" >&2
    exit 1
  else
    : > "${update_env_snapshot}"
    update_env_existed=false
  fi
  update_transaction_active=true
  trap handle_update_exit EXIT
  trap 'handle_update_signal 129' HUP
  trap 'handle_update_signal 130' INT
  trap 'handle_update_signal 143' TERM

  git -C "${install_dir}" remote set-url origin "${repository_url}"
  if [[ -z "${existing}" ]]; then
    git -C "${install_dir}" fetch --depth 1 origin "refs/tags/${version}:refs/tags/${version}"
  fi
  [[ "$(git -C "${install_dir}" rev-parse "refs/tags/${version}^{commit}")" == "${expected}" ]] \
    || { echo "取得的源码标签校验失败。" >&2; exit 1; }
  git -C "${install_dir}" checkout --detach "${version}"

  configure_release_environment "${version}"
  persist_manager_settings

  set +e
  bash "${install_dir}/deploy/update-controller.sh" "${installer_args[@]}"
  update_status=$?
  set -e
  if ((update_status != 0)); then
    return "${update_status}"
  fi
  update_transaction_active=false
  trap - EXIT HUP INT TERM
  cleanup_update_snapshot
  install_manager_link
  echo "总控在线更新完成：${version}。"
}

run_compose() {
  require_deployment
  (cd "${install_dir}" && docker compose --profile host-monitoring "$@")
}

case "${command_name}" in
  install) run_install ;;
  update) run_update ;;
  status) run_compose ps ;;
  logs) run_compose logs --tail 200 ;;
  restart)
    require_root
    confirm_action "将重新创建总控服务" || { echo "已取消。"; exit 0; }
    run_compose up -d --force-recreate --wait --wait-timeout 300 --remove-orphans
    ;;
esac
