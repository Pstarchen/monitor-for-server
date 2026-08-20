# HTTP 与 WebSocket API

默认路径前缀为 `/api`。浏览器接口返回 JSON，并使用 Spring Security 会话 Cookie；Agent 接口使用独立请求头。时间字段均为 ISO 8601 UTC 时间。

## 认证约定

1. 浏览器先调用 `GET /api/auth/csrf`，Axios 会从 `XSRF-TOKEN` Cookie 读取值并在写请求中发送 `X-XSRF-TOKEN`。
2. 调用 `POST /api/auth/login` 建立会话。认证失败只返回通用错误，连续失败会触发限流。
3. 后续请求携带会话 Cookie。退出使用 `POST /api/auth/logout`。
4. Agent 调用上报接口时发送 `X-Device-Id` 和 `X-Agent-Key`。不要把 Agent 密钥放入 URL、日志或 Web 前端。

错误响应格式：

```json
{
  "message": "可读的错误说明"
}
```

## 认证接口

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/auth/csrf` | 公开 | 初始化 CSRF Cookie |
| POST | `/api/auth/login` | 公开 | 用户名、密码、可选本地 `returnTo` |
| GET | `/api/auth/me` | 登录 | 当前用户资料 |
| POST | `/api/auth/logout` | 登录 | 注销并清除会话 |

登录请求：

```json
{
  "username": "admin",
  "password": "通过安全输入提供",
  "returnTo": "/dashboard"
}
```

## 设备与指标

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/devices` | 登录 | 设备及最新指标列表 |
| GET | `/api/devices/{id}` | 登录 | 单台设备详情 |
| POST | `/api/devices` | ADMIN / OPERATOR | 创建设备并一次性返回 Agent 密钥 |
| PUT | `/api/devices/{id}` | ADMIN / OPERATOR | 更新名称、位置、分组和主 IP |
| POST | `/api/devices/{id}/rotate-key` | ADMIN | 轮换并一次性返回新密钥 |
| DELETE | `/api/devices/{id}` | ADMIN | 删除设备及关联数据 |
| GET | `/api/devices/{id}/metrics/latest` | 登录 | 最新指标 |
| GET | `/api/devices/{id}/metrics/history` | 登录 | `from` 到 `to` 的历史指标，最大 31 天 |

创建设备请求：

```json
{
  "name": "生产 API-01",
  "location": "上海机房 A3",
  "groupName": "生产环境",
  "primaryIp": "10.20.1.15"
}
```

创建和轮换密钥的响应包含 `{ "device": { ... }, "agentKey": "..." }`。`agentKey` 不会再次返回。

Agent 上报：

```http
POST /api/agent/v1/reports
X-Device-Id: <device-id>
X-Agent-Key: <agent-key>
Content-Type: application/json
```

请求体包含 `collectedAt`、`host`、`cpu`、`memory`、`disks`、`network`、`processes` 与 `services`。成功返回 `202 Accepted` 和归一化后的指标快照，并返回 `X-Agent-Interval-Seconds` 响应头。Agent 会在下一次成功上报后应用总控设置的周期；网络中断时继续使用本地周期。

## 告警

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/alerts?limit=100` | 登录 | 最近告警事件，最大 500 条 |
| POST | `/api/alerts/{id}/acknowledge` | ADMIN / OPERATOR | 确认待处理告警 |
| GET | `/api/alert-rules` | 登录 | 告警规则列表 |
| POST | `/api/alert-rules` | ADMIN / OPERATOR | 创建规则 |
| PUT | `/api/alert-rules/{id}` | ADMIN / OPERATOR | 更新规则 |
| DELETE | `/api/alert-rules/{id}` | ADMIN / OPERATOR | 无历史事件时删除，否则停用 |

规则请求：

```json
{
  "name": "生产节点 CPU 过高",
  "deviceId": null,
  "metric": "CPU_USAGE",
  "threshold": 85,
  "severity": "WARNING",
  "enabled": true
}
```

`metric` 可取 `CPU_USAGE`、`MEMORY_USAGE`、`DISK_USAGE`、`DEVICE_OFFLINE`。前三项阈值单位为百分比，离线阈值单位为秒。

## 总览与管理

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/dashboard` | 登录 | 设备、告警和资源均值汇总 |
| GET | `/api/settings` | ADMIN | 非敏感系统设置及通知通道配置状态 |
| GET | `/api/settings/agent-bootstrap` | ADMIN / OPERATOR | Agent 公网入口与当前上报周期 |
| PUT | `/api/settings` | ADMIN | 更新系统设置与通知通道；敏感字段仅接受替换值 |
| POST | `/api/settings/notifications/{channel}/test` | ADMIN | 测试 `email`、`dingtalk` 或 `wecom` 通道 |
| GET | `/api/admin/users` | ADMIN | 账号列表 |
| POST | `/api/admin/users` | ADMIN | 创建账号，密码至少 12 位 |
| PUT | `/api/admin/users/{id}` | ADMIN | 更新名称、角色、状态和可选新密码 |
| GET | `/api/admin/audit-logs?limit=100` | ADMIN | 最近审计记录，最大 200 条 |
| GET | `/actuator/health` | 公开 | 服务健康状态 |

系统设置请求：

```json
{
  "metricRetentionDays": 30,
  "deviceOfflineAfterSeconds": 30,
  "defaultCollectionSeconds": 3,
  "siteName": "观澜监控",
  "publicBaseUrl": "https://monitor.example.com",
  "timezone": "Asia/Shanghai",
  "email": {
    "enabled": false,
    "host": "",
    "port": 587,
    "username": "",
    "password": null,
    "clearPassword": false,
    "from": "",
    "recipients": "",
    "auth": true,
    "startTls": true
  },
  "dingtalk": { "enabled": false, "webhookUrl": null, "clearWebhook": false },
  "wecom": { "enabled": false, "webhookUrl": null, "clearWebhook": false }
}
```

敏感值使用 `null` 或空字符串表示保留当前值，`clearPassword` / `clearWebhook` 用于删除数据库覆盖值。响应只包含 `configured`、`source` 等状态字段。

## WebSocket

已登录浏览器连接 `/ws/metrics`。网关必须转发 Upgrade 与 Connection 请求头。

```json
{
  "type": "metric.updated",
  "payload": {
    "deviceId": "...",
    "collectedAt": "2026-08-17T12:00:00Z"
  }
}
```

事件类型：

- `metric.updated`：设备新指标已写入。
- `alert.opened`：规则首次越限并生成告警。
- `alert.resolved`：指标恢复或离线设备重新上报。

WebSocket 是刷新提示通道，REST 与数据库始终是权威数据源。
