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

1. 将 `.env.example` 复制为 `.env`，为数据库、管理员和设置加密密钥生成互不相同的强随机值。
2. 构建并启动服务：

```powershell
docker compose up --build -d
```

3. 打开 `http://localhost:8080`，使用 `.env` 中设置的管理员账号登录。
4. 在“设备管理”中创建设备并保存一次性显示的 Agent 密钥。
5. 按 [Agent 安装说明](docs/deployment.md) 在被监控服务器启动 Agent。

## 本地校验

```powershell
go test ./...
pnpm --dir web install
pnpm --dir web test
pnpm --dir web build
docker compose build server web
```

## 项目文档

- [系统架构与安全边界](docs/architecture.md)
- [HTTP 与 WebSocket API](docs/api.md)
- [部署、Agent 安装与故障排查](docs/deployment.md)
- [总终端服务器搭建材料](docs/controller-server.md)
- [受监控服务器搭建材料](docs/monitored-agent.md)
- [生产审计与使用检查](docs/production-audit.md)
