# 观澜监控

观澜监控是一套私有化部署的服务器监控系统。本仓库包含 Go Agent、Spring Boot 服务端、Vue 3 Web 控制台以及 Docker 部署配置，不包含鸿蒙 APP。

## 能力范围

- Linux/Windows Agent 采集 CPU、内存、磁盘、网络、进程、温度和自定义服务状态；Linux 可选读取 Docker socket 展示容器资源。
- Agent 断线磁盘缓冲、自动重试、可配置采集周期、磁盘白名单与轻量采集模式。
- 设备密钥接入、实时指标、历史趋势、离线检测、阈值告警和告警确认。
- 邮件、钉钉和企业微信机器人通知，支持环境回退与 AES-256-GCM 加密的在线配置。
- 告警规则支持 CPU、内存、磁盘、TCP 连接数和设备离线阈值。
- 基于会话 Cookie 的用户认证、ADMIN/OPERATOR/VIEWER 权限和操作审计。
- 当前用户可自助修改显示名和密码，修改密码必须校验当前密码并轮换会话 ID。
- 响应式 Web 控制台、WebSocket 实时更新、浅色/深色模式和减少动态效果适配。
- HTTP GET、ICMP Ping、TCPing 服务监控，支持最近结果留存、排序、公开可见性和立即探测。
- HTTPS 服务监控会记录叶子证书到期时间，并可按剩余天数告警；所有服务监控支持连续失败和延迟阈值告警，并在异常进入/恢复时发送通知。
- 无需登录的根路径 `/` 公开状态页（`/status` 保留兼容），展示服务器在线摘要、资源负载、实时吞吐与服务可用性。
- API Token 支持哈希存储、过期、吊销、scope 和服务器白名单，可供移动端与自动化脚本安全访问。
- Agent 任务支持受控的一次性命令下发、超时/输出限制、取消、结果回传和审计；Agent 默认关闭命令执行，需显式配置开启。
- 可选 MCP HTTP 入口支持 API Token 驱动的服务器查询和任务下发，默认关闭。
- DDNS 配置支持 Webhook、IPv4/IPv6、重试、设备关联和 IP 变化自动更新，凭据加密存储。

## 快速启动

总终端只需要 Docker Engine 和 Compose v2。安装器默认先从国内镜像源拉取预构建的总控 `setup`、`server` 和 `web` 镜像，失败后回退到官方 GHCR，并自动启动受 Docker 内网保护的 PostgreSQL 16 与 Redis；数据库端口不会暴露到公网。只有需要离线或本地验证时才使用 `--build` 从源码构建。

```bash
git clone https://github.com/Pstarchen/monitor-for-server.git
cd monitor-for-server
bash ./deploy/install-controller.sh
```

需要自动更新总控时可在首次安装添加 `--auto-update`。日常可用 `deploy/update-controller.sh --check` 检查镜像、`--apply` 手动更新；更新器先尝试配置的国内镜像源，再回退 GHCR。网络环境可以访问官方源时可显式添加 `--no-mirror` 跳过镜像源。

使用本地源码构建总控镜像：

```bash
bash ./deploy/install-controller.sh --build
```

安装器会自动生成 PostgreSQL 数据库凭据并等待 Web 健康检查，然后打开 `http://<服务器IP>:18080/setup`。向导只收集站点名称、公网入口、允许来源、时区和首个管理员；端口与绑定地址在总终端启动时确定。提交后页面进入公开状态页，完成服务启动后再从状态页进入登录控制台。

无需填写数据库地址、数据库名或密码，也不需要执行 SQL。端口和绑定地址请在总终端安装器或 `.env` 首次启动前确定，不要在浏览器向导中改它们。生产环境请使用 HTTPS，并让 `PUBLIC_BASE_URL` 与 `ALLOWED_ORIGINS` 使用同一站点来源。

升级或清理本项目旧镜像时可显式运行：

```bash
bash ./deploy/install-controller.sh --cleanup
```

该选项不会删除 PostgreSQL/Redis 数据卷或其他 Compose 项目。

需要先构建并启动总终端、再通过浏览器完成配置时，可使用对应平台安装器：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\install-controller.ps1
```

Linux：

```bash
bash ./deploy/install-controller.sh
```

4. Linux 总终端会自动显示为“总控服务器”，并在生产服务就绪后开始上报主机指标。
5. 其他服务器仍在“设备管理”中创建设备，再按 [Agent 安装说明](docs/deployment.md) 启动 Agent。

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

- [系统架构与安全边界](docs/architecture.md)
- [HTTP 与 WebSocket API](docs/api.md)
- [部署、Agent 安装与故障排查](docs/deployment.md)
- [总终端服务器搭建材料](docs/controller-server.md)
- [受监控服务器搭建材料](docs/monitored-agent.md)
- [生产审计与使用检查](docs/production-audit.md)
