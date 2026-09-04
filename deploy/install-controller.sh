#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: install-controller.sh [--cleanup] [--build|--source-build] [--offline] [--auto-update] [--no-mirror] [--no-source-fallback]
                             [--no-install-dependencies]
                             [--network-mode public|internal|offline] [--allow-gitee]

Pulls prebuilt controller images and starts the controller with an internal
PostgreSQL database. Site and administrator configuration are completed in the
browser guide at /setup.

  --cleanup  stop this Compose project and remove its old images before build.
             PostgreSQL/Redis volumes are preserved.
  --build    build controller images locally instead of pulling them from GHCR.
  --source-build  build Docker images from Gitee/GitHub source repositories.
  --offline  use only images already loaded into the local Docker engine.
  --auto-update  enable the controller's daily 04:00 automatic update.
  --no-mirror  skip mainland-China mirror registries and use official GHCR.
  --no-source-fallback  do not build from source when all image registries fail.
  --no-install-dependencies  fail instead of installing Docker, Compose, or curl.
  --network-mode  select public, internal, or fully offline source policy.
  --allow-gitee  explicitly permit Gitee when network mode is internal.
USAGE
}

cleanup=false
build=false
source_build=false
auto_update=false
no_mirror=false
source_fallback=true
offline=false
no_install_dependencies=false
network_mode_argument=""
allow_gitee_argument=""
network_mode_environment="${XINGCHEN_NETWORK_MODE:-}"
allow_gitee_environment="${XINGCHEN_ALLOW_GITEE:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup) cleanup=true; shift ;;
    --build) build=true; shift ;;
    --source-build) source_build=true; shift ;;
    --offline) offline=true; shift ;;
    --auto-update) auto_update=true; shift ;;
    --no-mirror) no_mirror=true; shift ;;
    --no-source-fallback) source_fallback=false; shift ;;
    --no-install-dependencies) no_install_dependencies=true; shift ;;
    --network-mode)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--network-mode 需要模式值。" >&2; exit 2; }
      network_mode_argument="$2"
      shift 2
      ;;
    --allow-gitee) allow_gitee_argument=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "${script_dir}/.." && pwd)"
cd "${project_root}"

read_env_value() {
  local key="$1" value
  value="$(awk -v key="${key}" 'index($0, key "=") == 1 {print substr($0, length(key) + 2); exit}' .env 2>/dev/null || true)"
  if [[ "${value}" == \"*\" || "${value}" == \'*\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "${value}"
}

policy_env_value=""
policy_env_value_set=false
read_policy_env_value() {
  local key="$1" line candidate raw first last suffix env_fd match_count=0
  policy_env_value=""
  policy_env_value_set=false
  if [[ ! -e .env && ! -L .env ]]; then
    return 0
  fi
  if [[ ! -f .env || ! -r .env ]]; then
    echo "现有 .env 不可读或不是普通文件，拒绝推断网络策略。" >&2
    return 1
  fi
  if ! exec {env_fd}< .env; then
    echo "现有 .env 读取失败，拒绝推断网络策略。" >&2
    return 1
  fi
  while IFS= read -r -u "${env_fd}" line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    candidate="${line}"
    while [[ "${candidate}" == ' '* || "${candidate}" == $'\t'* ]]; do
      candidate="${candidate:1}"
    done
    [[ -z "${candidate}" || "${candidate}" == \#* ]] && continue
    if [[ "${candidate}" == "${key}="* ]]; then
      ((match_count += 1))
      if ((match_count > 1)); then
        echo "现有 .env 中的 ${key} 重复，拒绝继续。" >&2
        exec {env_fd}<&-
        return 1
      fi
      raw="${candidate#"${key}="}"
      first="${raw:0:1}"
      last="${raw: -1}"
      if [[ "${first}" == '"' || "${first}" == "'" || "${last}" == '"' || "${last}" == "'" ]]; then
        if [[ ${#raw} -lt 2 || "${first}" != "${last}" || ( "${first}" != '"' && "${first}" != "'" ) ]]; then
          echo "现有 .env 中的 ${key} 无法解析，拒绝继续。" >&2
          exec {env_fd}<&-
          return 1
        fi
        raw="${raw:1:${#raw}-2}"
      fi
      if [[ "${raw}" == *'"'* || "${raw}" == *"'"* ]]; then
        echo "现有 .env 中的 ${key} 无法解析，拒绝继续。" >&2
        exec {env_fd}<&-
        return 1
      fi
      policy_env_value="${raw}"
      policy_env_value_set=true
    elif [[ "${candidate}" == "${key}"* ]]; then
      suffix="${candidate#"${key}"}"
      first="${suffix:0:1}"
      if [[ -z "${suffix}" || ! "${first}" =~ [A-Za-z0-9_] ]]; then
        echo "现有 .env 中的 ${key} 无法解析，拒绝继续。" >&2
        exec {env_fd}<&-
        return 1
      fi
    elif [[ "${candidate}" == export[[:space:]]"${key}"* ]]; then
      echo "现有 .env 中的 ${key} 无法解析，拒绝继续。" >&2
      exec {env_fd}<&-
      return 1
    fi
  done
  exec {env_fd}<&-
}

if [[ -n "${network_mode_argument}" ]]; then
  network_mode="${network_mode_argument}"
elif [[ -n "${network_mode_environment}" ]]; then
  network_mode="${network_mode_environment}"
else
  read_policy_env_value XINGCHEN_NETWORK_MODE || exit 2
  if [[ "${policy_env_value_set}" == true ]]; then
    network_mode="${policy_env_value}"
  else
    network_mode=public
  fi
fi
if [[ -n "${allow_gitee_argument}" ]]; then
  allow_gitee="${allow_gitee_argument}"
elif [[ -n "${allow_gitee_environment}" ]]; then
  allow_gitee="${allow_gitee_environment}"
else
  read_policy_env_value XINGCHEN_ALLOW_GITEE || exit 2
  if [[ "${policy_env_value_set}" == true ]]; then
    allow_gitee="${policy_env_value}"
  else
    allow_gitee=false
  fi
fi
network_mode="${network_mode,,}"
if [[ ! "${network_mode}" =~ ^(public|internal|offline)$ ]]; then
  echo "--network-mode 必须是 public、internal 或 offline。" >&2
  exit 2
fi
allow_gitee="${allow_gitee,,}"
if [[ "${allow_gitee}" != true && "${allow_gitee}" != false ]]; then
  echo "XINGCHEN_ALLOW_GITEE 必须是 true 或 false。" >&2
  exit 2
fi
if [[ "${offline}" == true ]]; then
  network_mode=offline
elif [[ "${network_mode}" == offline ]]; then
  offline=true
fi
export XINGCHEN_NETWORK_MODE="${network_mode}"
export XINGCHEN_ALLOW_GITEE="${allow_gitee}"

if [[ "${offline}" == true && ( "${build}" == true || "${source_build}" == true || "${auto_update}" == true ) ]]; then
  echo "--offline 不能与 --build、--source-build 或 --auto-update 同时使用。" >&2
  exit 2
fi
if [[ "${network_mode}" == internal ]]; then
  if [[ "${build}" == true || "${source_build}" == true ]]; then
    echo "internal 网络模式禁止 --build 和 --source-build；请使用已导入镜像或内部 Registry。" >&2
    exit 2
  fi
  source_fallback=false
fi

missing_runtime_dependencies() {
  local missing=()
  if ! command -v docker >/dev/null 2>&1; then
    missing+=(Docker)
  elif ! docker compose version >/dev/null 2>&1; then
    missing+=("Docker Compose v2")
  fi
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  local IFS=', '
  printf '%s' "${missing[*]}"
}

run_as_root() {
  if ((EUID == 0)); then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "自动安装依赖需要 root 权限或 sudo。" >&2
    return 1
  fi
}

install_runtime_dependencies() {
  echo "正在安装 Docker Engine、Docker Compose v2 和 curl..."
  if command -v apt-get >/dev/null 2>&1; then
    run_as_root apt-get update
    run_as_root apt-get install -y curl docker.io docker-compose-v2 \
      || run_as_root apt-get install -y curl docker.io docker-compose-plugin
  elif command -v dnf >/dev/null 2>&1; then
    run_as_root dnf install -y curl docker docker-compose-plugin
  elif command -v yum >/dev/null 2>&1; then
    run_as_root yum install -y curl docker docker-compose-plugin
  elif command -v apk >/dev/null 2>&1; then
    run_as_root apk add --no-cache curl docker docker-cli-compose
  elif command -v zypper >/dev/null 2>&1; then
    run_as_root zypper --non-interactive install curl docker docker-compose
  elif command -v pacman >/dev/null 2>&1; then
    run_as_root pacman -Sy --noconfirm curl docker docker-compose
  else
    echo "未找到受支持的包管理器，请手动安装 Docker Engine、Docker Compose v2 和 curl。" >&2
    return 1
  fi
}

missing_dependencies="$(missing_runtime_dependencies)"
if [[ -n "${missing_dependencies}" ]]; then
  if [[ "${network_mode}" != public ]]; then
    echo "缺少运行依赖：${missing_dependencies}。${network_mode} 模式禁止联网安装软件包，请预先安装后重试。" >&2
    exit 1
  fi
  if [[ "${no_install_dependencies}" == true ]]; then
    echo "缺少运行依赖：${missing_dependencies}。已通过 --no-install-dependencies 禁用自动安装。" >&2
    exit 1
  fi
  install_runtime_dependencies
  hash -r
  missing_dependencies="$(missing_runtime_dependencies)"
  if [[ -n "${missing_dependencies}" ]]; then
    echo "依赖安装完成后仍缺少：${missing_dependencies}。请检查安装结果后重试。" >&2
    exit 1
  fi
fi

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

generate_device_id() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '\n' < /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    local raw
    raw="$(generate_password)"
    printf '%s-%s-4%s-8%s-%s\n' "${raw:0:8}" "${raw:8:4}" "${raw:13:3}" "${raw:17:3}" "${raw:20:12}"
  fi
}

write_env_value() {
  local key="$1"
  local value="$2"
  local temporary
  temporary="$(mktemp .env.controller-XXXXXX)"
  awk -v key="${key}" -v value="${value}" '
    index($0, key "=") == 1 {
      if (!seen++) print key "=" value
      next
    }
    { print }
    END { if (!seen) print key "=" value }
  ' .env > "${temporary}"
  chmod 600 "${temporary}"
  mv "${temporary}" .env
}

ensure_controller_agent_env() {
  [[ "$(uname -s)" == "Linux" ]] || return

  local device_id agent_key
  device_id="$(read_env_value CONTROLLER_AGENT_DEVICE_ID)"
  agent_key="$(read_env_value CONTROLLER_AGENT_KEY)"
  [[ -n "${device_id}" ]] || device_id="$(generate_device_id)"
  [[ -n "${agent_key}" ]] || agent_key="$(generate_password)"

  write_env_value CONTROLLER_AGENT_ENABLED true
  write_env_value CONTROLLER_AGENT_DEVICE_ID "${device_id}"
  write_env_value CONTROLLER_AGENT_KEY "${agent_key}"
  write_env_value CONTROLLER_AGENT_NAME "总控服务器"
  write_env_value CONTROLLER_AGENT_GROUP "控制平面"
}

write_bootstrap_env() {
  local password temporary
  password="$(generate_password)"
  temporary="$(mktemp .env.controller-bootstrap.XXXXXX)"
  umask 077
  printf '%s\n' \
    '# Generated by the controller installer. Keep this file private.' \
    'SPRING_PROFILES_ACTIVE=bootstrap' \
    'POSTGRES_DB=xingchen_monitor' \
    'POSTGRES_USER=xingchen' \
    "POSTGRES_PASSWORD=${password}" > "${temporary}"
  chmod 600 "${temporary}"
  mv "${temporary}" .env
}

ensure_postgres_password() {
  local count
  if [[ ! -f .env ]]; then
    write_bootstrap_env
    return
  fi
  count="$(grep -c '^POSTGRES_PASSWORD=' .env || true)"
  if [[ "${count}" -eq 0 ]]; then
    write_env_value POSTGRES_PASSWORD "$(generate_password)"
  elif [[ "${count}" -ne 1 ]] || ! grep -Eq "^POSTGRES_PASSWORD=(\"[^\"]+\"|'[^']+'|[^[:space:]\"']+)$" .env; then
    echo "现有 .env 中的 POSTGRES_PASSWORD 非法或重复，请修正后重试；安装器未修改该文件。" >&2
    exit 1
  fi
}

ensure_compose_project_name() {
  local configured database
  configured="$(read_env_value COMPOSE_PROJECT_NAME)"
  [[ -n "${configured}" ]] && return
  database="$(read_env_value POSTGRES_DB)"
  if [[ "${database}" == "guanlan_monitor" ]] || docker volume inspect guanlan-monitor_postgres-data >/dev/null 2>&1; then
    # Keep the old Compose project for existing installations so their named
    # volumes remain attached while the repository defaults move to Xingchen.
    write_env_value COMPOSE_PROJECT_NAME "guanlan-monitor"
  else
    write_env_value COMPOSE_PROJECT_NAME "xingchen-monitor"
  fi
}

ensure_postgres_password
ensure_compose_project_name

persist_installer_settings() {
  local key value
  local keys=(
    XINGCHEN_POSTGRES_IMAGE XINGCHEN_REDIS_IMAGE
    XINGCHEN_SETUP_IMAGE XINGCHEN_SERVER_IMAGE XINGCHEN_WEB_IMAGE XINGCHEN_AGENT_IMAGE
    XINGCHEN_TARGET_VERSION XINGCHEN_RELEASE_MANIFEST_PATH XINGCHEN_RELEASE_MANIFEST_URLS XINGCHEN_RELEASE_MANIFEST_SHA256
    XINGCHEN_AGENT_RELEASE_BASE_URLS XINGCHEN_AGENT_CACHE_DIR XINGCHEN_AGENT_OFFLINE_DIR
    XINGCHEN_CONTROLLER_ALLOW_GITHUB_API XINGCHEN_CONTROLLER_IMAGE_MIRRORS XINGCHEN_AGENT_IMAGE_MIRRORS
    XINGCHEN_NETWORK_MODE XINGCHEN_ALLOW_GITEE
    XINGCHEN_SOURCE_REPOSITORIES XINGCHEN_SOURCE_REF XINGCHEN_SOURCE_BUILD_TIMEOUT_SECONDS
    XINGCHEN_UPDATE_MIRROR_TIMEOUT_SECONDS XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS XINGCHEN_UPDATE_COMPOSE_TIMEOUT_SECONDS XINGCHEN_UPDATE_MIN_FREE_BYTES
  )
  for key in "${keys[@]}"; do
    value="${!key:-}"
    [[ -n "${value}" ]] || continue
    if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
      echo "${key} 不能包含换行符。" >&2
      exit 2
    fi
    write_env_value "${key}" "${value}"
  done
}

persist_installer_settings
if [[ "${offline}" == true ]]; then
  manifest_path="${XINGCHEN_RELEASE_MANIFEST_PATH:-$(read_env_value XINGCHEN_RELEASE_MANIFEST_PATH)}"
  offline_dir="${XINGCHEN_AGENT_OFFLINE_DIR:-$(read_env_value XINGCHEN_AGENT_OFFLINE_DIR)}"
  manifest_host_path="${manifest_path}"
  offline_host_dir="${offline_dir}"
  [[ "${manifest_host_path}" == /workspace/* ]] && manifest_host_path="${project_root}/${manifest_host_path#/workspace/}"
  [[ "${offline_host_dir}" == /workspace/* ]] && offline_host_dir="${project_root}/${offline_host_dir#/workspace/}"
  [[ -f "${manifest_host_path}" ]] || { echo "离线 Release manifest 不存在：${manifest_path:-未配置}" >&2; exit 1; }
  [[ -d "${offline_host_dir}" ]] || { echo "离线 Agent 制品目录不存在：${offline_dir:-未配置}" >&2; exit 1; }
fi

profile_args=()
if [[ "$(uname -s)" == "Linux" ]]; then
  ensure_controller_agent_env
  profile_args=(--profile host-monitoring)
else
  echo "当前系统不是 Linux，已跳过总控宿主机自动监控。"
fi

if [[ "${cleanup}" == true ]]; then
  echo "清理星辰监控旧容器和本地镜像（保留 PostgreSQL/Redis 卷）..."
  docker compose "${profile_args[@]}" down --remove-orphans --rmi local
  project_images="$(docker image ls --format '{{.Repository}} {{.ID}}' | awk '$1 ~ /^(xingchen|guanlan)-monitor(-|$)/ {print $2}' | sort -u)"
  if [[ -n "${project_images}" ]]; then
    while IFS= read -r image_id; do
      [[ -n "${image_id}" ]] && docker image rm -f "${image_id}" >/dev/null || true
    done <<< "${project_images}"
  fi
  # Dangling layers have no ownership metadata; leave them for an administrator
  # to prune globally after checking other Docker projects on the host.
fi

docker compose "${profile_args[@]}" config --quiet
controller_services=(setup server web)
if [[ "$(uname -s)" == "Linux" ]]; then
  controller_services+=(controller-agent)
fi
if [[ "${build}" == true && "${source_build}" == true ]]; then
  echo "--build 与 --source-build 不能同时使用。" >&2
  exit 2
elif [[ "${build}" == true ]]; then
  echo "使用本地源码构建总控镜像..."
  docker compose "${profile_args[@]}" build --pull "${controller_services[@]}"
else
  echo "正在拉取总控预构建镜像（优先使用国内镜像源）..."
  update_args=(--check)
  if [[ "${offline}" == true ]]; then
    update_args+=(--offline)
  fi
  if [[ "${source_build}" == true ]]; then
    update_args+=(--source-build)
  fi
  if [[ "${no_mirror}" == true ]]; then
    update_args+=(--no-mirror)
  fi
  if [[ "${source_fallback}" != true ]]; then
    update_args+=(--no-source-fallback)
  fi
  bash "${script_dir}/update-controller.sh" "${update_args[@]}"
fi
compose_up_args=(-d --remove-orphans)
if [[ "${offline}" == true ]]; then
  compose_up_args+=(--pull never)
fi
docker compose "${profile_args[@]}" up "${compose_up_args[@]}"

web_port="18080"
if [[ -f .env ]]; then
  configured_port="$(grep '^WEB_PORT=' .env | head -n 1 | cut -d= -f2 || true)"
  configured_port="${configured_port#\"}"
  configured_port="${configured_port%\"}"
  [[ -n "${configured_port}" ]] && web_port="${configured_port}"
fi
for attempt in {1..40}; do
  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 3 "http://127.0.0.1:${web_port}/healthz" >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" -eq 40 ]]; then
    echo "Web 服务未在 120 秒内通过健康检查，请运行 docker compose ps 和 docker compose logs。" >&2
    exit 1
  fi
  sleep 3
done

cat <<'MESSAGE'
总终端服务器已启动。首次安装请打开 http://<服务器IP>:<WEB_PORT>/setup。

安装完成后，直接访问配置的域名根路径即可进入公开状态页，无需追加 /status。

PostgreSQL 已内置，数据库凭据由安装器自动生成，无需填写或执行数据库命令。
向导只需设置站点入口、来源、时区和首个管理员。
端口与绑定地址已在总终端启动前确定，宝塔反代请先在 `.env` 中设为 `WEB_BIND_ADDRESS=127.0.0.1`。
Linux 总终端会自动作为“总控服务器”显示在设备管理中，无需另装 Agent。
MESSAGE
printf '当前 Web 端口：%s\n' "${web_port}"
if [[ "${auto_update}" == true ]]; then
  bash "${script_dir}/update-controller.sh" --auto
fi
