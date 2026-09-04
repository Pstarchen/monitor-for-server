# HTTP 与 WebSocket API

默认路径前缀为 `/api`。浏览器接口返回 JSON，并使用 Spring Security 会话 Cookie；Agent 接口使用独立请求头。时间字段均为 ISO 8601 UTC 时间。

## 认证约定

1. 浏览器先调用 `GET /api/auth/csrf`，Axios 会从 `XSRF-TOKEN` Cookie 读取值并在写请求中发送 `X-XSRF-TOKEN`。
2. 调用 `POST /api/auth/login` 建立会话。认证失败只返回通用错误，连续失败会触发限流；启用 TOTP 的账号会返回 `requiresTwoFactor: true`，此时不会建立最终认证上下文。
3. 对挑战会话调用 `POST /api/auth/2fa/verify`，验证码正确后才建立会话。挑战有效期为 5 分钟，验证码允许前后一个 30 秒周期。
4. 后续请求携带会话 Cookie。退出使用 `POST /api/auth/logout`。
5. Agent 调用上报接口时发送 `X-Device-Id` 和 `X-Agent-Key`。不要把 Agent 密钥放入 URL、日志或 Web 前端。

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
| POST | `/api/auth/login` | 公开 | 用户名、密码、可选本地 `returnTo`；启用 2FA 时返回验证码挑战 |
| POST | `/api/auth/2fa/verify` | 公开（挑战会话） | 使用 6 位 TOTP 验证码完成登录 |
| GET | `/api/auth/me` | 登录 | 当前用户资料 |
| PUT | `/api/auth/profile` | 登录 | 修改当前用户显示名；修改密码时必须同时提供当前密码和新密码 |
| GET | `/api/auth/2fa/status` | 登录 | 查看当前账号是否启用 TOTP |
| POST | `/api/auth/2fa/setup` | 登录 | 使用当前密码生成一次性绑定密钥和 `otpauth://` URI；要求设置加密密钥 |
| POST | `/api/auth/2fa/enable` | 登录 | 使用绑定阶段的 6 位验证码启用 TOTP |
| POST | `/api/auth/2fa/disable` | 登录 | 使用当前密码和 6 位验证码停用 TOTP |
| POST | `/api/auth/logout` | 登录 | 注销并清除会话 |

登录请求：

```json
{
  "username": "admin",
  "password": "通过安全输入提供",
  "returnTo": "/dashboard"
}
```

启用 TOTP 的登录响应示例：

```json
{
  "user": null,
  "returnTo": "/dashboard",
  "requiresTwoFactor": true
}
```

绑定流程先提交 `{"currentPassword":"通过安全输入提供"}` 到 `/api/auth/2fa/setup`，将返回的 `otpauthUri` 交给身份验证器 App 后，再把当前 6 位码提交到 `/api/auth/2fa/enable`。密钥只在 setup 响应中返回一次，数据库不会保存明文。

## 设备与指标

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/devices` | 登录 | 设备及最新指标列表 |
| GET | `/api/devices/{id}` | 登录 | 单台设备详情 |
| GET | `/api/devices/{id}/health` | 登录 | Agent 接入健康诊断：连接状态、最近上报年龄、失联阈值、指标年龄和检查结果 |
| POST | `/api/devices` | ADMIN / OPERATOR | 创建设备并一次性返回 Agent 密钥 |
| PUT | `/api/devices/{id}` | ADMIN / OPERATOR | 更新名称、位置、分组、主 IP、资产信息和公开设置 |
| POST | `/api/devices/{id}/enrollment-token` | ADMIN / OPERATOR + 设备管理权限 | 签发 15 分钟有效、只能消费一次的 Agent 接入令牌 |
| POST | `/api/devices/{id}/rotate-key` | ADMIN | 轮换并一次性返回新密钥 |
| POST | `/api/agent/v1/enroll` | 接入令牌 | 原子消费接入令牌并一次性返回长期 Agent 密钥 |
| DELETE | `/api/devices/{id}` | ADMIN | 删除设备及关联数据 |
| GET | `/api/devices/{id}/metrics/latest` | 登录 | 最新指标 |
| GET | `/api/devices/{id}/metrics/history` | 登录 | `from` 到 `to` 的历史指标，最大 31 天；每个快照包含当时的容器与进程列表，控制台可据此绘制单容器/单进程历史趋势 |
| GET | `/api/v2/devices/{id}/diagnostics` | 登录 / PAT `nezha:server:read` | 移动端诊断摘要：资源总量、网卡、磁盘 SMART、CPU/内存占用前五进程及健康提示 |
| GET | `/api/v2/devices/{id}/metrics/history?range=6H` | 登录 / PAT `nezha:server:read` | 移动端历史趋势；支持 `1H`、`6H`、`24H`、`7D`、`30D`，按范围降采样且最多返回 720 点 |
| GET | `/api/devices/{id}/notes?limit=50` | 登录 | 设备工作记录，最多 200 条 |
| POST | `/api/devices/{id}/notes` | ADMIN / OPERATOR | 新增交接、变更或巡检记录，正文最多 2000 字符 |
| DELETE | `/api/devices/{id}/notes/{noteId}` | ADMIN / OPERATOR | 删除设备工作记录 |
| GET | `/api/device-notes/recent?limit=8` | 登录 | 首页值班记录汇总 |
| GET | `/api/devices/{id}/status-history` | 登录 | 设备状态转换时间线，默认最近 31 天，最多查询 366 天 |

创建设备请求：

```json
{
  "name": "生产 API-01",
  "location": "上海机房 A3",
  "groupName": "生产环境",
  "primaryIp": "10.20.1.15",
  "assetTag": "SRV-2025-001",
  "ownerName": "运维一组",
  "vendor": "Dell",
  "model": "PowerEdge R760",
  "serialNumber": "SN-001",
  "environment": "production",
  "purchaseDate": "2025-01-02",
  "warrantyExpiresAt": "2028-01-02",
  "description": "生产 API 主节点"
}
```

设备资产字段均为可选；`environment` 可使用 `production`、`staging`、`testing`、`development` 或 `disaster-recovery`，日期使用 `YYYY-MM-DD`。设备状态从待接入变为在线、从在线变为离线或恢复在线时，系统会自动生成状态历史事件。

创建和轮换密钥的响应为兼容旧客户端，仍包含 `{ "device": { ... }, "agentKey": "..." }`。新控制台不会展示或写入安装命令，而是调用 enrollment-token 接口；响应为 `{ "token": "...", "expiresAt": "..." }`。安装器随后向 `/api/agent/v1/enroll` 发送 `{ "deviceId": "...", "token": "..." }`，成功后令牌原子失效并返回 `{ "agentKey": "..." }`。服务端只保存接入令牌的 SHA-256；错误、过期和已消费令牌统一返回 `401`。

设备列表和详情中的 `health` 字段与上述诊断接口一致。`state` 为 `HEALTHY`、`PENDING`、`OFFLINE` 或 `DEGRADED`：

- `PENDING` / `NOT_CONNECTED`：尚未收到首次 Agent 上报。
- `OFFLINE` / `HEARTBEAT_TIMEOUT`：最近上报超过系统配置的失联阈值。
- `DEGRADED` / `DATA_STALE`：Agent 最近有连接，但指标快照为空或已过期。
- `HEALTHY` / `HEALTHY`：连接和最新指标均在阈值内。

接口只返回诊断元数据和可读原因，不返回 Agent 密钥、Webhook 或其他机密。

`/api/v2` 移动诊断接口同时受账号设备权限和 PAT 服务器白名单约束。`diagnostics` 使用最新一条指标快照；设备尚无指标时返回 `404`。历史接口省略 `range` 时默认 `6H`，响应中的 `range`、`from`、`to` 和 `sampleStepSeconds` 可用于客户端绘制时间轴。

## 网络发现

网络发现由总控服务器执行，用于补齐尚未登记的私网节点。出于安全和资源保护，服务端只接受 RFC1918 私网 IPv4 的 `/24` 到 `/32` 网段（最多 256 个地址），每个任务最多 32 个端口，并限制单端口超时和并发数。网络发现仅接受浏览器登录会话，API Token 不能发起探测。

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/discovery?limit=20` | ADMIN / OPERATOR | 查看最近扫描任务 |
| POST | `/api/discovery` | ADMIN / OPERATOR | 异步创建扫描任务，返回 `202 Accepted` |
| GET | `/api/discovery/{id}` | ADMIN / OPERATOR | 查看任务进度和发现结果 |
| POST | `/api/discovery/{id}/cancel` | ADMIN / OPERATOR | 取消排队或运行中的任务 |

创建请求示例：

```json
{
  "cidr": "192.168.1.0/24",
  "ports": [22, 80, 443, 8080],
  "timeoutMs": 500,
  "concurrency": 16
}
```

结果只包含主机可达或至少一个端口可连接的地址；控制台可复制地址或带入设备登记表单，后续仍需签发一次性接入令牌并完成首次上报。

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

请求体包含 `collectedAt`、`host`、`cpu`、`memory`、`disks`、`network`、`networkInterfaces`、`ports`、`containers`、`processes`、`services`，以及 Agent 自身的 `agentVersion`、`agentUpdateStatus`、`agentLastUpdateError`、`agentUpdateStateChangedAt`。`agentVersion` 必须是稳定 `vX.Y.Z`；状态支持 `IDLE`、`CHECKING`、`DOWNLOADING`、`APPLYING`、`SUCCEEDED`、`FAILED`、`PAUSED`、`ROLLING_BACK`。最近错误会限长并展示给管理员，不得包含凭据、原始异常堆栈或敏感路径。

Agent 的 `monitored_processes` 配置会让指定进程即使不在默认 CPU 前 12 名也保留在 `processes` 列表中（最多额外 32 个）；显式开启 `collect_all_processes` 后最多采集 256 个进程，`process_collection_limit` 可降低上限。进程对象的 `commandLine` 最长 2048 字符，读取失败时为空。端口和容器明细分别受 `port_collection_limit`（最多 512）与 `container_collection_limit`（最多 100）限制，也可以通过 `skip_port_collection`、`skip_container_collection` 独立关闭。`host.fans`、`host.batteries` 和 `host.gpus` 是可选硬件健康数据：Linux 从 hwmon/power_supply 读取风扇与电池，安装 `nvidia-smi` 时采集 NVIDIA GPU；不支持或无权限时为空数组，不影响其他指标。磁盘可包含可选 `smart` 健康对象；Agent 在 Linux 上检测到 `smartctl` 且设备权限允许时读取 SMART/NVMe 自检、温度、寿命与错误计数，否则状态为 `UNKNOWN` 或不附带对象。`containers` 是可选的 Docker/Podman 容器摘要；无法访问运行时 socket 时为空数组。成功返回 `202 Accepted` 和归一化后的指标快照，并返回 `X-Agent-Interval-Seconds` 响应头。Agent 会在下一次成功上报后应用总控设置的周期；网络中断时继续使用本地周期。

## Agent 任务

普通任务用于向受控 Agent 下发非交互的一次性命令。Agent 配置中的 `allow_command_execution` 默认是 `false`，只有显式开启后才执行 `COMMAND`；命令按可执行文件和参数直接启动，不经过 Shell。安装器可使用 `--allow-command-execution`（Windows 为 `-AllowCommandExecution`）写入此开关。服务端限制命令参数数量、超时时间（1-300 秒）和 stdout/stderr 大小（1KiB-1MiB），任务创建、取消和结果都会写入审计日志。

`AGENT_UPDATE` 是独立的受控 operation，不依赖 `allow_command_execution` 或文件操作权限。它只能使用固定 `command=agent.update`、空 `args` 和严格 payload；普通命令入口不能伪造该 operation，普通取消入口也不能绕过 rollout 状态机。

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/tasks?deviceId=&limit=50` | 登录 / PAT `nezha:server:read` | 查看任务及结果；PAT 受服务器白名单约束 |
| POST | `/api/tasks` | ADMIN / OPERATOR / PAT `nezha:server:exec` | 创建任务 |
| POST | `/api/tasks/update` | ADMIN | 为已校验 rollout/member 创建固定 Agent 更新任务；主要由 rollout worker 调用 |
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

固定更新任务示例：

```json
{
  "deviceId": "device-uuid",
  "action": "update",
  "version": "v1.20.15",
  "rolloutId": 123,
  "memberId": 456
}
```

`action` 仅为 `update` 或 `rollback`，版本只接受无 prerelease/build 且无前导零的 `vX.Y.Z`，两个 ID 必须成对出现并与数据库中的 rollout/member/device 关系一致。Agent 收到的 assignment 为 `operation=AGENT_UPDATE`、`command=agent.update`、`args=[]`；payload 不接受 URL、路径、命令或未知字段。

## Agent 灰度发布

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/agent-rollouts?limit=50` | 登录 | 列表；OPERATOR/VIEWER 只返回具有设备查看权限的成员，无可见成员的发布会隐藏 |
| GET | `/api/agent-rollouts/{id}` | 登录 | 详情；没有任何可见成员时返回 `403` |
| POST | `/api/agent-rollouts` | ADMIN | 创建发布草稿 |
| POST | `/api/agent-rollouts/{id}/start` | ADMIN | 启动草稿 |
| POST | `/api/agent-rollouts/{id}/pause` | ADMIN | 暂停运行中更新或回滚 |
| POST | `/api/agent-rollouts/{id}/resume` | ADMIN | 继续已暂停发布 |
| POST | `/api/agent-rollouts/{id}/cancel` | ADMIN | 停止派发并继续对账已领取任务 |
| POST | `/api/agent-rollouts/{id}/rollback` | ADMIN | 将实际确认升级的成员回滚到各自发布前版本 |

创建请求：

```json
{
  "targetVersion": "v1.20.15",
  "deviceIds": ["device-a", "device-b"],
  "maintenanceWindowId": null,
  "canaryPercent": 10,
  "ringCount": 3,
  "maxConcurrent": 5,
  "jitterSeconds": 30,
  "failureThreshold": 20,
  "verificationTimeoutSeconds": 600
}
```

必须显式选择 1-500 台已上报稳定版本的非 Controller-managed Agent，且目标版本高于每台当前版本。可选参数省略时使用上例数值；范围依次为灰度 `0-100`、批次 `1-20`、并发 `1-100`、抖动 `0-86400` 秒、失败阈值 `1-100`、确认超时 `30-86400` 秒。

动作请求体可省略，也可传 `{"reason":"变更单或操作原因"}`。发布状态为 `DRAFT`、`RUNNING`、`PAUSED`、`CANCELED`、`SUCCEEDED`、`FAILED`、`ROLLING_BACK`、`ROLLED_BACK`；成员状态区分排队、已接受、版本确认、失败和对应回滚阶段。

任务结果 `SUCCEEDED` 只会把成员置为等待版本确认。确认必须满足 `device.lastSeenAt >= member.queuedAt` 且 `device.agentVersion` 等于目标版本；回滚使用每个成员创建时保存的 `previousVersion`。当前 ring 的已完成成员中失败率达到阈值后自动暂停。取消时无法撤回的已领取任务会继续对账 late report，显式回滚只纳入后来确认为已升级的成员。

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

`metric` 支持 CPU、内存、磁盘空间、1 分钟负载、磁盘读写速率、容器 CPU/内存、GPU 使用率、电池电量、SMART 失败磁盘数、TCP 连接数、网络速率、温度和设备离线。GPU、电池、SMART 及容器规则在目标没有对应数据时会自动跳过，避免把缺失数据误判为 0。

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
| GET | `/api/settings/notifications/deliveries` | ADMIN | 查看最近通知投递结果和失败原因 |
| POST | `/api/settings/notifications/deliveries/{id}/retry` | ADMIN | 使用当前配置重试失败投递 |
| GET | `/api/reports/summary` | 登录 | 查询 1-31 天节点、服务和告警汇总报告 |
| GET | `/api/reports/summary.csv` | 登录 | 下载同一时间窗口的 CSV 报告 |
| GET | `/api/admin/users` | ADMIN | 账号列表 |
| POST | `/api/admin/users` | ADMIN | 创建账号，密码至少 12 位 |
| PUT | `/api/admin/users/{id}` | ADMIN | 更新名称、角色、状态和可选新密码 |
| GET | `/api/device-access/me` | 登录 | 查看当前账号可见设备及其操作权限 |
| GET | `/api/admin/users/{id}/device-permissions` | ADMIN | 查看指定账号的设备权限矩阵 |
| PUT | `/api/admin/users/{id}/device-permissions` | ADMIN | 整体替换指定账号的设备权限矩阵 |
| GET | `/api/admin/audit-logs?limit=100` | ADMIN | 最近审计记录，最大 200 条 |
| GET | `/actuator/health` | 公开 | 服务健康状态 |

### API Token

登录会话可在 `/api/api-tokens` 创建和吊销个人 API Token。明文只在创建响应中返回一次，服务端只保存 SHA-256 哈希；这表示明文无法再次找回，不表示 PAT 是一次性凭据。PAT 可重复使用，直至到期或被吊销。PAT 使用 `Authorization: Bearer nzp_...` 调用接口，并且同时受用户角色、用户设备权限、scope 和服务器 ID 白名单约束。设备实际范围是用户设备权限与 Token 白名单的交集；空白名单表示不额外缩小用户已有的设备范围。

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/api-tokens` | 登录会话 | 查看当前用户的 Token 元信息，不返回明文 |
| POST | `/api/api-tokens` | 登录会话 | 创建 Token，支持 `scopes`、`serverIds`、`expiresInDays` |
| DELETE | `/api/api-tokens/{id}` | 登录会话 | 吊销当前用户的 Token |

创建请求示例：

```json
{
  "name": "harmony-mobile",
  "scopes": ["nezha:inventory:read", "nezha:server:read", "nezha:service:read", "nezha:alert:read", "nezha:realtime:read", "nezha:push:read", "nezha:push:write", "nezha:push:delete"],
  "serverIds": [],
  "expiresInDays": 90
}
```

常用 scope 为 `nezha:inventory:read`（设备清单）、`nezha:server:read`（设备指标）、`nezha:service:read`（服务监控）、`nezha:alert:read`（告警读取）、`nezha:realtime:read`（实时事件）和 `nezha:push:read` / `write` / `delete`（当前 PAT 的华为 Push Kit 登记），以及对应资源的 `write` / `delete` / `exec` 权限。`nezha:admin:*` 与 `nezha:*` 仅管理员可以签发。

#### 鸿蒙扫码绑定

创建 Token 后，控制台先通过当前登录会话调用 `GET /api/client/bootstrap`，再用响应中的控制器身份、API 版本和能力列表生成 schema v2 鸿蒙 App 绑定二维码。二维码内容是 UTF-8 JSON，不会写入服务端；其中的 `token` 与创建响应中仅展示一次的明文相同：

```json
{
  "type": "xingchenyunxun-bind",
  "schemaVersion": 2,
  "baseUrl": "https://monitor.example.com",
  "token": "nzp_...",
  "scopes": ["nezha:inventory:read", "nezha:server:read", "nezha:service:read", "nezha:alert:read", "nezha:realtime:read", "nezha:push:read", "nezha:push:write", "nezha:push:delete"],
  "controllerId": "7c9ae80b-5a56-49ef-8448-695888502191",
  "controllerName": "华东监控中心",
  "apiVersion": 2,
  "capabilities": ["client-bootstrap-v1", "mobile-diagnostics-v1", "alert-cursor-v2", "realtime-v2"],
  "tokenExpiresAt": "2026-12-01T08:00:00Z"
}
```

`tokenExpiresAt` 使用 ISO-8601 时间；永不过期的 PAT 使用空字符串。旧版 `type/baseUrl/token/scopes` schema v1 仍由兼容 helper 和旧客户端支持，但 Web 控制台只在成功取得 bootstrap 后生成 v2 二维码，不会伪造控制器元数据。

客户端 bootstrap 可由登录会话或具有 `nezha:inventory:read` 的 PAT 调用。响应中的 `controller` 包含持久化 `id`、显示 `name`、`canonicalEntry` 和 `timezone`；`server` 包含版本、构建时间、`apiVersion`、`minimumClientApiVersion` 和服务器时间；`capabilities` 只声明服务端实际启用的能力；`principal` 描述认证类型、账号和角色，PAT 认证时还包含 Token ID、前缀、scope、服务器范围和到期时间，但永不返回 PAT 明文。App 应只接受精确的 `type`，校验 schema 上限和 scope 格式，以 bootstrap 响应为权威；QR 与 bootstrap 的 `controllerId` 不一致时拒绝保存。

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/client/bootstrap` | 登录 / PAT `nezha:inventory:read` | 返回控制器、服务端、能力和当前认证主体元数据，不返回 PAT 明文 |

二维码内的 PAT 是可重复使用的 Bearer 凭据，并非扫码后失效的一次性凭据。二维码和 Token 明文具有相同权限，不应转发、截图或长期保留；默认移动端 scope 允许读取设备、指标、服务监控、告警和实时事件，并只管理该 PAT 自己的华为 Push Kit 登记。建议设置有效期，发生泄露时立即在控制台吊销。若服务端返回 403，响应中的 `requiredScope` 会标明请求所需的 Token scope。

### MCP HTTP

MCP 默认关闭。设置 `ENABLE_MCP=true` 并重启服务后，使用 `Authorization: Bearer nzp_...` 向 `POST /mcp` 发送 Streamable HTTP JSON-RPC 请求；网页登录会话不会被接受。当前入口支持 `initialize`、`notifications/initialized`、`ping`、`tools/list`，以及 `meta.whoami`、`server.list`、`server.get`、`server.exec`、`fs.list`、`fs.read`、`fs.write`、`fs.delete` 工具。命令和文件操作会复用任务队列，返回任务 ID；MCP 会短暂等待快速完成的任务，超时仍返回任务状态，之后可通过任务 API 查询输出。

MCP 工具继续受 Token scope 和服务器 ID 白名单约束。`server.exec` 需要 `nezha:server:exec`，`fs.list` / `fs.read` 需要 `nezha:server:read`，`fs.write` 需要 `nezha:server:write`，`fs.delete` 需要 `nezha:server:delete`；目标 Agent 还必须分别显式开启 `allow_command_execution` 或 `allow_file_operations`，安装器可使用 `--allow-file-operations`（Windows 为 `-AllowFileOperations`）写入文件操作开关。MCP 每个 Token 默认按每秒 10 次、每分钟 120 次限流。

## 服务监控与公开状态页

## DDNS

DDNS 配置由 ADMIN / OPERATOR 管理，设备编辑时可关联配置。Agent 上报来源地址发生变化后，服务端按 IPv4/IPv6 开关和最大重试次数更新域名；相同地址不会重复调用供应商。Webhook 支持 `#ip#`、`#domain#`、`#type#`、`#record#`、`#access_id#` 和 `#access_secret#` 占位符，请求头与凭据使用设置加密密钥保护。读取接口只返回 `webhookConfigured`，不会返回 Webhook URL、请求头或凭据；编辑时相关字段留空表示保留原值。

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/ddns` | 登录 / PAT `nezha:ddns:read` | 查看 DDNS 配置状态，不返回密文 |
| GET | `/api/maintenance-windows` | 登录 / PAT `nezha:maintenance:read` | 查看维护静默窗口；受服务器白名单约束 |
| POST | `/api/maintenance-windows` | ADMIN / OPERATOR / PAT `nezha:maintenance:write` | 创建维护静默窗口 |
| PUT | `/api/maintenance-windows/{id}` | ADMIN / OPERATOR / PAT `nezha:maintenance:write` | 更新维护静默窗口 |
| DELETE | `/api/maintenance-windows/{id}` | ADMIN / OPERATOR / PAT `nezha:maintenance:delete` | 删除维护静默窗口 |
| POST | `/api/ddns` | ADMIN / OPERATOR | 创建 DDNS 配置 |
| PUT | `/api/ddns/{id}` | ADMIN / OPERATOR | 更新配置；敏感字段留空保留原值 |
| DELETE | `/api/ddns/{id}` | ADMIN / OPERATOR | 删除配置 |
| POST | `/api/ddns/{id}/test?ip=` | ADMIN / OPERATOR | 使用指定地址执行一次测试更新 |

服务监控由总控服务执行 HTTP GET、ICMP Ping、TCPing、FTP 握手、SFTP/SSH 握手、SNMP v2c 只读查询、Redis PING、PostgreSQL 或 MySQL 协议探测，结果按指标留存策略保存。FTP 仅验证 `220` 欢迎响应，SFTP 仅验证 `SSH-` 协议头，不执行登录，也不保存账号密码；SNMP 仅查询 `sysDescr.0`，community 使用设置加密密钥加密保存，接口只返回是否已配置；数据库探测只发送最小协议握手，不执行查询，也不需要保存数据库密码；Redis 启用认证时，`NOAUTH` 响应仍表示服务已在线。HTTP GET 可额外设置 `expectedStatus` 精确匹配状态码，以及 `bodyContains` 检查响应体是否包含业务标记（响应体最多读取 64 KiB）。另支持 `HEARTBEAT` 外部心跳类型：总控不主动连接目标，而是由 cron、CI、备份脚本等任务定时调用心跳地址；超过两个配置周期未收到上报会记录失败并触发通知。HTTPS 目标会记录 TLS 叶子证书的到期时间，并按 `certificateThresholdDays`（0-3650，0 表示关闭）触发到期告警。服务监控的写操作需要 ADMIN / OPERATOR，公开状态接口不会返回设备 IP、硬件明细或 Agent 凭据。

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
| GET / POST | `/api/heartbeat/{id}` | 心跳令牌 | 接收外部任务心跳；令牌放在 `X-Heartbeat-Token` 请求头或 `token` 查询参数 |

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
  "certificateThresholdDays": 14,
  "expectedStatus": 200,
  "bodyContains": "status:ok"
}
```

服务监控请求还可设置 `failureThreshold`（连续失败次数，1-20）和 `latencyThresholdMs`（延迟告警阈值，0 表示关闭）。服务异常从正常进入和恢复时分别发送一次通知，避免按探测周期重复发送。结果中的 `certificateExpiresAt` 仅在 HTTPS 目标成功完成 TLS 握手时返回。

数据库协议探测示例（目标必须包含端口）：

```json
{
  "name": "生产 Redis",
  "target": "redis.internal:6379",
  "type": "REDIS_PING",
  "intervalSeconds": 30,
  "timeoutMs": 3000,
  "publicVisible": false,
  "sortOrder": 0,
  "enabled": true,
  "failureThreshold": 2,
  "latencyThresholdMs": 0,
  "certificateThresholdDays": 0
}
```

将 `type` 替换为 `POSTGRESQL`（默认端口 5432）或 `MYSQL`（默认端口 3306）即可探测对应服务。探测只验证协议握手，不执行 SQL；启用认证的 Redis 返回 `NOAUTH` 时仍会记录为在线。

创建心跳监控时将 `type` 设为 `HEARTBEAT`，`target` 留空即可。创建响应中的 `heartbeatToken` 和 `heartbeatPath` 只返回一次，请立即保存。例如：

```bash
curl -fsS -X POST -H 'X-Heartbeat-Token: hb_...' 'https://monitor.example.com/api/heartbeat/42'
```

也可以使用 `?token=` 查询参数兼容只支持 URL 的定时任务，但请求头方式不会把令牌带入常见的访问日志。

建议将命令加入 cron（例如每分钟执行一次），并将 `intervalSeconds` 设置为 60。令牌服务端只保存 SHA-256 摘要；编辑或列表接口不会再次返回明文令牌。

告警规则支持 `CPU_USAGE`、`MEMORY_USAGE`、`DISK_USAGE`、`TCP_CONNECTIONS`、`NETWORK_RECV_BPS`、`NETWORK_SENT_BPS`、`TEMPERATURE`、`FAN_RPM` 和 `DEVICE_OFFLINE`；连接数阈值使用连接数，网络阈值使用 B/s，温度阈值使用 °C，风扇阈值使用 RPM，离线阈值使用秒，其余资源阈值使用百分比。

系统设置请求：

```json
{
  "metricRetentionDays": 30,
  "deviceOfflineAfterSeconds": 30,
  "defaultCollectionSeconds": 3,
  "siteName": "星辰监控",
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
  "wecom": { "enabled": false, "webhookUrl": null, "clearWebhook": false },
  "generic": { "enabled": false, "webhookUrl": null, "clearWebhook": false, "payloadFormat": "GENERIC_JSON" }
}
```

敏感值使用 `null` 或空字符串表示保留当前值，`clearPassword` / `clearWebhook` 用于删除数据库覆盖值。响应只包含 `configured`、`source` 等状态字段。

通用 Webhook 支持以下消息格式：`GENERIC_JSON` 和 `SLACK` 发送 `{ "text": "..." }`，`DISCORD` 发送 `{ "content": "..." }`，`LARK` 发送 `{ "msg_type": "text", "content": { "text": "..." } }`，`PLAIN_TEXT` 以 `text/plain` 发送原始消息。通用端点只要返回 HTTP 2xx 即视为成功，不要求固定响应 JSON；地址仍需使用 HTTPS（本地开发可显式开启 `ALLOW_INSECURE_HTTP`）。

## WebSocket

已登录浏览器连接 `/ws/metrics`。网关必须转发 Upgrade 与 Connection 请求头。

### 可恢复实时通道

`/ws/realtime` 是与旧 `/ws/metrics` 并行的可靠实时通道。客户端先以登录会话或具有 `nezha:realtime:read` 的 PAT 调用 `POST /api/realtime/ticket?afterEventId=` 获取 30 秒内有效、仅可使用一次的 ticket，再连接 `/ws/realtime?ticket=`。ticket 不包含会话 Cookie 或 PAT 明文。

每个事件包含 `schemaVersion`、稳定 UUID `eventId`、`type`、`occurredAt`、`controllerId` 和最小化 `payload`，设备 ID 位于需要设备过滤的事件 payload 中。服务端按当前用户设备权限过滤事件。客户端应持久化最后成功处理的 `eventId`，断线后用它签发新 ticket；也可通过 `GET /api/realtime/events?afterEventId=&limit=` 分页补偿。补偿响应包含 `events`、`nextEventId`、`oldestEventId`、`latestEventId`、`hasMore` 和 `resyncRequired`。游标已超出保留窗口或积压超过单批上限时，服务端设置 `resyncRequired=true`；WebSocket 会发送 `resync.required` 后正常关闭，客户端应重载 REST 快照再从最新事件继续。

事务 outbox 当前覆盖实时指标、设备状态变化以及告警打开、更新、确认和恢复。Redis 启用时，发布器将已提交事件发送到配置频道供多个服务实例订阅；Redis 不可用不会回滚业务事务，事件保留在 outbox 并退避重试。`REALTIME_RETENTION_HOURS` 控制已发布、已完成推送扇出的事件保留时间。

### 华为 Push Kit 移动推送登记

这里的推送专指 HarmonyOS NEXT/5.x+ 的华为 Push Kit V3，不是 Web Push、FCM、APNs、通用 Webhook，也不是旧版华为 OAuth Push API。服务端接入与环境变量见 [华为 Push Kit V3 接入](huawei-push-kit.md)。

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| POST | `/api/mobile/installations` | PAT `nezha:push:write` | 按 `clientInstallationId` 幂等创建或刷新当前 PAT 的 HarmonyOS 设备登记 |
| GET | `/api/mobile/installations` | PAT `nezha:push:read` | 列出当前 PAT 的登记；仅返回 token 尾号，不返回密文或明文 |
| PATCH / PUT | `/api/mobile/installations/{id}/token` | PAT `nezha:push:write` | 轮换华为 Push Token，并可刷新 App 版本 |
| PATCH / PUT | `/api/mobile/installations/{id}/preferences` | PAT `nezha:push:write` | 更新告警、设备状态和总启用开关 |
| DELETE | `/api/mobile/installations/{id}` | PAT `nezha:push:delete` | 删除当前 PAT 拥有的登记及其投递历史 |
| POST | `/api/mobile/installations/{id}/test` | PAT `nezha:push:write` | 提交华为 Push Kit 测试消息；Push Kit 关闭时返回 `503` |

推送 token 使用与系统设置相同的 `SecretValueCodec` 和 `SETTINGS_ENCRYPTION_KEY` 加密保存，并用不可逆 SHA-256 指纹防止重复登记。投递按 outbox `eventId` 和 installation 去重，只向有设备查看权限且偏好已开启的用户扇出。失败投递采用有上限的指数退避；供应商确认 token 失效时会停用对应登记。

华为 Push Kit 默认关闭。只有完整配置 V3 服务账号的 `project_id`、`key_id`、`sub_account` 与 PKCS#8 私钥后才能设置 `PUSH_KIT_ENABLED=true`。服务端使用 PS256 生成一小时有效的 JWT，并固定请求 `https://push-api.cloud.huawei.com/v3/{projectId}/messages:send`；不再接受旧 OAuth 客户端凭据或自定义推送端点。`PUSH_KIT_BATCH_SIZE` 和 `PUSH_KIT_MAX_ATTEMPTS` 控制工作批次及最大尝试次数。

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
