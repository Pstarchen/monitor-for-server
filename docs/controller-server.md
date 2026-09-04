# 总终端服务器搭建材料

第一次部署且不熟悉 Docker、域名或首次向导时，请先按[新手使用指南](user-guide.md)操作。本页用于查阅总控服务器的生产部署和运维边界。

总终端服务器运行 Web 控制台、Spring Boot API、内置 PostgreSQL 和 Redis。被监控服务器只需要运行 Agent，不需要安装 Java、PostgreSQL 或 Node.js。

## 必备材料

- 一台 64 位 Linux 服务器以及 root/sudo 权限。在线入口会检测并通过受支持的发行版包管理器补齐 `curl`、Git、Docker Engine 24+ 和 Docker Compose v2。
- 安装器支持 `public`、`internal`、`offline`。`CN=true` 属于 `public` 国内在线路径：从 Gitee 取得固定版本编排文件，从腾讯云 TCR 拉取六个预构建镜像，不访问 GitHub、GitHub API、GHCR 或 Docker Hub，也不在目标机编译应用。`internal` 和 `offline` 才会禁止公网依赖安装。
- Docker Compose 会自动拉取 PostgreSQL 16 镜像并创建私有数据卷；数据库、用户和密码由控制端安装器自动生成，端口只在 Compose 内网可见。
- 一个生产域名及 TLS 证书。公网只暴露 Web 入口，PostgreSQL、Redis 和 Spring Boot 端口保持内网。若先用 IP 初始化，必须显式启用临时 HTTP，完成宝塔反向代理和 HTTPS 后立即关闭。
- 安装服务需要短暂访问宿主机 Docker socket，以便向导完成后自动重建生产容器；不要把安装端口以外的 Docker API 暴露到公网。

### 内置 PostgreSQL

安装器会在项目 `.env` 中生成随机 PostgreSQL 密码，并通过 Docker Compose 注入 `postgres`、`setup` 和 `server`。用户不需要安装数据库客户端、创建数据库、创建账号或执行 SQL。PostgreSQL 端口不发布到宿主机；数据库表由 Flyway 在生产服务首次启动时创建。

数据库数据位于 PostgreSQL 数据卷。新部署默认使用 `xingchen-monitor` Compose 项目、`xingchen_monitor` 数据库和 `xingchen` 用户。升级时保留该卷即可；安装器会识别旧版项目并继续使用原 `.env` 和数据卷，不会因为改名创建空数据库。重装或迁移前请使用 `pg_dump` 做逻辑备份。不要把 `.env` 或数据库卷备份上传到公网。

## 首次部署

能够访问 GitHub 和 GHCR 时，使用固定版本的一行入口：

```bash
curl -fsSL --proto '=https' --tlsv1.2 'https://raw.githubusercontent.com/Pstarchen/monitor-for-server/v1.20.17/deploy/xingchen.sh' -o xingchen.sh && chmod +x xingchen.sh && sudo ./xingchen.sh install --version v1.20.17
```

中国大陆服务器或无法访问 GitHub/GHCR 时，使用 Gitee 和腾讯云 TCR：

```bash
curl -fsSL --proto '=https' --tlsv1.2 'https://gitee.com/starchen520/monitor-for-server/raw/v1.20.17/deploy/xingchen.sh' -o xingchen.sh && chmod +x xingchen.sh && sudo CN=true ./xingchen.sh install --version v1.20.17
```

两个入口都固定到 `v1.20.17`，不要替换为可变的 `main`。默认安装目录是 `/opt/guanlan-monitor`，可通过 `--install-dir <绝对路径>` 修改。`CN=true` 直接拉取 `ccr.ccs.tencentyun.com/xc_monitor` 下的六个公开预构建镜像，不在目标机编译；它不代表离线，如果目标机也无法访问 Gitee、腾讯云 TCR 或系统包源，就应使用内部源或已校验的离线 bundle。

需要禁止所有公共代码托管和镜像服务时，先在可联网发布机把 setup、server、web、agent、PostgreSQL、Redis 六个 digest 固定镜像晋级到内部 Registry，并把四平台 Agent 制品发布到内部 HTTPS 域。目标机配置 `.env` 后执行：

```bash
bash ./deploy/install-controller.sh --network-mode internal --no-source-fallback
```

生产建议至少设置：

```dotenv
XINGCHEN_NETWORK_MODE=internal
XINGCHEN_ALLOW_GITEE=false
XINGCHEN_CONTROLLER_ALLOW_GITHUB_API=false
XINGCHEN_RELEASE_MANIFEST_URLS=https://release.internal.example/xingchen/v1.20.17/manifest.json
XINGCHEN_RELEASE_MANIFEST_SHA256=<受信 manifest 摘要>
XINGCHEN_AGENT_RELEASE_BASE_URLS=https://release.internal.example/xingchen
```

六个 `XINGCHEN_*_IMAGE` 必须使用内部 Registry 的固定 digest；上面的域名和摘要只是占位符，未替换时不得部署。完整晋级和配置示例见[部署与运维](deployment.md#内部源与完全离线安装)。

打开 `http://<服务器IP>:18080/setup`，按页面顺序完成：

1. 确认 PostgreSQL 服务健康，安装器已自动生成数据库凭据。
2. 设置公网入口、来源、站点名、时区和首个管理员密码。
3. 提交后页面会自动进入登录页；生产服务就绪前登录按钮会暂时锁定，就绪后即可登录。

管理员可在控制台“系统设置 > 系统更新”中查看当前/最新语义版本、发布来源、缓存、校验、失败阶段和镜像回滚结果，也可启用每日 04:00 自动更新。`CN=true` 部署通过 Gitee 稳定标签发现新版本，GitHub 部署只读取已公开 Release；内部或离线部署继续优先使用受信 manifest 和 last-known-good 缓存。连续 3 次自动失败会暂停 24 小时，手动更新不受影响。命令行仍可使用 `deploy/update-controller.sh --check`、`--apply` 和 `--auto`。

如果暂时没有域名，可以先用 `http://<服务器IP>:18080`；HTTPS 和宝塔反代配置完成后，再在系统设置中切换为正式域名。

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
docker compose --profile host-monitoring ps
docker compose logs --tail 100 server
```

首次启动从 `BOOTSTRAP_ADMIN_USERNAME` 和 `BOOTSTRAP_ADMIN_PASSWORD` 创建管理员；已有管理员时不会覆盖密码。Linux 总终端会自动注册为“总控服务器”并显示在“设备管理”中，无需创建设备、复制凭据或另装 Agent。其他节点在“设备管理”创建并使用 15 分钟一次性接入令牌安装 Agent。

## 总控宿主机监控

Linux 安装器会生成仅限本机使用的设备 ID 和密钥，启用 `host-monitoring` Compose profile，并以只读方式挂载宿主机的 `/proc`、`/sys`、`/etc` 与根目录。总控 Agent 经本机 Web 网关上报，因此不会依赖公网域名或额外开放端口。设备密钥在 `.env` 中保存，控制台不能轮换或删除该受管设备，避免误操作中断自身监控。

Windows Docker Desktop 的 Linux 容器只能看到虚拟机，不能代表 Windows 宿主机；Windows 安装器因此默认关闭自动总控监控。如需采集 Windows 总终端，请在“设备管理”按普通 Windows Agent 流程接入。

## 网关要求

TLS 在 Caddy、Nginx、Traefik、宝塔或云负载均衡器终止，并转发到 Web 容器的 `WEB_PORT`。宝塔目标建议为 `http://127.0.0.1:<WEB_PORT>`；必须透传 `Host`、`X-Forwarded-Host`、`X-Forwarded-For`、`X-Forwarded-Proto`，并为 `/ws/` 转发 Upgrade/Connection 头。鸿蒙端和浏览器都应使用同一个 HTTPS 域名。

## 更新与修改信息

安装成功后会创建 `/usr/local/bin/xingchen` 管理命令，常用动作无需再记 Compose 参数：

```bash
sudo xingchen status
sudo xingchen logs
sudo xingchen restart
sudo xingchen update
```

不带动作运行 `sudo xingchen` 会打开交互菜单。管理器会从现有部署的 Git origin 沿用 GitHub 或 Gitee 来源；中国模式后续直接更新不会回退到 GitHub/GHCR，也可以用 `sudo xingchen update --source gitee` 显式指定。

更新前仍应备份 PostgreSQL 和当前 `.env`，特别是 `SETTINGS_ENCRYPTION_KEY`。`update` 会调用受保护的总控更新流程，完成候选版本准备、数据库备份、Compose 切换、健康检查和必要的应用镜像回滚。高级场景可直接执行 `bash ./deploy/update-controller.sh --apply`；`--source-build` 强制从配置的仓库构建，`--build` 构建当前目录源码。Flyway 会在新服务启动时自动运行数据库迁移。

站点名、入口 URL、采集周期、离线阈值和通知配置继续在“系统设置”修改；敏感值会加密存储。

更新失败不会删除数据卷。健康检查失败时更新器会尝试恢复旧应用镜像并再次检查，但不会自动回滚 PostgreSQL；新版本 `server` 可能已经执行前向 Flyway 迁移，因此镜像恢复后仍必须确认数据库兼容性。需要完整降级时，应使用升级前备份恢复 PostgreSQL。

若操作系统信号恰好中断 Compose 切换，外层管理器会恢复源码、Git origin 和 `.env`，但不能据此断定运行中的容器已恢复。重新登录后先运行 `sudo xingchen status`；状态不一致时在维护窗口内重新执行同一条 `sudo xingchen update --version <版本>`，不要手工删除数据卷。

完全断网的已有部署必须使用离线包内的 `upgrade-offline.sh/.ps1`，不能再次运行新装入口。例如从 `v1.20.15` 升级到 `v1.20.16`：

```bash
sha256sum -c xingchen-monitor-offline-v1.20.16-amd64.tar.gz.sha256
tar -xzf xingchen-monitor-offline-v1.20.16-amd64.tar.gz
cd xingchen-monitor-offline-v1.20.16-amd64
sudo ./upgrade-offline.sh --project-root /opt/guanlan-monitor --check
sudo ./upgrade-offline.sh --project-root /opt/guanlan-monitor --apply
```

升级入口会保留现有 `.env`、端口、Compose 项目名和数据卷，切换前创建 PostgreSQL 逻辑备份；它不会重新生成数据库密码。即使应用镜像回滚成功，也仍需单独判断 Flyway 迁移后的数据库兼容性。

```powershell
docker compose exec -T postgres pg_dump -U "$(grep '^POSTGRES_USER=' .env | cut -d= -f2)" "$(grep '^POSTGRES_DB=' .env | cut -d= -f2)" > monitor-backup.sql
docker compose --profile host-monitoring up -d
```

## 鸿蒙 App 搭配边界

仓库不包含原生鸿蒙 App。鸿蒙端可以复用以下稳定契约：

- `POST /api/auth/login`、`GET /api/auth/me`：会话登录，建议使用 ArkUI 的安全 Cookie/网络层保存会话。
- `GET /api/dashboard`、`/api/devices`、`/api/devices/{id}/metrics/history`：页面数据和趋势。
- `GET /api/auth/csrf` 后，所有会话写请求携带 `X-XSRF-TOKEN`。
- 已登录 WebSocket `/ws/metrics`：接收刷新提示，REST 数据库仍是权威来源。

鸿蒙端不能使用 Agent 密钥，也不应把管理员凭据写入本地明文存储。生产域名必须允许鸿蒙网络栈的 HTTPS 与 WebSocket（`wss`）连接，并在 `ALLOWED_ORIGINS` 中配置实际 Web 控制台来源。
