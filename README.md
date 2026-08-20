# 观澜监控

观澜监控是一套私有化部署的服务器监控系统。本仓库包含 Go Agent、Spring Boot 服务端、Vue 3 Web 控制台以及 Docker 部署配置，不包含鸿蒙 APP。

## 能力范围

- Linux/Windows Agent 采集 CPU、内存、磁盘、网络、进程、温度和自定义服务状态。
- Agent 断线磁盘缓冲、自动重试、可配置采集周期、磁盘白名单与轻量采集模式。
- 设备密钥接入、实时指标、历史趋势、离线检测、阈值告警和告警确认。
- 邮件、钉钉和企业微信机器人通知，支持环境回退与 AES-256-GCM 加密的在线配置。
- 基于会话 Cookie 的用户认证、ADMIN/OPERATOR/VIEWER 权限和操作审计。
- 响应式 Web 控制台、WebSocket 实时更新、浅色/深色模式和减少动态效果适配。

## 快速启动

总终端只需要 Docker Engine 和 Compose v2。安装器默认从 GHCR 拉取预构建的总控 `setup`、`server` 和 `web` 镜像，并自动启动受 Docker 内网保护的 PostgreSQL 16 与 Redis；数据库端口不会暴露到公网。只有需要离线或本地验证时才使用 `--build` 从源码构建。

```bash
git clone https://github.com/Pstarchen/monitor-for-server.git
cd monitor-for-server
bash ./deploy/install-controller.sh
```

需要自动更新总控时可在首次安装添加 `--auto-update`。日常可用 `deploy/update-controller.sh --check` 检查镜像、`--apply` 手动更新；更新器先尝试配置的国内镜像源，再回退 GHCR。

使用本地源码构建总控镜像：

```bash
bash ./deploy/install-controller.sh --build
```

安装器会自动生成 PostgreSQL 数据库凭据并等待 Web 健康检查，然后打开 `http://<服务器IP>:18080/setup`。向导只收集站点名称、公网入口、允许来源、时区和首个管理员；端口与绑定地址在总终端启动时确定。提交后页面立即进入登录页，等生产服务就绪后再允许登录。

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
