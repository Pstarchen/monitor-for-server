---
title: 常见问题与排障
description: 按安装、连接、Agent、告警、通知、备份和更新现象定位星辰监控问题。
---

# 常见问题与排障

先根据现象选择入口。排查时不要粘贴 `.env`、Agent 密钥、API Token、管理员密码或完整通知地址。

| 现象 | 优先检查 |
| --- | --- |
| 安装器找不到 Docker | Docker 服务状态与 Compose v2 |
| 网页打不开或显示 502 | 容器状态、服务端健康检查与端口占用 |
| 登录后退出或写操作 403 | HTTPS、Cookie、`PUBLIC_BASE_URL` 与 `ALLOWED_ORIGINS` |
| 设备一直待接入 | Agent 服务、设备 ID、总控地址与密钥 |
| 页面数据停止更新 | Agent 最近上报、WebSocket 与反向代理 Upgrade |
| 告警没有通知 | 规则范围、维护静默、渠道测试与投递记录 |
| 更新失败 | 更新入口版本、镜像源、备份空间、更新锁与健康检查 |

## 安装器提示找不到 Docker 或 Compose

运行：

```bash
docker --version
docker compose version
docker info
```

`docker info` 必须能连接守护进程。项目要求 Compose v2，命令是 `docker compose`，不是旧版 `docker-compose`。普通用户没有权限时，按服务器安全策略使用 `sudo` 或配置 Docker 访问权限。

Windows 环境还需确认 Docker Desktop 已启动，并使用 Linux containers。

## 总控容器已启动，但网页打不开

先检查服务状态与最近日志：

```bash
docker compose --profile host-monitoring ps
docker compose logs --tail 100 server
docker compose logs --tail 100 web
```

再检查 18080 端口是否被占用，以及安全组、防火墙、反向代理目标地址是否正确。只使用宝塔、Caddy 或 Nginx 反代时，可把 Web 绑定地址设置为 `127.0.0.1`，但反向代理必须运行在同一台主机或可访问该地址。

## `/setup` 提交后短暂出现 502

提交向导会写入生产配置并重建 `server` 与 `web`。浏览器连接可能短暂中断。等待健康检查通过后刷新公开状态页。

如果长时间没有恢复，检查：

```bash
docker compose ps
docker compose logs --tail 150 setup
docker compose logs --tail 150 server
```

不要重复提交向导。先确认上一次任务是否仍在运行或已经给出明确失败原因。

## 登录后立即退出、返回 403 或 WebSocket 断开

确认以下值使用同一个正式 HTTPS 来源：

```dotenv
SESSION_COOKIE_SECURE=true
PUBLIC_BASE_URL=https://monitor.example.com
ALLOWED_ORIGINS=https://monitor.example.com
```

反向代理还需要透传 `Host`、`X-Forwarded-Host`、`X-Forwarded-For`、`X-Forwarded-Proto`，并为 `/ws/` 开启 WebSocket Upgrade。

常见错误包括：

- 一个地址使用 `http`，另一个使用 `https`。
- 域名、端口或末尾路径不一致。
- CDN 没有启用 WebSocket。
- 浏览器阻止同站 Cookie。

## 设备一直“待接入”或突然离线

在设备详情先查看“Agent 接入诊断”和最近上报时间，然后在目标机检查服务。

Linux：

```bash
/opt/xingchen/agent/agent.sh status
/opt/xingchen/agent/agent.sh logs
```

Windows：

```powershell
Get-Service XingchenAgent
Get-WinEvent -LogName Application -MaxEvents 50
```

逐项核对：

1. Agent 配置中的总控地址能访问 `/healthz`。
2. 设备 ID 与控制台中的设备一致。
3. 密钥没有被轮换，也没有复制缺失。
4. 目标机系统时间、DNS 和证书链正常。
5. 防火墙允许 Agent 主动访问总控 HTTPS 入口。

离线缓冲会保存在 spool 目录，网络恢复后自动补传。不要因为短暂断线立即删除设备。

## 设备在线，但缺少进程、容器或磁盘数据

- 进程与连接可能被轻量采集参数关闭，检查 `--skip-processes`、`--skip-connections`。
- Docker 容器信息需要访问 Docker socket，确认 Agent 的运行方式和权限。
- 指定磁盘白名单时，只会上报列出的挂载点。
- SMART/NVMe 健康需要目标机安装 `smartctl` 并提供相应设备权限。
- Windows Docker Desktop 不能代表 Windows 宿主机，Windows 应使用原生 Agent 服务。

修改采集参数后重启 Agent，并等待至少两个采集周期再判断。

## 告警触发了，但没有收到通知

按以下顺序检查：

1. 告警事件的通知列是否显示被维护窗口静默。
2. 系统设置中的渠道测试是否成功。
3. 通知投递记录中的失败原因与重试次数。
4. 邮件、钉钉、企业微信或 Webhook 的凭据是否仍有效。
5. 规则范围是否覆盖目标设备，设备权限是否允许当前用户处理事件。

“确认告警”只表示有人接手，不代表故障恢复。恢复状态由后续指标或探测结果决定。

## 旧版没有 bootstrap，如何升级到 v1.20.19

`v1.20.18` 及更早版本的 Setup 不含新版在线引导器和更新包，不能仅凭旧控制台有“检查更新”按钮就认定新链路可用。已有部署应按[旧版一次性迁移](./deployment.md#旧版一次性迁移)取得固定 `v1.20.19` 且通过可信 SHA256 校验的入口，再更新既有目录；不要重新安装、执行 `main` 分支脚本或手工改写敏感 `.env`。

没有 `.git` 的旧离线部署也能迁移。显式使用 `--source gitee --version v1.20.19` 会在校验与备份通过后切到 Gitee 版本发现和腾讯云六镜像，并保留数据库与设备配置。迁移成功后优先使用控制台“系统设置 → 系统更新”或 `sudo xingchen update`。

## 使用 Gitee 为什么还要访问腾讯云

Gitee 用于取得固定版本脚本和发现稳定标签，实际运行的 setup、server、web、agent、PostgreSQL、Redis 六个镜像来自 `ccr.ccs.tencentyun.com/xc_monitor`。这种模式仍然联网，需要 Gitee、TCR 及必要的系统包源可达；目标机不需要访问 GitHub、GHCR 或 Docker Hub。完全断网应使用[已校验的离线 bundle](./deployment.md#内部源与完全离线安装)。

普通更新沿用现有来源和网络策略，不会自动把 `internal/offline` 改成在线。只有管理员明确指定 `--source gitee|github` 才执行在线切源。未指定版本的 Gitee 版本发现需要 Git，但部署目录不需要 `.git`。

## 提示已有更新任务或遗留快照怎么办

退出码 `75` 表示更新锁正被其他进程持有。先看控制台任务、`docker ps --filter name=xingchen-controller-update-run` 和 `docker compose logs --tail 100 setup`，不要连续点击更新，也不要删除 `.controller-update.lock` 强行绕过互斥；锁文件存在本身不代表任务仍在运行。

`.controller-update-snapshot.*` 表示可能存在未完成事务。先保留快照、SQL 备份和旧镜像，核对当前容器与失败日志，再按[恢复边界](./deployment.md#更新失败与恢复边界)处理。删除快照或执行 `docker compose down -v` 不会恢复故障，反而可能丢失恢复依据或数据库卷。

## 磁盘还剩 1 GiB，为什么更新备份仍会失败

1 GiB 是最低预检门槛，不是完整空间预算。管理器更新在 PostgreSQL 容器内生成 SQL，再复制到项目 `backups/`，复制期间两份完整 SQL 会同时占用空间；还要容纳候选镜像、旧镜像和数据库持续写入。控制台备份虽然流式写入，也需要足够的完整 SQL 空间。

按[升级前的磁盘预算](./deployment.md#升级前的磁盘预算)分别检查项目与 Docker 数据目录所在磁盘，扩容或转存已验证的历史备份后重试。不要通过下调预检门槛、删除本次备份或清理数据库卷强行继续。

## 更新失败会自动回滚吗

新版在线更新会在候选服务健康检查失败时尝试恢复原 `.env`、Compose、受管脚本和实际运行过的旧镜像，再次检查健康。退出码 `10` 表示旧部署已恢复并通过健康检查；`11` 表示自动恢复失败，需要人工处理并保留快照。

两种情况都不会自动回滚 PostgreSQL。Flyway 迁移向前执行，旧镜像不一定兼容升级后的表结构，因此镜像恢复成功不等于数据库已安全降级；生产降级必须同时确认数据库与镜像兼容性。

升级前请创建 PostgreSQL 备份，并独立保存 `.env` 和 `SETTINGS_ENCRYPTION_KEY`。需要恢复时，优先使用升级前的同一组备份与镜像版本。

## 仍然无法定位

收集以下不含秘密的信息后再提交 Issue：

- 操作系统与 CPU 架构。
- 项目版本或 Git 提交号。
- Docker Engine 与 Compose 版本。
- 相关容器状态。
- 已脱敏的错误日志和复现步骤。

查看[完整新手指南](./user-guide.md)、[部署与运维](./deployment.md)和[系统架构](./architecture.md)可以获得更完整的参数说明。
