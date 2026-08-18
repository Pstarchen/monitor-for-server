#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [--overwrite] [--allow-local-http] [--allow-insecure-http]"
}

overwrite=false
allow_local_http=false
allow_insecure_http=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --overwrite) overwrite=true; shift ;;
    --allow-local-http) allow_local_http=true; shift ;;
    --allow-insecure-http) allow_insecure_http=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "${script_dir}/.." && pwd)"
env_file="${project_root}/.env"

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Docker Engine and Docker Compose v2 are required." >&2
  exit 1
fi
if [[ -f "${env_file}" && "${overwrite}" != true ]]; then
  echo ".env already exists. Edit it manually or rerun with --overwrite." >&2
  exit 1
fi

mysql_client=""
if command -v mysql >/dev/null 2>&1; then
  mysql_client="$(command -v mysql)"
elif command -v mariadb >/dev/null 2>&1; then
  mysql_client="$(command -v mariadb)"
else
  echo "MySQL client (mysql or mariadb) is required to create the application database." >&2
  exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "OpenSSL is required to generate deployment secrets." >&2
  exit 1
fi

ask() {
  local label="$1" value=""
  while [[ -z "${value}" ]]; do
    read -r -p "${label}: " value
  done
  printf '%s' "${value}"
}

ask_default() {
  local label="$1" default="$2" value=""
  read -r -p "${label} [${default}]: " value
  printf '%s' "${value:-${default}}"
}

ask_secret() {
  local label="$1" minimum="$2" value=""
  while (( ${#value} < minimum )); do
    read -r -s -p "${label}: " value
    echo >&2
    if (( ${#value} < minimum )); then
      echo "输入不能为空且至少需要 ${minimum} 个字符。" >&2
    fi
  done
  if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
    echo "密码不能包含换行。" >&2
    exit 2
  fi
  printf '%s' "${value}"
}

validate_port() {
  local label="$1" value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    echo "${label}无效。" >&2
    exit 2
  fi
}

validate_identifier() {
  local label="$1" value="$2"
  if [[ ! "${value}" =~ ^[A-Za-z][A-Za-z0-9_]{0,63}$ ]]; then
    echo "${label}只能以字母开头，并且只能包含字母、数字和下划线（最多 64 位）。" >&2
    exit 2
  fi
}

validate_host() {
  local label="$1" value="$2"
  if [[ -z "${value}" || "${value}" =~ [[:space:]/?#] ]]; then
    echo "${label}格式无效。" >&2
    exit 2
  fi
}

# Quote a value as a MySQL string literal. Identifiers are validated separately.
sql_literal() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\'\'}"
  printf "'%s'" "${value}"
}

mysql_args=(--protocol=tcp --host="${mysql_admin_host:-}" --port="${mysql_admin_port:-}" --user="${mysql_admin_user:-}" --batch --skip-column-names)
mysql_query() {
  MYSQL_PWD="${mysql_admin_password}" "${mysql_client}" "${mysql_args[@]}" --raw -e "$1"
}

mysql_exec() {
  MYSQL_PWD="${mysql_admin_password}" "${mysql_client}" "${mysql_args[@]}" --batch --skip-column-names
}

trap 'unset mysql_admin_password app_password admin_password admin_password_confirm app_password_confirm settings_key; if [[ -n "${tmp_file:-}" ]]; then rm -f -- "${tmp_file}"; fi' EXIT

echo '先配置外部 MySQL。安装器会创建新的数据库和最小权限应用账号，不会覆盖已有同名对象。'
mysql_admin_host="$(ask 'MySQL 管理地址（安装器所在主机可访问，例如 127.0.0.1）')"
validate_host 'MySQL 管理地址' "${mysql_admin_host}"
mysql_admin_port="$(ask 'MySQL 管理端口（1-65535）')"
validate_port 'MySQL 管理端口' "${mysql_admin_port}"
mysql_admin_user="$(ask 'MySQL 管理用户名（需要建库、建用户和授权权限）')"
mysql_admin_password="$(ask_secret 'MySQL 管理密码' 1)"
mysql_args=(--protocol=tcp --host="${mysql_admin_host}" --port="${mysql_admin_port}" --user="${mysql_admin_user}" --batch --skip-column-names)
if ! mysql_probe="$(mysql_query 'SELECT 1;')" || [[ "${mysql_probe}" != 1 ]]; then
  echo "无法使用提供的 MySQL 管理账号连接，请检查地址、端口、账号、密码和防火墙。" >&2
  exit 2
fi

mysql_app_host="$(ask_default '容器连接 MySQL 地址（同机 Docker 使用 host.docker.internal）' 'host.docker.internal')"
validate_host '容器连接 MySQL 地址' "${mysql_app_host}"
mysql_app_port="$(ask_default '容器连接 MySQL 端口' "${mysql_admin_port}")"
validate_port '容器连接 MySQL 端口' "${mysql_app_port}"
database_name="$(ask '目标数据库名（新建，字母开头，仅字母/数字/下划线）')"
validate_identifier '目标数据库名' "${database_name}"
app_username="$(ask '应用数据库用户名（新建，字母开头，仅字母/数字/下划线）')"
validate_identifier '应用数据库用户名' "${app_username}"
app_password="$(ask_secret '应用数据库密码（至少 12 位）' 12)"
app_password_confirm="$(ask_secret '再次输入应用数据库密码' 12)"
if [[ "${app_password}" != "${app_password_confirm}" ]]; then
  echo "两次应用数据库密码不一致。" >&2
  exit 2
fi

public_base_url="$(ask '公网入口 URL（HTTPS；临时 IP/HTTP 请使用 --allow-insecure-http）')"
if [[ ! "${public_base_url}" =~ ^https://[^/?#[:space:]]+(/[^?#[:space:]]*)?$ ]]; then
  if [[ "${allow_insecure_http}" == true && "${public_base_url}" =~ ^http://[^/?#[:space:]]+(:[0-9]+)?(/[^?#[:space:]]*)?$ ]]; then
    echo "警告：当前使用明文 HTTP，仅限初始化。绑定 HTTPS 域名后必须更新 .env 并重建 server。" >&2
  elif [[ "${allow_local_http}" == true && "${public_base_url}" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?(/[^?#[:space:]]*)?$ ]]; then
    :
  else
    echo "公网入口必须是 HTTPS；临时 IP/HTTP 初始化请使用 --allow-insecure-http。" >&2
    exit 2
  fi
fi
allowed_origins="$(ask 'Web 来源（通常与公网入口相同）')"
site_name="$(ask '站点名称')"
admin_username="$(ask '初始管理员用户名')"
timezone="$(ask '服务时区（例如 Asia/Shanghai）')"
web_port="$(ask 'Web 端口（1-65535）')"
validate_port 'Web 端口' "${web_port}"
web_bind_address="$(ask 'Web 绑定地址（0.0.0.0 允许 IP 直连；127.0.0.1 仅供宝塔反代）')"
if [[ ! "${web_bind_address}" =~ ^(0\.0\.0\.0|127\.0\.0\.1|localhost|::1)$ ]]; then
  echo "Web 绑定地址只支持 0.0.0.0、127.0.0.1、localhost 或 ::1。" >&2
  exit 2
fi
admin_password="$(ask_secret '初始管理员密码（至少 12 位）' 12)"
admin_password_confirm="$(ask_secret '再次输入初始管理员密码' 12)"
if [[ "${admin_password}" != "${admin_password_confirm}" ]]; then
  echo "两次管理员密码不一致。" >&2
  exit 2
fi

database_sql="$(sql_literal "${database_name}")"
app_user_sql="$(sql_literal "${app_username}")"
if ! database_exists="$(mysql_query "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = ${database_sql};")"; then
  echo "无法检查数据库是否存在，请确认管理账号具有读取元数据权限。" >&2
  exit 2
fi
if [[ "${database_exists}" != 0 ]]; then
  echo "数据库 ${database_name} 已存在。为避免覆盖数据，安装器已停止；请换一个数据库名或手动完成后续配置。" >&2
  exit 2
fi
if ! user_exists="$(mysql_query "SELECT COUNT(*) FROM mysql.user WHERE User = ${app_user_sql};")"; then
  echo "无法检查应用用户是否存在，请确认管理账号具有读取 mysql.user 的权限。" >&2
  exit 2
fi
if [[ "${user_exists}" != 0 ]]; then
  echo "应用用户 ${app_username} 已存在。为避免修改现有账号，安装器已停止。" >&2
  exit 2
fi

app_password_sql="$(sql_literal "${app_password}")"
echo "正在创建数据库 ${database_name}、应用用户 ${app_username} 并授予目标库权限..."
if ! mysql_exec <<SQL
CREATE DATABASE ${database_sql} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER ${app_user_sql}@'%' IDENTIFIED BY ${app_password_sql};
GRANT ALL PRIVILEGES ON ${database_sql}.* TO ${app_user_sql}@'%';
FLUSH PRIVILEGES;
SQL
then
  echo "MySQL 初始化失败。未写入 .env；请检查管理账号权限和 MySQL 错误后再试。" >&2
  exit 2
fi
unset mysql_admin_password app_password_confirm

# Compose accepts double-quoted dotenv values; escape interpolation and quotes.
dotenv_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\$\$}"
  printf '"%s"' "${value}"
}

settings_key="$(openssl rand -base64 32 | tr -d '\n')"
tmp_file="$(mktemp)"
umask 077
{
  printf '%s\n' '# Generated by deploy/install-controller.sh. Keep this file private.'
  printf 'SPRING_PROFILES_ACTIVE=production\n'
  printf 'DB_URL=%s\n' "$(dotenv_value "jdbc:mysql://${mysql_app_host}:${mysql_app_port}/${database_name}?useUnicode=true&characterEncoding=utf8&serverTimezone=UTC")"
  printf 'DB_USERNAME=%s\n' "$(dotenv_value "${app_username}")"
  printf 'DB_PASSWORD=%s\n' "$(dotenv_value "${app_password}")"
  printf 'BOOTSTRAP_ADMIN_USERNAME=%s\n' "$(dotenv_value "${admin_username}")"
  printf 'BOOTSTRAP_ADMIN_PASSWORD=%s\n' "$(dotenv_value "${admin_password}")"
  printf 'SETTINGS_ENCRYPTION_KEY=%s\n' "$(dotenv_value "${settings_key}")"
  printf 'WEB_PORT=%s\n' "$(dotenv_value "${web_port}")"
  printf 'WEB_BIND_ADDRESS=%s\n' "$(dotenv_value "${web_bind_address}")"
  printf 'APP_TIMEZONE=%s\n' "$(dotenv_value "${timezone}")"
  printf 'SITE_NAME=%s\n' "$(dotenv_value "${site_name}")"
  printf 'PUBLIC_BASE_URL=%s\n' "$(dotenv_value "${public_base_url}")"
  printf 'SESSION_COOKIE_SECURE=%s\n' "$(dotenv_value "$([[ "${public_base_url}" == https://* ]] && echo true || echo false)")"
  printf 'ALLOW_INSECURE_HTTP=%s\n' "$(dotenv_value "$([[ "${public_base_url}" == http://* ]] && echo true || echo false)")"
  printf 'ALLOWED_ORIGINS=%s\n' "$(dotenv_value "${allowed_origins}")"
  printf 'METRIC_RETENTION_DAYS=30\nDEVICE_OFFLINE_AFTER_SECONDS=30\n'
} > "${tmp_file}"

if [[ -f "${env_file}" && "${overwrite}" == true ]]; then
  cp -- "${env_file}" "${env_file}.backup.$(date +%Y%m%d%H%M%S)"
fi
install -m 0600 "${tmp_file}" "${env_file}"
docker compose --env-file "${env_file}" config --quiet
docker compose --env-file "${env_file}" up --build -d
unset admin_password admin_password_confirm settings_key
echo "总终端服务器已启动。请打开 ${public_base_url} 并使用刚设置的管理员账号登录；后续站点、通知和设备配置由你在控制台完成。"
