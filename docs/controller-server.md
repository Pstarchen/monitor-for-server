# 总终端服务器搭建材料

总终端服务器是运行 Web 控制台、Spring Boot API 和 Redis 的那台机器，并连接用户自行准备的外部 MySQL。被监控服务器只需要运行 Agent，不需要安装 Java、MySQL 或 Node.js。

## 必备材料

- Docker Engine 24+ 和 Docker Compose v2。
- 外部 MySQL 8.0+ 实例，并准备一个有建库、建用户和授权权限的管理账号；总终端不会安装 MySQL 服务本身，但安装器会按向导创建独立数据库和最小权限应用账号。
- 一个生产域名及 TLS 证书。公网只暴露 Web 入口，MySQL、Redis 和 Spring Boot 端口保持内网。若先用 IP 初始化，必须显式启用临时 HTTP，完成宝塔反向代理和 HTTPS 后立即关闭。
- 独立保存的 `.env`，尤其是 `DB_URL`、`DB_PASSWORD`、`BOOTSTRAP_ADMIN_PASSWORD` 和 `SETTINGS_ENCRYPTION_KEY`。

### 准备外部 MySQL

确保安装器所在主机可以使用 `mysql` 或 `mariadb` 客户端连接 MySQL。安装器会依次询问管理地址/端口/账号、容器可达地址、目标数据库名、应用用户名和应用密码，然后：

1. 测试管理账号连接。
2. 检查目标数据库和应用用户名是否已存在。
3. 仅在两者都不存在时创建数据库、创建 `'应用用户'@'%'` 并授予目标库权限。
4. 将应用连接写入 `.env`；管理密码不会写入 `.env`。

发现同名数据库或用户时安装器会停止，不执行覆盖、删库或改密。应用账号使用 `%` 以兼容 Docker 网桥；生产环境完成部署后，建议按实际网段收窄来源并通过防火墙限制 3306。若 MySQL 与总终端同机，容器连接地址使用 `host.docker.internal`，不要填容器内的 `127.0.0.1`。

## 首次部署

```powershell
Set-Location <项目目录>
powershell -ExecutionPolicy Bypass -File .\deploy\install-controller.ps1
```

IP 临时初始化（登录密码会经过明文 HTTP，仅用于首次部署）：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\install-controller.ps1 -AllowInsecureHttp
```

Linux 总终端运行：

```bash
cd /path/to/monitor-for-server
bash ./deploy/install-controller.sh
```

安装器会先测试 MySQL 管理连接并收集数据库、Web、站点、管理员、时区、端口和绑定地址，全部通过校验后才检查并创建数据库和应用用户，随后生成设置加密密钥，执行 `docker compose config --quiet`，通过后才构建启动。它不读取隐式 `.env` 默认值；已有 `.env` 时会停止，只有显式传入 `--overwrite` / `-Overwrite` 才会备份后重建。绑定地址填 `0.0.0.0` 可用 IP 直连，填 `127.0.0.1` 可限制为宝塔本机反代。服务启动后，后续站点、通知和设备配置由管理员在控制台完成。

生产环境生成的 `.env` 至少包含：

```dotenv
SESSION_COOKIE_SECURE=true
ALLOWED_ORIGINS=https://monitor.example.com
PUBLIC_BASE_URL=https://monitor.example.com
WEB_BIND_ADDRESS=127.0.0.1
ALLOW_INSECURE_HTTP=false
```

使用 IP 临时部署时，安装器会生成 `ALLOW_INSECURE_HTTP=true` 和 `SESSION_COOKIE_SECURE=false`。宝塔反代和证书生效后，把 `PUBLIC_BASE_URL`、`ALLOWED_ORIGINS` 改为 `https://monitor.xciy.cn`，将 `SESSION_COOKIE_SECURE` 和 `ALLOW_INSECURE_HTTP` 分别改为 `true`、`false`，再执行 `docker compose up -d --force-recreate server web`。

未完成安装时，Compose 会因为关键变量缺失而直接失败，不会静默使用 `localhost` 或不安全 Cookie 默认值。安装器完成后检查：

```powershell
docker compose ps
docker compose logs --tail 100 server
```

首次启动从 `BOOTSTRAP_ADMIN_USERNAME` 和 `BOOTSTRAP_ADMIN_PASSWORD` 创建管理员；已有管理员时不会覆盖密码。登录后在“设备管理”创建节点，保存一次性 Agent 密钥。

## 网关要求

TLS 在 Caddy、Nginx、Traefik、宝塔或云负载均衡器终止，并转发到 Web 容器的 `WEB_PORT`。宝塔目标建议为 `http://127.0.0.1:<WEB_PORT>`；必须透传 `Host`、`X-Forwarded-For`、`X-Forwarded-Proto`，并为 `/ws/` 转发 Upgrade/Connection 头。鸿蒙端和浏览器都应使用同一个 HTTPS 域名。

## 更新与修改信息

1. 先备份外部 MySQL，并保留当前 `.env` 和设置加密密钥。
2. 拉取新版本后执行 `docker compose build --pull server web`。
3. 执行 `docker compose up -d`，Flyway 会自动运行数据库迁移。
4. 在“系统设置”修改站点名、入口 URL、采集周期、离线阈值和通知配置；敏感值会加密存储。

```powershell
mysqldump --defaults-extra-file=/secure/monitor-mysqldump.cnf monitor > monitor-backup.sql
docker compose up -d
```

## 鸿蒙 App 搭配边界

仓库不包含原生鸿蒙 App。鸿蒙端可以复用以下稳定契约：

- `POST /api/auth/login`、`GET /api/auth/me`：会话登录，建议使用 ArkUI 的安全 Cookie/网络层保存会话。
- `GET /api/dashboard`、`/api/devices`、`/api/devices/{id}/metrics/history`：页面数据和趋势。
- `GET /api/auth/csrf` 后，所有会话写请求携带 `X-XSRF-TOKEN`。
- 已登录 WebSocket `/ws/metrics`：接收刷新提示，REST 数据库仍是权威来源。

鸿蒙端不能使用 Agent 密钥，也不应把管理员凭据写入本地明文存储。生产域名必须允许鸿蒙网络栈的 HTTPS 与 WebSocket（`wss`）连接，并在 `ALLOWED_ORIGINS` 中配置实际 Web 控制台来源。
