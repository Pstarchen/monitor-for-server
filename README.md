# 星辰监控

星辰监控是一套私有化部署的服务器监控系统。本仓库包含 Go Agent、Spring Boot 服务端、Vue 3 Web 控制台以及 Docker 部署配置，不包含鸿蒙 APP。

## 配套 HarmonyOS 客户端

配套客户端「星辰云巡」可在 HarmonyOS 设备上查看服务器实时指标、历史趋势、设备诊断、服务可用性和告警动态。部署本项目后，可在 Web 控制台创建 API Token，通过绑定二维码或手动输入地址与 Token 连接客户端。

- [访问星辰监控官网](https://xcmon.xciy.cn/)
- [前往华为应用市场安装星辰云巡](https://appgallery.huawei.com/app/detail?id=cn.xciy.xcyx&channelId=SHARE&source=appshare)
- [查看星辰云巡开源仓库](https://github.com/Pstarchen/xingchenyunxun)

建议从只读权限开始，只授予客户端实际需要的 scope；生产环境应使用 HTTPS。

## 能力范围

- Linux/Windows Agent 采集 CPU、内存、磁盘、网络、进程、监听端口、温度和自定义服务状态；支持额外指定关键进程，即使其不在资源排名前列也会持续保留，也可显式采集带命令行的完整进程清单；Linux 可选读取 Docker socket 展示容器资源，并在具备 `smartctl` 与设备权限时采集磁盘 SMART/NVMe 健康。
- Agent 断线磁盘缓冲、自动重试、可配置采集周期、磁盘白名单与轻量采集模式。
- 设备密钥接入、实时指标、历史趋势、离线检测、阈值告警和告警确认。
- 邮件、钉钉、企业微信和通用 Webhook 通知，支持环境回退与 AES-256-GCM 加密的在线配置；通用 Webhook 可直接对接 Slack、Discord、飞书/Lark 或纯文本端点。
- 独立的华为 Push Kit V3 通道，面向 HarmonyOS NEXT / 5.x+，支持服务账号校验、加密私钥保存、Push Token 设备登记和按设备测试推送；与 Web Push、FCM、APNs、Webhook 及旧版华为 OAuth Push API 区分。
- 告警规则支持 CPU、内存、磁盘、SMART 失败磁盘数、TCP 连接数和设备离线阈值。
- 基于会话 Cookie 的用户认证、ADMIN/OPERATOR/VIEWER 角色、按设备分配的查看/管理/告警/任务权限和操作审计；支持基于 TOTP 的双因素认证，密钥以 AES-256-GCM 密文保存。
- 当前用户可自助修改显示名和密码，修改密码必须校验当前密码并轮换会话 ID。
- 响应式 Web 控制台、WebSocket 实时更新、浅色/深色模式和减少动态效果适配。
- HTTP GET、ICMP Ping、TCPing、Redis PING、PostgreSQL 和 MySQL 协议握手服务监控，支持最近结果留存、排序、公开可见性和立即探测；数据库探测只发送最小协议握手，不需要保存数据库密码。
- HTTP 服务监控支持期望状态码和响应体文本条件，可识别“网络正常但业务已异常”的接口。
- 外部心跳监控，可接收 cron、CI、备份和发布任务的存活信号；连续两个周期未上报会记录失败并触发通知，令牌只在创建时显示一次。
- HTTPS 服务监控会记录叶子证书到期时间，并可按剩余天数告警；所有服务监控支持连续失败和延迟阈值告警，并在异常进入/恢复时发送通知。
- 首页与服务监控控制台以 60 次探测记录展示可用性时间线，并补充平均延迟、P95 延迟、异常次数和响应延迟趋势，刷新倒计时跟随每项监控的实际间隔。
- 设备详情支持从历史快照筛选容器和进程，查看 CPU、内存及容器网络吞吐趋势；容器网络计数器重启后会自动归零，避免产生负速率。
- 运行报告支持 24 小时、7 天和 30 天窗口，汇总节点资源压力、服务可用率、平均延迟和告警活动，并可导出 CSV。
- 通知投递记录保存各通道的成功/失败原因与重试次数，失败消息可在设置页使用最新凭据重试。
- 首页提供资源压力排行，按当前 CPU、内存和磁盘占用最高项定位重点节点，可直接进入设备详情。
- 无需登录的根路径 `/` 公开状态页（`/status` 保留兼容），展示服务器在线摘要、资源负载、实时吞吐与服务可用性。
- API Token 支持哈希存储、过期、吊销、scope 和服务器白名单，并与所属账号的设备权限取交集，可供移动端与自动化脚本安全访问。
- Agent 任务支持受控的一次性命令下发、超时/输出限制、取消、结果回传和审计；Agent 默认关闭命令执行，需显式配置开启。
- Agent 发布支持确定性灰度分组、批次、维护窗口、并发与抖动控制、失败阈值自动暂停和批量回滚；只有任务下发后的实时版本上报才会确认升级成功。
- 可选 MCP HTTP 入口支持 API Token 驱动的服务器查询和任务下发，默认关闭。
- DDNS 配置支持 Webhook、IPv4/IPv6、重试、设备关联和 IP 变化自动更新，凭据加密存储。
- 网络发现支持总控探测 RFC1918 私网 `/24` 到 `/32` 地址、常见端口和响应耗时，任务带进度、取消、审计记录和设备登记入口。
- Agent 首次接入使用 15 分钟有效、只能消费一次的 enrollment token；服务端只保存令牌 SHA-256，长期 Agent 密钥由安装器交换后直接写入受限配置文件，不进入安装命令。

## 快速启动

Linux 总终端在 `public` 模式会按受支持的发行版包管理器补齐 `curl`、Docker Engine 和 Docker Compose v2；已由运维平台准备依赖时可传 `--no-install-dependencies`，让缺失依赖直接报错。`internal` 与 `offline` 不访问公网软件包源：前者要求预装依赖并使用内部 Registry/制品服务，后者只允许已校验 bundle 与本地 Docker image store。安装器提供 `public`、`internal`、`offline` 三种网络模式；`internal` 在代码层拒绝 GitHub、GitHub API、GitHubusercontent、GHCR 和 Docker Hub，Gitee 也必须显式开启。生产环境如果目标服务器不能访问 GitHub，推荐使用 `internal`，并把 setup、server、web、agent、PostgreSQL、Redis 六个镜像和 Agent 制品提前晋级到内部基础设施。

总控保留一键准备和 Docker Compose 编排体验，但不会从代码托管平台的可变 `main` 分支下载后直接执行，也不会用 `latest` 作为升级依据。版本必须固定为稳定 `vX.Y.Z` 或 OCI digest；manifest、摘要或制品校验缺失、失败时立即停止，不降级为未校验安装。GitHub 与 Gitee 示例都先取得完整仓库，再执行仓库内安装器，便于审计和固定版本。

第一次部署建议先阅读[新手使用指南](docs/user-guide.md)。它从 Docker 准备、首次 `/setup`、Agent 接入一直讲到告警、通知、备份、更新和常见问题排查。

无法访问 GitHub/GHCR 时从 Gitee 固定版本本地构建：
```bash
git clone --depth 1 --branch v1.20.16 https://gitee.com/starchen520/monitor-for-server.git xingchen-monitor && cd xingchen-monitor && sudo bash ./deploy/install-controller.sh --build
```

能够访问 GitHub 时也可使用：

```bash
git clone --depth 1 --branch v1.20.16 https://github.com/Pstarchen/monitor-for-server.git xingchen-monitor && cd xingchen-monitor && sudo bash ./deploy/install-controller.sh
```

需要自动更新总控时可在首次安装添加 `--auto-update`。日常可用 `deploy/update-controller.sh --check` 检查稳定版本、`--apply` 手动更新；普通 `--apply` 在切换 Compose 服务前必须先创建 PostgreSQL 备份，备份失败则不切换。自动更新只在同一主版本内前进，连续 3 次失败会暂停 24 小时，跨主版本或熔断期间仍可人工评估后手动执行。`public` 模式先尝试 `XINGCHEN_CONTROLLER_IMAGE_MIRRORS` 和固定版本的官方 GHCR 镜像；源码回退默认关闭，只有显式配置 `XINGCHEN_SOURCE_REPOSITORIES` 才会启用，GitHub API 与 GitHub 源码不会被隐式访问。无法访问 GitHub/GHCR 的服务器应使用 `internal` 或 `offline` 模式。

使用本地源码构建总控镜像：

```bash
bash ./deploy/install-controller.sh --build
```

目标服务器无法访问 GitHub/GHCR 时，将 `XINGCHEN_SETUP_IMAGE`、`XINGCHEN_SERVER_IMAGE`、`XINGCHEN_WEB_IMAGE`、`XINGCHEN_AGENT_IMAGE`、`XINGCHEN_POSTGRES_IMAGE` 和 `XINGCHEN_REDIS_IMAGE` 指向内部 Registry 的不可变 digest，通过 `XINGCHEN_RELEASE_MANIFEST_URLS`、`XINGCHEN_AGENT_RELEASE_BASE_URLS` 指向内部 HTTPS 制品服务，并设置 `XINGCHEN_NETWORK_MODE=internal`、`XINGCHEN_ALLOW_GITEE=false`、`XINGCHEN_CONTROLLER_ALLOW_GITHUB_API=false`。联网发布机可使用 `deploy/promote-internal-release.ps1` 按源 digest 晋级镜像并生成内部 manifest/lock；脚本不接收 Registry 凭据。稳定版 Setup 镜像还内置同版本的四个平台 Agent 制品作为末级本地基线；Agent 默认从总控同域取得受校验制品，目标节点不访问代码托管平台。

完全断网环境在联网发布机取得 `xingchen-monitor-offline-vX.Y.Z-<架构>.tar.gz` 与同名 `.sha256`，通过受控介质传入目标机。新装执行包内 `install-offline.sh` 或 `install-offline.ps1`；已有部署必须执行 `upgrade-offline.sh --project-root <绝对部署目录> --check` 后再使用 `--apply`，以保留原 `.env`、Compose 项目、端口和数据卷，并在切换前备份 PostgreSQL。不要用新装入口覆盖存量部署。

安装器会自动生成 PostgreSQL 数据库凭据并等待 Web 健康检查，然后打开 `http://<服务器IP>:18080/setup`。向导只收集站点名称、公网入口、允许来源、时区和首个管理员；端口与绑定地址在总终端启动时确定。提交后页面进入公开状态页，完成服务启动后再从状态页进入登录控制台。

无需填写数据库地址、数据库名或密码，也不需要执行 SQL。端口和绑定地址请在总终端安装器或 `.env` 首次启动前确定，不要在浏览器向导中改它们。生产环境请使用 HTTPS，并让 `PUBLIC_BASE_URL` 与 `ALLOWED_ORIGINS` 使用同一站点来源。

升级或清理本项目旧镜像时可显式运行：

```bash
bash ./deploy/install-controller.sh --cleanup
```

该选项不会删除 PostgreSQL/Redis 数据卷或其他 Compose 项目。

Windows 可使用对应平台安装器，再通过浏览器完成配置：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\install-controller.ps1
```

安装完成后：

1. 打开 `http://<服务器IP>:18080/setup`，设置公网入口、来源、时区和首个管理员。
2. Linux 总终端会自动显示为“总控服务器”，并在生产服务就绪后开始上报主机指标。
3. 其他服务器在“设备管理”中创建设备，运行页面生成的 Controller 同域短命令；bootstrap 校验完整安装器的 SHA256 后才执行，并由安装器隐藏读取一次性接入令牌。
4. 按[新手使用指南](docs/user-guide.md)完成通知测试、告警规则、备份和更新设置。

## 本地校验

```powershell
Push-Location agent; go test ./...; Pop-Location
Push-Location setup; go test ./...; Pop-Location
pnpm --dir web install
pnpm --dir web test
pnpm --dir web build
docker compose build setup server web postgres
```

## 项目文档

- [项目官网与在线 Wiki](docs/index.md)
- [5 分钟快速安装](docs/quick-start.md)
- [新手使用指南：从安装到日常使用](docs/user-guide.md)
- [系统架构与安全边界](docs/architecture.md)
- [HTTP 与 WebSocket API](docs/api.md)
- [华为 HarmonyOS Push Kit V3 接入](docs/huawei-push-kit.md)
- [部署、Agent 安装与故障排查](docs/deployment.md)
- [总终端服务器搭建材料](docs/controller-server.md)
- [受监控服务器搭建材料](docs/monitored-agent.md)
- [生产审计与使用检查](docs/production-audit.md)
- [让 AI 审计和优化安装、更新体系](docs/installation-update-ai-prompt.md)

### 本地运行官网与 Wiki

```powershell
pnpm --dir docs install
pnpm --dir docs dev
```

生产构建：

```powershell
pnpm --dir docs build
```
