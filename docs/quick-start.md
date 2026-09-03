---
title: 5 分钟快速安装
description: 安装星辰监控总控，完成首次配置并接入第一台服务器。
---

# 5 分钟快速安装

本页给出最短且完整的上线路径。它适合首次体验或新建环境。生产环境完成后，还应继续阅读[部署与运维](./deployment.md)和[生产审计与使用检查](./production-audit.md)。

## 你将部署什么

总控服务器使用 Docker Compose 运行 Web、服务端、安装服务、PostgreSQL、Redis 和可选的总控 Agent。被监控服务器只需安装轻量 Agent，并由 Agent 主动连接总控。

| 角色 | 最低准备 | 对外端口 |
| --- | --- | --- |
| 总控服务器 | 64 位 Linux、Docker Engine 24+、Compose v2 | 80/443，初始化时可临时使用 18080 |
| 被监控服务器 | Linux 或 Windows，具备安装服务的管理员权限 | 通常无需开放入站端口 |

::: warning 生产环境要求
请准备域名和有效 HTTPS 证书。PostgreSQL、Redis 与 Spring Boot 端口不应直接暴露到公网。
:::

## 安装总控

### Linux

目标服务器无法访问 GitHub 时从 Gitee 获取：

```bash
git clone https://gitee.com/starchen520/monitor-for-server.git xingchen-monitor
cd xingchen-monitor
sudo bash ./deploy/install-controller.sh
```

能够访问 GitHub 时也可使用：

```bash
git clone https://github.com/Pstarchen/monitor-for-server.git xingchen-monitor
cd xingchen-monitor
sudo bash ./deploy/install-controller.sh
```

安装器会检查 Docker，生成数据库凭据，准备镜像并等待 Web 健康检查通过。它不会把数据库密码打印到日志。

无法访问 GHCR 时，先在 `.env` 或进程环境中把全部 `XINGCHEN_*_IMAGE` 指向内部 Registry；完全断网时使用 Release 提供的架构对应离线 bundle，校验 `.sha256` 后执行包内 `install-offline.sh`。

### Windows

Windows 更适合本机体验或测试。先启动 Docker Desktop，并切换到 Linux containers，然后在项目目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\install-controller.ps1
```

若 Docker Desktop 未运行，安装器会在前置检查阶段停止，不会写入半成品配置。

## 完成首次配置

安装完成后打开：

```text
http://<总控服务器IP>:18080/setup
```

向导只需要以下信息：

| 字段 | 填写建议 |
| --- | --- |
| 站点名称 | 浏览器、控制台和通知中显示的名称 |
| 公网入口 | 用户与 Agent 实际访问的完整 URL |
| 允许的 Web 来源 | 至少包含公网入口，多个来源用逗号分隔 |
| 服务时区 | 使用 IANA 名称，例如 `Asia/Shanghai` |
| 管理员账号 | 使用独立用户名和高强度密码 |

提交向导后，安装服务会重建 Web 与服务端。短暂出现连接中断属于正常重启过程，健康检查通过后会进入公开状态页。

::: tip 先用 IP，稍后切换域名
初始化时可以使用 `http://<IP>:18080`。正式域名与 TLS 生效后，在系统设置同步修改公网入口，再让 `PUBLIC_BASE_URL`、`ALLOWED_ORIGINS` 使用同一个 HTTPS 来源。
:::

## 完成首次安全检查

登录控制台后，按以下顺序操作：

1. 打开“备份与恢复”，创建第一个 PostgreSQL 备份。
2. 打开“系统设置”，配置并测试至少一种通知渠道。
3. 在个人资料中启用 TOTP 双因素认证。
4. 检查公开状态页是否只展示允许公开的设备与服务。

## 接入第一台服务器

1. 打开“设备管理”，点击“添加设备”。
2. 填写设备名称、分组和资产信息。
3. 保存后立即复制设备 ID，并单独保存只显示一次的长期 Agent 密钥；安装命令本身不包含密钥。
4. 在目标服务器运行控制台生成的命令。
5. 等待设备状态从“待接入”变为“在线”。

Agent 密钥明文只显示一次。关闭弹窗后无法找回，只能由管理员轮换。不要把密钥发送到聊天群、工单或截图中。

Linux Agent 安装完成后可检查：

```bash
/opt/xingchen/agent/agent.sh status
/opt/xingchen/agent/agent.sh logs
```

Windows Agent 安装完成后可检查：

```powershell
Get-Service XingchenAgent
```

## 配置第一组监控

确认设备已有 CPU、内存和磁盘数据后，再继续：

1. 创建 CPU、内存、磁盘和离线告警规则。
2. 创建一个 HTTP 或 Ping 服务探测并执行“立即探测”。
3. 用可控的阈值变化验证告警打开、通知发送和恢复流程。
4. 为发布与维护创建静默窗口，确认静默期间仍记录事件。

## 上线完成标准

- 总控页面通过 HTTPS 访问，WebSocket 保持连接。
- 总控宿主机和至少一台被监控服务器持续在线。
- 资源趋势包含多个采集点，数据时间持续更新。
- 服务探测可以成功执行，也能展示失败原因。
- 测试告警完成打开、通知、确认与恢复闭环。
- 已创建可恢复的数据库备份，并妥善保存 `.env` 与 `SETTINGS_ENCRYPTION_KEY`。

遇到问题时，从[常见问题](./faq.md)按现象定位；需要完整参数与升级策略时，继续阅读[部署与运维](./deployment.md)。
