# 部署与运维

材料已按角色拆分：先阅读[总终端服务器搭建材料](controller-server.md)，再阅读[受监控服务器搭建材料](monitored-agent.md)。本页保留完整的运维参考和故障排查。

## 前置条件

- Docker Engine 24+ 与 Docker Compose v2。
- Docker Compose 会自动启动 PostgreSQL 16 和 Redis。数据库、用户和密码由控制端安装器自动生成，数据库端口只在 Compose 内网可见，无需安装数据库客户端或执行 SQL。
- 生产域名和 TLS 证书；生产环境不得直接暴露明文 HTTP。仅首次用 IP 初始化时可按总终端安装材料显式启用临时 HTTP。
- Linux 被监控主机推荐安装 Docker Engine；Docker 不可用时需要 systemd，以及预编译 Agent 或 Go 1.24+ 与 git。
- Windows 被监控主机需要 Windows 服务管理权限；Windows Docker Desktop 不能代表 Windows 宿主机，因此仍使用原生 Agent。

## Docker Compose 部署

Linux 生产环境应使用总终端安装器启动。它默认先从国内镜像源拉取总控 `setup`、`server`、`web` 镜像，失败后回退 GHCR，并自动生成数据库与总控 Agent 凭据，将本机作为“总控服务器”显示到“设备管理”。未完成安装时，服务会以临时 bootstrap 配置启动，Web 只提供 `/setup` 向导：

```bash
bash ./deploy/install-controller.sh
docker compose --profile host-monitoring ps
```

离线或需要从当前源码构建总控镜像时：

```bash
bash ./deploy/install-controller.sh --build
```

然后打开：

```bash
http://<服务器IP>:18080/setup
```

安装器会生成 PostgreSQL 凭据并启动数据库。首次向导只需配置站点入口、来源、时区和首个管理员；Web 端口、绑定地址和 Compose 项目名在总终端启动前确定。向导写入生产 `.env` 后会同时重建 `server` 和 `web`，因此提交后会进入公开状态页，不会回到 Setup 或出现 502；服务完全就绪后可从状态页进入登录控制台。Flyway 在服务端启动时创建或升级表结构。数据库凭据只写入总终端私有配置，不会进入日志。

Linux 总终端不需要单独安装 Agent。安装器启动的 `controller-agent` 通过本机网关上报宿主机指标，生产服务就绪后“设备管理”会出现“总控服务器”。它读取宿主机而非容器的 CPU、内存、网络和磁盘信息；不要在控制台轮换或删除这台系统管理设备。

### 站点信息配置

首次向导中的字段直接决定浏览器、反向代理和 Agent 的访问方式：

- `站点名称`：登录页、侧栏和通知中显示的产品名称。
- `网站图标`：浏览器标签页显示的图标，默认使用 `/favicon.svg`；也可以填写站内路径或 HTTPS 图片地址，或上传不超过 50MB 的图片文件。上传文件保存在总控持久卷中。
- `公网入口`：用户和 Agent 实际访问的完整地址，例如 `https://monitor.example.com` 或临时初始化用的 `http://<服务器IP>:18080`；不要填写路径、查询参数或片段。
- `允许的 Web 来源`：逗号分隔的浏览器来源，必须包含公网入口；有多个域名时逐项填写完整的 `http(s)://host[:port]`。
- `服务时区`：使用 IANA 名称，例如 `Asia/Shanghai`，用于告警和审计时间展示。
- Web 端口与绑定地址由总终端安装器在首次启动前写入 `.env`，默认是 `18080` 和 `0.0.0.0`。只通过宝塔/Caddy/Nginx 反代时，在安装器启动前将绑定地址改为 `127.0.0.1`。浏览器向导不会再修改这两项，避免提交时切断当前页面。

正式域名和 TLS 生效后，在“系统设置”同步修改站点入口，确保 `PUBLIC_BASE_URL`、`ALLOWED_ORIGINS` 使用 HTTPS 且来源完全一致，并执行 `docker compose up -d --force-recreate server web`。不要把数据库密码、Agent 密钥或管理员密码写进站点地址。

安装完成后，直接访问 `PUBLIC_BASE_URL` 对应的域名根路径即可进入公开状态页，不需要追加 `/status`。安装向导会同时重建 `server` 和 `web`，确保当前源码中的根路径规则已生效。若是已有实例升级了这项规则，请执行：

```bash
docker compose up -d --build --no-deps server web
```

旧的 `/status` 和 `/status/` 地址会自动重定向到根路径。

无法使用浏览器时，命令行安装器仍然可用：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\install-controller.ps1
```

Linux：

```bash
bash ./deploy/install-controller.sh
```

总控更新可以先检查并拉取候选镜像，再决定是否重启：

```bash
sudo bash ./deploy/update-controller.sh --check
sudo bash ./deploy/update-controller.sh --apply
sudo bash ./deploy/update-controller.sh --auto
```

更新器默认允许单个镜像最多拉取 600 秒、Compose 操作最多执行 900 秒，适配带宽受限或首次下载镜像的环境。可通过 `GUANLAN_UPDATE_PULL_TIMEOUT_SECONDS` 和 `GUANLAN_UPDATE_COMPOSE_TIMEOUT_SECONDS` 调整；更新状态会在命令明确失败时记录错误，不会删除数据库卷。

更新器默认依次尝试可用的 `ghcr.1ms.run` 和 `ghcr.nju.edu.cn`，失败后回退到官方 GHCR；不会默认使用未将本项目加入白名单的 DaoCloud 公共镜像。首次安装和系统设置中的更新都使用这条顺序，单个镜像源默认最多等待 180 秒。可通过 `GUANLAN_CONTROLLER_IMAGE_MIRRORS` 传入逗号分隔的镜像前缀，或使用 `--no-mirror` 跳过镜像源；需要本地构建时使用 `--build`。`--auto` 会启用由 setup 服务执行的每日 04:00 自动更新，失败不会删除数据库卷。

升级前只清理本项目旧容器和本地镜像（保留 PostgreSQL/Redis 数据卷）时使用 `--cleanup`；不带该参数不会做破坏性清理。镜像默认从 GHCR 拉取，可通过 `GUANLAN_SETUP_IMAGE`、`GUANLAN_SERVER_IMAGE`、`GUANLAN_WEB_IMAGE` 和 `GUANLAN_AGENT_IMAGE` 指向内部仓库或固定版本。若 `.env` 缺少有效的 PostgreSQL 密码，安装器会重新生成 bootstrap 配置，不会复用旧数据库配置。

生产环境生成的配置至少包含：

```dotenv
SESSION_COOKIE_SECURE=true
ALLOWED_ORIGINS=https://monitor.example.com
PUBLIC_BASE_URL=https://monitor.example.com
```

启动服务（安装器已执行过时无需重复执行）：

```bash
docker compose --profile host-monitoring ps
docker compose logs --tail 100 server
```

完成向导后入口以页面提示为准。首次生产启动时，服务端从向导写入的 `BOOTSTRAP_ADMIN_USERNAME` 与 `BOOTSTRAP_ADMIN_PASSWORD` 创建管理员；已有管理员时不会覆盖密码。

## TLS 入口

Compose 中的 Web 容器负责静态资源、REST 与 WebSocket 内部代理。生产环境应在其前方配置 Caddy、Nginx、Traefik 或云负载均衡器终止 TLS，并将流量转发到 `WEB_PORT`。入口必须：

- 透传 `Host`、`X-Forwarded-Host`、`X-Forwarded-For` 和 `X-Forwarded-Proto`。
- 为 `/ws/` 开启 WebSocket Upgrade。
- 仅允许公网访问 Web 入口，不发布 PostgreSQL、Redis 和 Spring Boot 端口。
- 配合 `SESSION_COOKIE_SECURE=true` 和精确的 HTTPS `ALLOWED_ORIGINS`。

宝塔反向代理可将 `http://127.0.0.1:<WEB_PORT>` 作为目标，并开启 WebSocket。域名证书生效后，将 `.env` 中的 `PUBLIC_BASE_URL`、`ALLOWED_ORIGINS` 改为 `https://monitor.xciy.cn`，把 `SESSION_COOKIE_SECURE=true`、`ALLOW_INSECURE_HTTP=false`，然后重建 `server web`。

## 创建设备

1. 登录 Web 控制台并打开“设备管理”。
2. 添加设备并立即保存设备 ID 与一次性 Agent 密钥。
3. 密钥关闭后无法找回；遗失时由管理员轮换密钥。

## Linux Agent

安装器默认检测 Docker 守护进程，成功时直接拉取 GHCR 预构建镜像并启动容器，不要求 Go。密钥通过环境变量提供，避免进入命令历史：

```bash
export GUANLAN_AGENT_KEY='<一次性密钥>'
installer_script="$(mktemp)"
trap 'rm -f "$installer_script"' EXIT
download_installer() {
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 "$1" -o "$installer_script" \
      && return 0
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 "$1" -o "$installer_script" \
      && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -4 -t 3 -T 10 -O "$installer_script" "$1" \
      && return 0
    wget -t 3 -T 10 -O "$installer_script" "$1" \
      && return 0
  fi
  return 1
}
if ! download_installer \
  'https://monitor.example.com/api/setup/agent-installer?platform=linux'; then
  if ! download_installer \
    'https://cdn.jsdelivr.net/gh/Pstarchen/monitor-for-server@v1.11.1/deploy/install-agent.sh'; then
    download_installer \
      'https://raw.githubusercontent.com/Pstarchen/monitor-for-server/v1.11.1/deploy/install-agent.sh' \
      || { echo '无法下载 Agent 安装器：总控、CDN 和 GitHub 均不可达，请检查服务器出口、防火墙或 DNS。' >&2; exit 1; }
  fi
fi
sudo --preserve-env=GUANLAN_AGENT_KEY bash "$installer_script" \
  --server-url monitor.example.com \
  --device-id '<设备ID>' \
  --interval 3s \
  --disk / \
  --disk /data \
  --service nginx \
  --service sshd \
  --process java
```

低配置或连接密集型主机可添加 `--skip-processes --skip-connections`。使用 `--process java`（可重复指定，最多 32 个）可额外保留关键进程，即使其不在 CPU 排名前 12；需要完整进程清单时添加 `--all-processes --process-limit 128`（最多 256 个），也可用 `--skip-ports`、`--skip-containers` 或对应的 `--port-limit`、`--container-limit` 控制明细量。Windows 安装器对应使用 `-MonitoredProcess java`、`-CollectAllProcesses`。如明确需要远程一次性命令或 MCP 文件操作，再分别添加 `--allow-command-execution`、`--allow-file-operations`；两项默认关闭。支持 `1s`、`3s`、`10s`、`30s`、`60s`，不传 `--disk` 时采集全部可用分区。

需要个性化指标时，在 Agent 配置的 `custom_metrics` 数组中添加最多 32 个参数化程序。程序不经过 Shell，每项最多运行 3 秒，`kind` 支持 `number`、`text`、`exit_code`；服务端设备详情会展示结果，告警规则可对数值项设置阈值。详见 `docs/monitored-agent.md` 中的 JSON 示例。Linux 还可添加 `--system-logs` 采集存在的标准系统日志文件（最多展示每个文件最近 20 行）。

`--server-url` 可以填写域名或 `域名:端口`，安装器会先探测 `https://主机/healthz`；若 HTTPS 不可用但 HTTP 健康检查可用，会自动回退到 `http://主机` 并在 Agent 配置中启用明文连接。也可以直接传入完整的 `http(s)://` 地址。生产环境建议配置 HTTPS，HTTP 仅适合没有证书的临时或内网部署。默认镜像为 `ghcr.io/pstarchen/monitor-for-server-agent:latest`，支持 `linux/amd64` 与 `linux/arm64`。可用 `--image` 或 `GUANLAN_AGENT_IMAGE` 指向固定版本/内部仓库，`--container` 可覆盖容器名。Docker 模式会以只读方式映射 `/dev` 供可选 SMART 检测使用；虚拟磁盘或未授予设备访问权限时，SMART 会显示为未采集，不影响其他指标。Docker 模式安装结果：

- 容器：`guanlan-agent`，重启策略为 `unless-stopped`
- 配置：`/etc/guanlan-agent/agent.json`，只读挂载到容器
- 缓冲：Docker 卷 `guanlan-agent-spool`
- 宿主机：只读挂载到 `/host`，并使用 host network/PID 采集主机指标

```bash
docker ps --filter name=guanlan-agent
docker logs --tail 100 guanlan-agent
```

Docker 不可用时，`--binary /path/to/guanlan-agent` 会使用本机 systemd 服务；`--no-docker --binary /path/to/guanlan-agent` 可强制跳过 Docker。未提供二进制时，在线安装器会拉取源码，因此需要 Go 1.24+、git 和 systemd；可通过 `--source-url` 指向内部源码镜像。此回退模式安装结果：

- 程序：`/usr/local/bin/guanlan-agent`
- 配置：`/etc/guanlan-agent/agent.json`，权限 `0600`
- 缓冲：`/var/lib/guanlan-agent/spool`
- 服务：`guanlan-agent.service`

本机回退模式检查状态：

```bash
systemctl status guanlan-agent
journalctl -u guanlan-agent -n 100 --no-pager
```

## Windows Agent

以管理员 PowerShell 运行：

```powershell
$env:GUANLAN_AGENT_KEY = '<一次性密钥>'
& .\deploy\install-agent.ps1 `
  -ServerUrl 'monitor.example.com' `
  -DeviceId '<设备ID>' `
  -Interval '3s' `
  -DiskMountpoint 'C:\','D:\' `
  -MonitoredService 'W3SVC','MSSQLSERVER'
```

轻量采集可添加 `-SkipProcesses -SkipConnections`；需要完整进程清单时添加 `-CollectAllProcesses -ProcessCollectionLimit 128`（上限 256）。端口和容器也可分别通过 `-SkipPorts`、`-SkipContainers` 关闭，或用 `-PortCollectionLimit`、`-ContainerCollectionLimit` 调低明细上限。如明确需要远程一次性命令或 MCP 文件操作，再分别添加 `-AllowCommandExecution`、`-AllowFileOperations`，两项默认关闭。不传 `-DiskMountpoint` 时采集全部可用分区。

使用预编译程序时添加 `-BinaryPath 'C:\staging\guanlan-agent.exe'`。脚本注册自动启动的 `GuanlanAgent` Windows 服务，并将配置写入 `%ProgramData%\GuanlanMonitor\agent.json`，ACL 仅允许 SYSTEM 与管理员访问。即使已安装 Docker Desktop，Windows 也保持原生服务模式，以免采集到 Docker 的 Linux 虚拟机而不是 Windows 宿主机。

检查状态：

```powershell
Get-Service GuanlanAgent
Get-Content "$env:ProgramData\GuanlanMonitor\agent.json" | ConvertFrom-Json | Select-Object server_url,device_id,interval
```

不要输出或展示 `agent_key` 字段。

## 通知配置

邮件、钉钉、企业微信和通用 Webhook 可在 Web 控制台的“系统设置”中启用、编辑和测试。SMTP 密码、Webhook 和钉钉加签密钥写入数据库前使用 AES-256-GCM 加密，页面只显示是否已配置；钉钉安全关键词会自动附加到消息内容，避免关键词校验导致发送失败。通用 Webhook 可选择通用 JSON、Slack、Discord、飞书/Lark 或纯文本格式，服务端对通用端点只校验 HTTP 2xx。`.env` 中的值作为未设置数据库覆盖值时的回退（可使用 `DINGTALK_KEYWORD`、`DINGTALK_SIGN_SECRET`、`GENERIC_WEBHOOK_URL`、`GENERIC_WEBHOOK_FORMAT`）；修改环境回退值后重建服务端容器：

```powershell
docker compose up -d --force-recreate server
```

## 备份与升级

备份前创建一致性 PostgreSQL 逻辑备份，并将部署使用的 `.env`，特别是 `SETTINGS_ENCRYPTION_KEY`，保存在独立秘密管理系统。Redis 仅用于在线状态加速，不是主要备份目标。

```powershell
docker compose exec -T postgres pg_dump -U "$(grep '^POSTGRES_USER=' .env | cut -d= -f2)" "$(grep '^POSTGRES_DB=' .env | cut -d= -f2)" > monitor-backup.sql
```

数据库密码只通过 `.env` 注入服务端，不会展开到宿主机命令输出。升级步骤：

```powershell
docker compose pull setup server web controller-agent
docker compose up -d
docker compose ps
```

Flyway 会在服务端启动时执行数据库迁移。升级前先在测试环境验证备份恢复。

## 故障排查

- Web 显示 502：检查 `docker compose ps` 与 `docker compose logs server`，确认服务端健康检查通过。
- 登录后写操作返回 403：确认浏览器允许同站 Cookie，入口域名与 `ALLOWED_ORIGINS` 完全一致。
- WebSocket 反复断开：确认外层代理转发 Upgrade 请求头，且会话 Cookie 可发送到 `/ws/metrics`。
- 设备一直待接入：打开设备详情查看“Agent 接入诊断”。`等待 Agent 接入` 表示尚未收到首次上报；`Agent 已离线` 表示已超过失联阈值。然后在目标机检查 `docker logs --tail 100 guanlan-agent` 或 `journalctl -u guanlan-agent -n 100 --no-pager`，核对设备 ID、服务端 HTTPS 地址和密钥；密钥轮换后旧值立即失效。
- Agent 日志提示延迟上报：检查 DNS、证书链和防火墙。缓冲文件会保留在 spool 目录并在恢复后补传。
- Linux 安装器仍提示 Go 1.24+：Docker 命令不存在、守护进程不可达，或显式使用了 `--no-docker`；先运行 `docker info` 检查。要强制使用本机程序，请同时指定 `--no-docker --binary /path/to/guanlan-agent`。
- Agent 镜像无法拉取：确认 GHCR 包已设为 Public、目标机能访问 `ghcr.io`，或用 `--image` 指向可访问的镜像仓库。
- 总控镜像无法拉取：确认 GHCR 的 `monitor-for-server-{setup,server,web}` 包已设为 Public；也可使用 `bash ./deploy/install-controller.sh --build` 从源码构建。
- 设备离线但无告警：检查系统离线判定时间、离线规则阈值和规则是否启用。
