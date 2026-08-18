# 部署与运维

材料已按角色拆分：先阅读[总终端服务器搭建材料](controller-server.md)，再阅读[受监控服务器搭建材料](monitored-agent.md)。本页保留完整的运维参考和故障排查。

## 前置条件

- Docker Engine 24+ 与 Docker Compose v2。
- 外部 MySQL 8.0+；总终端 Compose 不再携带 MySQL 容器，首次运行网页向导使用用户提供的管理账号创建数据库和应用账号。
- 生产域名和 TLS 证书；生产环境不得直接暴露明文 HTTP。仅首次用 IP 初始化时可按总终端安装材料显式启用临时 HTTP。
- 每台被监控主机具备 systemd 或 Windows 服务管理权限。
- 从源码构建 Agent 时需要 Go 1.24+；生产环境建议向安装器传入预编译二进制。

## Docker Compose 部署

在项目根目录直接启动 Compose。未完成安装时，服务会以临时 bootstrap 配置启动，Web 只提供 `/setup` 向导：

```bash
docker compose up --build -d
docker compose ps
```

然后打开：

```bash
http://<服务器IP>:18080/setup
```

向导第一步要求同时填写 MySQL 地址、端口、目标数据库名、管理用户名和密码，并检测管理连接及目标数据库是否可创建；下一步再设置容器连接地址、应用账号和密码。随后安装器创建数据库和应用账号，写入生产 `.env`，再自动执行 `docker compose up -d --build server web`。管理员账号在生产数据库迁移后由服务端创建。MySQL 管理密码只在安装服务内存中使用，不会写入 `.env`。发现已有同名库或用户时会停止，避免覆盖数据。

无法使用浏览器时，命令行安装器仍然可用：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\install-controller.ps1
```

Linux：

```bash
bash ./deploy/install-controller.sh
```

生产环境生成的配置至少包含：

```dotenv
SESSION_COOKIE_SECURE=true
ALLOWED_ORIGINS=https://monitor.example.com
PUBLIC_BASE_URL=https://monitor.example.com
```

启动服务（安装器已执行过时无需重复执行）：

```powershell
docker compose up --build -d
docker compose ps
docker compose logs --tail 100 server
```

完成向导后入口以页面提示为准。首次生产启动时，服务端从向导写入的 `BOOTSTRAP_ADMIN_USERNAME` 与 `BOOTSTRAP_ADMIN_PASSWORD` 创建管理员；已有管理员时不会覆盖密码。

## TLS 入口

Compose 中的 Web 容器负责静态资源、REST 与 WebSocket 内部代理。生产环境应在其前方配置 Caddy、Nginx、Traefik 或云负载均衡器终止 TLS，并将流量转发到 `WEB_PORT`。入口必须：

    - 透传 `Host`、`X-Forwarded-Host`、`X-Forwarded-For` 和 `X-Forwarded-Proto`。
- 为 `/ws/` 开启 WebSocket Upgrade。
- 仅允许公网访问 Web 入口，不发布 MySQL、Redis 和 Spring Boot 端口。
- 配合 `SESSION_COOKIE_SECURE=true` 和精确的 HTTPS `ALLOWED_ORIGINS`。

宝塔反向代理可将 `http://127.0.0.1:<WEB_PORT>` 作为目标，并开启 WebSocket。域名证书生效后，将 `.env` 中的 `PUBLIC_BASE_URL`、`ALLOWED_ORIGINS` 改为 `https://monitor.xciy.cn`，把 `SESSION_COOKIE_SECURE=true`、`ALLOW_INSECURE_HTTP=false`，然后重建 `server web`。

## 创建设备

1. 登录 Web 控制台并打开“设备管理”。
2. 添加设备并立即保存设备 ID 与一次性 Agent 密钥。
3. 密钥关闭后无法找回；遗失时由管理员轮换密钥。

## Linux Agent

安装器默认从当前仓库源码构建 Agent。密钥通过环境变量提供，避免进入命令历史：

```bash
export GUANLAN_AGENT_KEY='<一次性密钥>'
sudo --preserve-env=GUANLAN_AGENT_KEY ./deploy/install-agent.sh \
  --server-url https://monitor.example.com \
  --device-id '<设备ID>' \
  --interval 3s \
  --disk / \
  --disk /data \
  --service nginx \
  --service mysql
```

低配置或连接密集型主机可添加 `--skip-processes --skip-connections`。支持 `1s`、`3s`、`10s`、`30s`、`60s`，不传 `--disk` 时采集全部可用分区。

使用预编译二进制时添加 `--binary /path/to/guanlan-agent`。安装结果：

- 程序：`/usr/local/bin/guanlan-agent`
- 配置：`/etc/guanlan-agent/agent.json`，权限 `0600`
- 缓冲：`/var/lib/guanlan-agent/spool`
- 服务：`guanlan-agent.service`

检查状态：

```bash
systemctl status guanlan-agent
journalctl -u guanlan-agent -n 100 --no-pager
```

## Windows Agent

以管理员 PowerShell 运行：

```powershell
$env:GUANLAN_AGENT_KEY = '<一次性密钥>'
& .\deploy\install-agent.ps1 `
  -ServerUrl 'https://monitor.example.com' `
  -DeviceId '<设备ID>' `
  -Interval '3s' `
  -DiskMountpoint 'C:\','D:\' `
  -MonitoredService 'W3SVC','MSSQLSERVER'
```

轻量采集可添加 `-SkipProcesses -SkipConnections`；不传 `-DiskMountpoint` 时采集全部可用分区。

使用预编译程序时添加 `-BinaryPath 'C:\staging\guanlan-agent.exe'`。脚本注册自动启动的 `GuanlanAgent` Windows 服务，并将配置写入 `%ProgramData%\GuanlanMonitor\agent.json`，ACL 仅允许 SYSTEM 与管理员访问。

检查状态：

```powershell
Get-Service GuanlanAgent
Get-Content "$env:ProgramData\GuanlanMonitor\agent.json" | ConvertFrom-Json | Select-Object server_url,device_id,interval
```

不要输出或展示 `agent_key` 字段。

## 通知配置

邮件、钉钉和企业微信可在 Web 控制台的“系统设置”中启用、编辑和测试。SMTP 密码与 Webhook 写入数据库前使用 AES-256-GCM 加密，页面只显示是否已配置；`.env` 中的值作为未设置数据库覆盖值时的回退。修改环境回退值后重建服务端容器：

```powershell
docker compose up -d --force-recreate server
```

## 备份与升级

备份前创建一致性 MySQL 逻辑备份，并将部署使用的 `.env`，特别是 `SETTINGS_ENCRYPTION_KEY`，保存在独立秘密管理系统。Redis 仅用于在线状态加速，不是主要备份目标。

```powershell
mysqldump --defaults-extra-file=/secure/monitor-mysqldump.cnf monitor > monitor-backup.sql
```

数据库密码只通过 `.env` 注入服务端，不会展开到宿主机命令输出。升级步骤：

```powershell
docker compose build --pull server web
docker compose up -d
docker compose ps
```

Flyway 会在服务端启动时执行数据库迁移。升级前先在测试环境验证备份恢复。

## 故障排查

- Web 显示 502：检查 `docker compose ps` 与 `docker compose logs server`，确认服务端健康检查通过。
- 登录后写操作返回 403：确认浏览器允许同站 Cookie，入口域名与 `ALLOWED_ORIGINS` 完全一致。
- WebSocket 反复断开：确认外层代理转发 Upgrade 请求头，且会话 Cookie 可发送到 `/ws/metrics`。
- 设备一直待接入：核对 Agent 配置中的设备 ID、服务端 HTTPS 地址和密钥；密钥轮换后旧值立即失效。
- Agent 日志提示延迟上报：检查 DNS、证书链和防火墙。缓冲文件会保留在 spool 目录并在恢复后补传。
- 设备离线但无告警：检查系统离线判定时间、离线规则阈值和规则是否启用。
