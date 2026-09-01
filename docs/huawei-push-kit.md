# 华为 HarmonyOS Push Kit V3 接入

## 能力边界

本项目中的 `Push Kit` 专指华为面向 HarmonyOS NEXT/5.x 及之后版本提供的 Push Kit V3 场景化消息服务。它用于把监控告警和设备状态变化发送到已绑定的 HarmonyOS App，不是以下服务：

- 浏览器 Web Push；
- Firebase Cloud Messaging（FCM）或 Apple Push Notification service（APNs）；
- 本项目已有的邮件、钉钉、企业微信和通用 Webhook 通知；
- 使用 `client_id/client_secret` 的旧版华为 OAuth Push API。

服务端固定调用 `POST https://push-api.cloud.huawei.com/v3/{projectId}/messages:send`，请求头使用 `push-type: 0`，并通过华为服务账号私钥生成 PS256 JWT。发送体使用 V3 的 `payload.notification`、`target.token` 和 `pushOptions` 结构。

官方参考：

- [Push Kit 使用入门](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-gettingstart)
- [基于服务账号生成鉴权令牌](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-jwt-token)
- [发送通知消息](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-send-alert)
- [场景化消息响应参数](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/push-scenariozed-api-response)

## 消息来源

当前只向已开启偏好的安装登记发送以下业务事件：

- `alert.*`：告警打开、更新、确认和恢复；按安装登记的最低严重级别过滤。
- `device.status`：设备在线状态变化。
- `push.test`：用户主动触发的测试消息，向华为请求设置 `testMessage=true`。

服务端根据 PAT 所属账号的设备权限、PAT 服务器白名单以及安装登记的设备范围再次过滤。华为 Push Token 加密保存，API 只返回末尾字符。

## 华为侧准备

1. 在 AppGallery Connect 中为 HarmonyOS 应用开通 Push Kit，并确认应用所属项目 ID。
2. 在华为开发者联盟 API Console 中为同一项目创建“推送服务 API”的服务账号密钥，下载 JSON 文件。
3. 从 JSON 文件读取 `project_id`、`key_id`、`sub_account` 和 `private_key`。私钥必须保留为 PKCS#8 PEM，不要提交到 Git。
4. 根据应用实际消息类别申请通知消息自分类权益。未取得对应权益时保持 `PUSH_KIT_CATEGORY=MARKETING`；取得权益后再改为华为批准的 category。

HarmonyOS App 需要通过 `@kit.PushKit` 获取 Push Token，请求通知授权，并把 Token 上传到 `/api/mobile/installations`。Token 变化时应监听 `tokenUpdate` 并调用 `PATCH /api/mobile/installations/{id}/token` 更新；设备升级到 HarmonyOS NEXT 后也应重新获取 Token。

## 服务端配置

将服务账号字段写入部署服务器的私有 `.env`，不要写入仓库。`PUSH_KIT_PRIVATE_KEY` 可以使用单行的 `\n` 表示 PEM 换行。

```dotenv
PUSH_KIT_ENABLED=false
PUSH_KIT_PROJECT_ID=
PUSH_KIT_KEY_ID=
PUSH_KIT_SUB_ACCOUNT=
PUSH_KIT_PRIVATE_KEY=
PUSH_KIT_CATEGORY=MARKETING
PUSH_KIT_TTL_SECONDS=86400
PUSH_KIT_BATCH_SIZE=50
PUSH_KIT_MAX_ATTEMPTS=5
```

先填写并检查全部服务账号字段，最后才把 `PUSH_KIT_ENABLED` 改为 `true`。启用时服务端会在启动阶段验证项目 ID、category 和私钥格式；配置无效会拒绝启动，避免产生无法投递的队列。

```bash
docker compose config --quiet
docker compose up -d --build --no-deps server
docker compose logs --tail 100 server
```

## App API 权限

移动 App 的 PAT 默认包含：

- `nezha:push:read`：读取该 PAT 的 HarmonyOS 安装登记。
- `nezha:push:write`：创建登记、更新 Push Token/偏好和发送测试消息。
- `nezha:push:delete`：删除该 PAT 的登记。

这些权限不授予对其他账号或其他 PAT 登记的访问。完整接口见 [HTTP 与 WebSocket API](api.md#华为-push-kit-移动推送登记)。

## 验证与排障

1. App 使用新创建的 PAT 登记当前 Push Token。
2. 调用 `/api/mobile/installations/{id}/test`，接口应返回 `QUEUED`；Push Kit 未启用时返回 `503`。
3. 检查投递状态。华为业务码 `80000000` 才视为成功，`80200005`、`80300029`、`81000001` 会进入有限重试。
4. `tokenFormatError` 或 `tokenPlatformNotSupport` 会停用对应登记，App 应重新获取并上报 Token。

华为通知消息受权益和频控约束。调测消息每日及单次 Token 数量也有限制；接口返回成功但设备未展示通知时，应同时检查 App 通知授权、category 权益、Push Token 所属项目和华为侧频控。
