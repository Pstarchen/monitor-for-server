# 部署与运维

## 前置条件

- Docker Engine 24+ 与 Docker Compose v2。
- 生产域名和 TLS 证书；生产环境不得直接暴露明文 HTTP。
- 每台被监控主机具备 systemd 或 Windows 服务管理权限。
- 从源码构建 Agent 时需要 Go 1.24+；也可以向安装器传入预编译二进制。

## Docker Compose 部署

在项目根目录创建部署环境文件：

```powershell
Copy-Item .env.example .env
```

为 `MYSQL_ROOT_PASSWORD`、`MYSQL_PASSWORD` 和 `BOOTSTRAP_ADMIN_PASSWORD` 设置互不相同的强随机值。生产环境还应设置：

```dotenv
SESSION_COOKIE_SECURE=true
ALLOWED_ORIGINS=https://monitor.example.com
```

不要提交 `.env`。启动服务：

```powershell
docker compose up --build -d
docker compose ps
docker compose logs --tail 100 server
```

默认通过 `http://localhost:8080` 访问。首次启动时，服务端从 `BOOTSTRAP_ADMIN_USERNAME` 与 `BOOTSTRAP_ADMIN_PASSWORD` 创建管理员；已有同名账号时不会覆盖密码。

## TLS 入口

Compose 中的 Web 容器负责静态资源、REST 与 WebSocket 内部代理。生产环境应在其前方配置 Caddy、Nginx、Traefik 或云负载均衡器终止 TLS，并将流量转发到 `WEB_PORT`。入口必须：

- 透传 `Host`、`X-Forwarded-For` 和 `X-Forwarded-Proto`。
- 为 `/ws/` 开启 WebSocket Upgrade。
- 仅允许公网访问 Web 入口，不发布 MySQL、Redis 和 Spring Boot 端口。
- 配合 `SESSION_COOKIE_SECURE=true` 和精确的 HTTPS `ALLOWED_ORIGINS`。

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
  --service nginx \
  --service mysql
```

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
  -MonitoredService 'W3SVC','MSSQLSERVER'
```

使用预编译程序时添加 `-BinaryPath 'C:\staging\guanlan-agent.exe'`。脚本注册自动启动的 `GuanlanAgent` Windows 服务，并将配置写入 `%ProgramData%\GuanlanMonitor\agent.json`，ACL 仅允许 SYSTEM 与管理员访问。

检查状态：

```powershell
Get-Service GuanlanAgent
Get-Content "$env:ProgramData\GuanlanMonitor\agent.json" | ConvertFrom-Json | Select-Object server_url,device_id,interval
```

不要输出或展示 `agent_key` 字段。

## 通知配置

邮件、钉钉和企业微信通道通过 `.env` 配置。Webhook URL 和 SMTP 密码属于密钥，不会通过 Web 设置页面读取或返回。修改后重建服务端容器：

```powershell
docker compose up -d --force-recreate server
```

## 备份与升级

备份前创建一致性 MySQL 逻辑备份，并保留部署使用的 `.env` 于独立秘密管理系统。Redis 仅用于在线状态加速，不是主要备份目标。

```powershell
docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysqldump -umonitor monitor' > monitor-backup.sql
```

密码只在数据库容器内部从环境变量读取，不会展开到宿主机命令。升级步骤：

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
