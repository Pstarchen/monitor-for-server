# 总终端服务器搭建材料

总终端服务器是运行 Web 控制台、Spring Boot API、MySQL 和 Redis 的那台机器。被监控服务器只需要运行 Agent，不需要安装 Java、MySQL 或 Node.js。

## 必备材料

- Docker Engine 24+ 和 Docker Compose v2。
- 一个生产域名及 TLS 证书。公网只暴露 Web 入口，MySQL、Redis 和 Spring Boot 端口保持内网。
- 独立保存的 `.env`，尤其是 `MYSQL_ROOT_PASSWORD`、`MYSQL_PASSWORD`、`BOOTSTRAP_ADMIN_PASSWORD` 和 `SETTINGS_ENCRYPTION_KEY`。

## 首次部署

```powershell
Set-Location <项目目录>
powershell -ExecutionPolicy Bypass -File .\deploy\install-controller.ps1
```

Linux 总终端运行：

```bash
cd /path/to/monitor-for-server
bash ./deploy/install-controller.sh
```

安装器会逐项询问公网入口、Web 来源、站点名称、管理员、时区和端口，自动生成数据库密码与设置加密密钥，先执行 `docker compose config --quiet`，通过后才构建启动。它不会读取或覆盖隐式默认配置；已有 `.env` 时会停止，只有显式传入 `--overwrite` / `-Overwrite` 才会备份后重建。

生产环境生成的 `.env` 至少包含：

```dotenv
SESSION_COOKIE_SECURE=true
ALLOWED_ORIGINS=https://monitor.example.com
PUBLIC_BASE_URL=https://monitor.example.com
```

未完成安装时，Compose 会因为关键变量缺失而直接失败，不会静默使用 `localhost` 或不安全 Cookie 默认值。安装器完成后检查：

```powershell
docker compose ps
docker compose logs --tail 100 server
```

首次启动从 `BOOTSTRAP_ADMIN_USERNAME` 和 `BOOTSTRAP_ADMIN_PASSWORD` 创建管理员；已有管理员时不会覆盖密码。登录后在“设备管理”创建节点，保存一次性 Agent 密钥。

## 网关要求

TLS 在 Caddy、Nginx、Traefik 或云负载均衡器终止，并转发到 Web 容器的 `WEB_PORT`。必须透传 `Host`、`X-Forwarded-For`、`X-Forwarded-Proto`，并为 `/ws/` 转发 Upgrade/Connection 头。鸿蒙端和浏览器都应使用同一个 HTTPS 域名。

## 更新与修改信息

1. 先备份 MySQL，并保留当前 `.env` 和设置加密密钥。
2. 拉取新版本后执行 `docker compose build --pull server web`。
3. 执行 `docker compose up -d`，Flyway 会自动运行数据库迁移。
4. 在“系统设置”修改站点名、入口 URL、采集周期、离线阈值和通知配置；敏感值会加密存储。

```powershell
docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysqldump -umonitor monitor' > monitor-backup.sql
docker compose up -d
```

## 鸿蒙 App 搭配边界

仓库不包含原生鸿蒙 App。鸿蒙端可以复用以下稳定契约：

- `POST /api/auth/login`、`GET /api/auth/me`：会话登录，建议使用 ArkUI 的安全 Cookie/网络层保存会话。
- `GET /api/dashboard`、`/api/devices`、`/api/devices/{id}/metrics/history`：页面数据和趋势。
- `GET /api/auth/csrf` 后，所有会话写请求携带 `X-XSRF-TOKEN`。
- 已登录 WebSocket `/ws/metrics`：接收刷新提示，REST 数据库仍是权威来源。

鸿蒙端不能使用 Agent 密钥，也不应把管理员凭据写入本地明文存储。生产域名必须允许鸿蒙网络栈的 HTTPS 与 WebSocket（`wss`）连接，并在 `ALLOWED_ORIGINS` 中配置实际 Web 控制台来源。
