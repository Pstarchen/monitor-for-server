# 总终端服务器搭建材料

总终端服务器是运行 Web 控制台、Spring Boot API 和 Redis 的那台机器，并连接用户自行准备的外部 MySQL。被监控服务器只需要运行 Agent，不需要安装 Java、MySQL 或 Node.js。

## 必备材料

- Docker Engine 24+ 和 Docker Compose v2。
- 外部 MySQL 8.0+ 实例；总终端不会安装 MySQL 服务、创建数据库或修改 MySQL 用户。请先在 MySQL 管理端创建目标数据库和应用账号，并授予目标库建表、索引权限。
- 一个生产域名及 TLS 证书。公网只暴露 Web 入口，MySQL、Redis 和 Spring Boot 端口保持内网。若先用 IP 初始化，必须显式启用临时 HTTP，完成宝塔反向代理和 HTTPS 后立即关闭。
- 安装服务需要短暂访问宿主机 Docker socket，以便向导完成后自动重建生产容器；不要把安装端口以外的 Docker API 暴露到公网。

### 准备外部 MySQL

浏览器向导运行在总终端的 `setup` 内部服务中，不要求宿主机安装 MySQL 客户端。第一步必须一次填写真实的 MySQL 访问地址、端口、已创建的数据库名、已授权用户名和密码；点击测试后直接连接目标库并初始化表结构：

1. 使用填写的五项信息直接打开目标数据库；不会替换主机地址，也不会猜测 Docker 网桥地址。
2. 空数据库执行服务端 V1 表结构并写入 Flyway 初始记录；已有数据库会逐项校验监控表和关键字段，避免把不完整旧库当作可用库。
3. 检查 Flyway 迁移记录，发现失败迁移会停止安装；通过后才将数据库连接写入总终端私有 `.env`，不输出密码。

如果数据库已有不完整表结构，安装器会停止并提示使用空数据库或先完成迁移，不会删除或覆盖业务数据。生产环境建议按实际网段限制 MySQL 来源并通过防火墙保护 3306。MySQL 地址必须是从总终端容器可达的实际主机名或 IP；安装器不会把 `localhost`、`127.0.0.1` 或其他地址自动转换成 Docker 网关。

如果页面显示 MySQL 错误码 `1130`，说明网络已经连通，但 MySQL 用户的来源主机规则拒绝了总终端来源。请在 MySQL 管理端按实际来源网段增加账号 Host 授权并授予目标库权限；只存在 `user@localhost` 的账号不能从容器登录。

向导会在 1130 响应中显示不含真实凭据的授权 SQL 模板，可复制到宝塔数据库终端后，按实际来源主机、账号策略和密码替换占位符；不要把 `%` 当成默认安全配置。

## 首次部署

```bash
git clone https://github.com/Pstarchen/monitor-for-server.git
cd monitor-for-server
docker compose up --build -d
```

打开 `http://<服务器IP>:18080/setup`，按页面顺序完成：

1. 填写 MySQL 地址、端口、目标数据库名、用户名和密码，测试连接并准备数据库。
2. 设置公网入口、来源、站点名、Web 端口、绑定地址和首个管理员密码。
3. 等待页面显示服务重建完成，再进入登录页。

MySQL 访问地址必须填写总终端容器可以访问的实际地址；同机部署时请根据服务器 Docker 网桥和 MySQL `bind-address` 配置确定可达 IP，不要直接照抄浏览器中的 `localhost`。如果暂时没有域名，可以先用 `http://<服务器IP>:18080`；HTTPS 和宝塔反代配置完成后，再在系统设置或 `.env` 中切换为正式域名。

向导只在首次安装期间写入 `.env`，会为已有文件生成 `.env.backup.setup.<时间>`，不会删除或覆盖数据库中的业务数据。完成后 `setup` 服务不再接受安装提交；升级和日常配置仍通过 Compose 与控制台完成。命令行安装器是浏览器不可用时的备用路径。

生产环境生成的 `.env` 至少包含：

```dotenv
SESSION_COOKIE_SECURE=true
ALLOWED_ORIGINS=https://monitor.example.com
PUBLIC_BASE_URL=https://monitor.example.com
WEB_BIND_ADDRESS=127.0.0.1
ALLOW_INSECURE_HTTP=false
```

使用 IP 临时部署时，安装器会生成 `ALLOW_INSECURE_HTTP=true` 和 `SESSION_COOKIE_SECURE=false`。宝塔反代和证书生效后，把 `PUBLIC_BASE_URL`、`ALLOWED_ORIGINS` 改为 `https://monitor.xciy.cn`，将 `SESSION_COOKIE_SECURE` 和 `ALLOW_INSECURE_HTTP` 分别改为 `true`、`false`，再执行 `docker compose up -d --force-recreate server web`。

首次未完成安装时，Compose 使用临时 H2 bootstrap 配置，只用于让向导可访问；未完成安装不会创建管理员，也不会进入生产监控状态。向导完成后检查：

```powershell
docker compose ps
docker compose logs --tail 100 server
```

首次启动从 `BOOTSTRAP_ADMIN_USERNAME` 和 `BOOTSTRAP_ADMIN_PASSWORD` 创建管理员；已有管理员时不会覆盖密码。登录后在“设备管理”创建节点，保存一次性 Agent 密钥。

## 网关要求

TLS 在 Caddy、Nginx、Traefik、宝塔或云负载均衡器终止，并转发到 Web 容器的 `WEB_PORT`。宝塔目标建议为 `http://127.0.0.1:<WEB_PORT>`；必须透传 `Host`、`X-Forwarded-Host`、`X-Forwarded-For`、`X-Forwarded-Proto`，并为 `/ws/` 转发 Upgrade/Connection 头。鸿蒙端和浏览器都应使用同一个 HTTPS 域名。

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
