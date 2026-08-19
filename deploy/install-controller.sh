#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: install-controller.sh

Builds and starts the controller services. Database and site configuration are
completed in the browser setup guide at /setup.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ $# -gt 0 ]]; then
  echo "This installer does not accept configuration flags. Use the browser setup guide." >&2
  usage >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "${script_dir}/.." && pwd)"

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Docker Engine and Docker Compose v2 are required." >&2
  exit 1
fi

cd "${project_root}"
docker compose config --quiet
docker compose up --build -d

cat <<'MESSAGE'
总终端服务器已启动。请打开 http://<服务器IP>:18080/setup 完成首次安装。

安装向导会要求你明确填写 MySQL 地址、端口、已创建的数据库名、用户名和密码；
本脚本不会安装 MySQL、创建数据库、创建用户、授权账号或猜测 Docker 网桥地址。
MESSAGE
