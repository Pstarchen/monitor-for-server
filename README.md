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

1. 准备 Docker Engine、Compose v2，以及用户自行维护的外部 MySQL 8.0+。项目不携带 MySQL 容器；请先在 MySQL 管理端创建目标数据库和应用账号，安装向导只会用你填写的账号连接目标库并初始化监控表结构。

```powershell
docker compose up --build -d
```

2. 先在外部 MySQL 中创建数据库和应用账号，再打开 `http://<服务器IP>:18080/setup`。首次运行向导第一步要求填写实际可达的 MySQL 地址、端口、数据库名、用户名和密码；向导直接检测目标库并初始化表结构，随后设置站点入口和首个管理员。

3. 向导完成后服务会自动切换到生产配置，再使用刚创建的管理员登录。

需要先构建并启动总终端、再通过浏览器完成配置时，可使用对应平台安装器：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\install-controller.ps1
```

Linux：

```bash
bash ./deploy/install-controller.sh
```

4. 在“设备管理”中创建设备并保存一次性显示的 Agent 密钥。
5. 按 [Agent 安装说明](docs/deployment.md) 在被监控服务器启动 Agent。

## 本地校验

```powershell
Push-Location agent; go test ./...; Pop-Location
Push-Location setup; go test ./...; Pop-Location
pnpm --dir web install
pnpm --dir web test
pnpm --dir web build
docker compose build setup server web
```

## 项目文档

- [系统架构与安全边界](docs/architecture.md)
- [HTTP 与 WebSocket API](docs/api.md)
- [部署、Agent 安装与故障排查](docs/deployment.md)
- [总终端服务器搭建材料](docs/controller-server.md)
- [受监控服务器搭建材料](docs/monitored-agent.md)
- [生产审计与使用检查](docs/production-audit.md)
