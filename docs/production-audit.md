# 生产审计与使用检查

审计范围：Spring Boot 服务端、Go Agent、Vue 控制台、Nginx/Compose 部署和安装文档。审计结论基于源码、配置、前端 390px/1440px 视口检查以及可执行的本地测试。

## 结论

- 架构可以部署到生产，但必须使用 HTTPS、强随机环境变量、外部 TLS 网关和数据库备份。
- 当前仓库不包含原生鸿蒙 App；鸿蒙端可以按 `docs/api.md` 使用 REST 和已登录 WebSocket。没有真实鸿蒙工程或设备时，无法声称已完成 ArkUI 真机兼容性测试。
- UI 遵循 Naigou WeBot 技能要求的原创化中性 SaaS 语法：近黑/白色阶、细边框、紧凑侧栏、分组导航、状态标签、移动抽屉、浅色/深色和减少动态效果。没有复制其品牌、商标、文案或素材。
- 390px 登录页无横向溢出，1440px 登录页层级清晰；控制台的表格在窄屏保留横向滚动容器，避免压缩到不可读。

## 已修复的隐藏问题

1. UI 可选择 30/60 秒采集周期，但两套 Agent 安装器此前只接受 1/3/10 秒；现在五种周期一致。
2. Windows PowerShell 5 的 UTF-8 BOM 会导致 Go Agent JSON 解析失败；安装器现在写入无 BOM UTF-8，Agent 读取也兼容已有 BOM 文件。
3. Agent 报告的磁盘、网络、进程数据此前缺少完整边界校验；现在校验非负值、百分比和字符串长度，并在服务端归一化有限数值。
4. CORS/WS 来源配置此前对逗号后的空格处理不一致；现在统一去除空白并忽略空项。
5. WebSocket 反代此前缺少客户端转发头且 70 秒无数据可能断开；现在透传客户端头并将代理读写超时提高到 1 小时。
6. Nginx 增加 CSP、Permissions-Policy、X-Content-Type-Options、X-Frame-Options 和 Referrer-Policy。

## 生产前必须确认

- `.env` 中外部 `DB_URL`、`DB_USERNAME`、`DB_PASSWORD`、管理员密码和 `SETTINGS_ENCRYPTION_KEY` 不提交 Git；安装器使用的 MySQL 管理密码不会写入 `.env`；`SETTINGS_ENCRYPTION_KEY` 丢失会使数据库中的通知凭据不可恢复。
- `production` profile 不再允许回退到 H2 默认库；缺少安装向导写入的 `DB_URL`、`DB_USERNAME`、`DB_PASSWORD` 或 `SETTINGS_ENCRYPTION_KEY` 时，服务应直接失败并要求补齐配置。
- 外层 TLS 网关正确转发 `/api/`、`/ws/`、Cookie 和 `X-Forwarded-*`；生产设置 `SESSION_COOKIE_SECURE=true` 与精确的 `ALLOWED_ORIGINS`。
- 外部 MySQL 仅开放给总终端所需来源，Redis 不发布到公网；按 `docs/controller-server.md` 做备份、升级和恢复演练。
- 受监控主机使用预编译 Agent 时无需安装 Go；源码安装才需要 Go 1.24+。密钥轮换后必须在目标机重新部署配置。
- Agent 上报接口使用独立设备密钥；鸿蒙 App 使用用户会话，不能复用 Agent 密钥。

## 验证记录

已通过：

- `pnpm --dir web test`
- `pnpm --dir web typecheck`
- `pnpm --dir web build`
- `go test ./...`
- `go vet ./...`
- PowerShell 安装器语法解析
- `git diff --check`
- 显式外部 MySQL 变量的 `docker compose config --quiet`
- 目标服务器只读环境检查：CentOS Stream 8、Docker 26.1.3、Compose v2.27、宝塔运行状态、监听端口和部署目录
- 目标服务器安装器 `bash -n` 与代码/文档同步校验

当前限制：本地没有 Maven CLI；目标服务器的 MySQL 已运行但 root socket 认证拒绝，尚未获得外部 `DB_URL/DB_USERNAME/DB_PASSWORD`，因此服务端容器尚未启动。用户按总终端材料准备数据库后，应在目标服务器补跑：

```powershell
mvn -q test
docker compose config
docker compose up --build -d
docker compose ps
```
