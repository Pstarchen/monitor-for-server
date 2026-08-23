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
| PUT | `/api/auth/profile` | 登录 | 修改当前用户显示名；修改密码时必须同时提供当前密码和新密码 |
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

## 公开品牌

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/settings/public` | 公开 | 返回站点名称和网站图标地址 |
| GET | `/api/settings/site-icon` | 公开 | 返回已上传的网站图标文件 |
| POST | `/api/settings/site-icon` | ADMIN | 上传图片网站图标，文件大小不超过 50MB |

Agent 上报：

```http
POST /api/agent/v1/reports
X-Device-Id: <device-id>
X-Agent-Key: <agent-key>
Content-Type: application/json
```

请求体包含 `collectedAt`、`host`、`cpu`、`memory`、`disks`、`network`、`processes` 与 `services`。成功返回 `202 Accepted` 和归一化后的指标快照，并返回 `X-Agent-Interval-Seconds` 响应头。Agent 会在下一次成功上报后应用总控设置的周期；网络中断时继续使用本地周期。

## Agent 任务

任务用于向受控 Agent 下发非交互的一次性命令。Agent 配置中的 `allow_command_execution` 默认是 `false`，只有显式开启后才会轮询任务并执行；命令按可执行文件和参数直接启动，不经过 Shell。安装器可使用 `--allow-command-execution`（Windows 为 `-AllowCommandExecution`）写入此开关。服务端限制命令参数数量、超时时间（1-300 秒）和 stdout/stderr 大小（1KiB-1MiB），任务创建、取消和结果都会写入审计日志。

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/tasks?deviceId=&limit=50` | 登录 / PAT `nezha:server:read` | 查看任务及结果；PAT 受服务器白名单约束 |
| POST | `/api/tasks` | ADMIN / OPERATOR / PAT `nezha:server:exec` | 创建任务 |
| GET | `/api/tasks/{id}` | 登录 / PAT `nezha:server:read` | 查看单个任务 |
| POST | `/api/tasks/{id}/cancel` | ADMIN / OPERATOR / PAT `nezha:server:exec` | 取消排队或执行中的任务 |
| GET | `/api/agent/v1/tasks/next` | Agent 设备密钥 | Agent 领取一个排队任务；无任务返回 `204` |
| POST | `/api/agent/v1/tasks/{id}/result` | Agent 设备密钥 | 回传 `SUCCEEDED`、`FAILED` 或 `TIMED_OUT` 结果 |

创建请求示例：

```json
{"deviceId":"device-uuid","command":"uname","args":["-a"],"timeoutSeconds":30,"maxOutputBytes":65536}
```

Agent 端配置：

```json
{"allow_command_execution":false,"allow_file_operations":false,"command_poll_interval":"1s","max_command_output_bytes":65536}
```

生产环境只应对明确授权的设备开启命令执行，并为 PAT 设置服务器 ID 白名单和最小 scope。

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
| GET | `/api/admin/controller-update` | ADMIN | 查看总控构建版本、服务健康状态和更新策略 |
| POST | `/api/admin/controller-update/check` | ADMIN | 从配置的镜像源检查总控更新 |
| POST | `/api/admin/controller-update/apply` | ADMIN | 异步更新并重启总控服务 |
| PUT | `/api/admin/controller-update/auto` | ADMIN | 启用或关闭每日 04:00 自动更新 |
| POST | `/api/settings/notifications/{channel}/test` | ADMIN | 测试 `email`、`dingtalk` 或 `wecom` 通道 |
| GET | `/api/admin/users` | ADMIN | 账号列表 |
| POST | `/api/admin/users` | ADMIN | 创建账号，密码至少 12 位 |
| PUT | `/api/admin/users/{id}` | ADMIN | 更新名称、角色、状态和可选新密码 |
| GET | `/api/admin/audit-logs?limit=100` | ADMIN | 最近审计记录，最大 200 条 |
| GET | `/actuator/health` | 公开 | 服务健康状态 |

### API Token

登录会话可在 `/api/api-tokens` 创建和吊销个人 API Token。明文只在创建响应中返回一次，服务端只保存 SHA-256 哈希；PAT 使用 `Authorization: Bearer nzp_...` 调用接口，并且同时受用户角色、scope 和服务器 ID 白名单约束。

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/api-tokens` | 登录会话 | 查看当前用户的 Token 元信息，不返回明文 |
| POST | `/api/api-tokens` | 登录会话 | 创建 Token，支持 `scopes`、`serverIds`、`expiresInDays` |
| DELETE | `/api/api-tokens/{id}` | 登录会话 | 吊销当前用户的 Token |

创建请求示例：

```json
{
  "name": "mobile-readonly",
  "scopes": ["nezha:inventory:read", "nezha:server:read"],
  "serverIds": [],
  "expiresInDays": 90
}
```

常用 scope 为 `nezha:inventory:read`（设备清单）、`nezha:server:read`（设备指标）、`nezha:service:read`（服务监控）、`nezha:alert:read`（告警读取）和对应的 `write` / `delete` / `exec` 权限。`nezha:admin:*` 与 `nezha:*` 仅管理员可以签发。

### MCP HTTP

MCP 默认关闭。设置 `ENABLE_MCP=true` 并重启服务后，使用 `Authorization: Bearer nzp_...` 向 `POST /mcp` 发送 Streamable HTTP JSON-RPC 请求；网页登录会话不会被接受。当前入口支持 `initialize`、`notifications/initialized`、`ping`、`tools/list`，以及 `meta.whoami`、`server.list`、`server.get`、`server.exec`、`fs.list`、`fs.read`、`fs.write`、`fs.delete` 工具。命令和文件操作会复用任务队列，返回任务 ID；MCP 会短暂等待快速完成的任务，超时仍返回任务状态，之后可通过任务 API 查询输出。

MCP 工具继续受 Token scope 和服务器 ID 白名单约束。`server.exec` 需要 `nezha:server:exec`，`fs.list` / `fs.read` 需要 `nezha:server:read`，`fs.write` 需要 `nezha:server:write`，`fs.delete` 需要 `nezha:server:delete`；目标 Agent 还必须分别显式开启 `allow_command_execution` 或 `allow_file_operations`，安装器可使用 `--allow-file-operations`（Windows 为 `-AllowFileOperations`）写入文件操作开关。MCP 每个 Token 默认按每秒 10 次、每分钟 120 次限流。

## 服务监控与公开状态页

## DDNS

DDNS 配置由 ADMIN / OPERATOR 管理，设备编辑时可关联配置。Agent 上报来源地址发生变化后，服务端按 IPv4/IPv6 开关和最大重试次数更新域名；相同地址不会重复调用供应商。Webhook 支持 `#ip#`、`#domain#`、`#type#`、`#record#`、`#access_id#` 和 `#access_secret#` 占位符，请求头与凭据使用设置加密密钥保护。读取接口只返回 `webhookConfigured`，不会返回 Webhook URL、请求头或凭据；编辑时相关字段留空表示保留原值。

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/ddns` | 登录 / PAT `nezha:ddns:read` | 查看 DDNS 配置状态，不返回密文 |
| POST | `/api/ddns` | ADMIN / OPERATOR | 创建 DDNS 配置 |
| PUT | `/api/ddns/{id}` | ADMIN / OPERATOR | 更新配置；敏感字段留空保留原值 |
| DELETE | `/api/ddns/{id}` | ADMIN / OPERATOR | 删除配置 |
| POST | `/api/ddns/{id}/test?ip=` | ADMIN / OPERATOR | 使用指定地址执行一次测试更新 |

服务监控由总控服务执行 HTTP GET、ICMP Ping 或 TCPing 探测，结果按指标留存策略保存。HTTPS 目标会记录 TLS 叶子证书的到期时间，并按 `certificateThresholdDays`（0-3650，0 表示关闭）触发到期告警。服务监控的写操作需要 ADMIN / OPERATOR，公开状态接口不会返回设备 IP、硬件明细或 Agent 凭据。

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/services` | 登录 | 查看全部服务监控配置与最近结果 |
| POST | `/api/services` | ADMIN / OPERATOR | 创建服务监控 |
| PUT | `/api/services/{id}` | ADMIN / OPERATOR | 更新服务监控 |
| DELETE | `/api/services/{id}` | ADMIN / OPERATOR | 删除服务监控及结果 |
| POST | `/api/services/{id}/check` | ADMIN / OPERATOR | 立即执行一次探测 |
| GET | `/api/services/{id}/history` | 登录 | 查询最多 31 天的探测历史 |
| GET | `/api/services/public` | 公开 | 返回启用且允许公开的服务及最近结果 |
| GET | `/api/public/overview` | 公开 | 返回公开状态页所需的服务器摘要、网络速率和服务结果 |

服务请求示例：

```json
{
  "name": "官网健康检查",
  "target": "https://monitor.example.com/healthz",
  "type": "HTTP_GET",
  "intervalSeconds": 60,
  "timeoutMs": 5000,
  "publicVisible": true,
  "sortOrder": 10,
  "enabled": true,
  "certificateThresholdDays": 14
}
```

服务监控请求还可设置 `failureThreshold`（连续失败次数，1-20）和 `latencyThresholdMs`（延迟告警阈值，0 表示关闭）。服务异常从正常进入和恢复时分别发送一次通知，避免按探测周期重复发送。结果中的 `certificateExpiresAt` 仅在 HTTPS 目标成功完成 TLS 握手时返回。

告警规则支持 `CPU_USAGE`、`MEMORY_USAGE`、`DISK_USAGE`、`TCP_CONNECTIONS` 和 `DEVICE_OFFLINE`；连接数阈值使用连接数，离线阈值使用秒，其余资源阈值使用百分比。

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
