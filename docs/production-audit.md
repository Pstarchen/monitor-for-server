# 生产审计与使用检查

审计范围：Spring Boot 服务端、Go Agent、Vue 控制台、Nginx/Compose 部署和安装文档。审计结论基于源码、配置、前端 390px/1440px 视口检查以及可执行的本地测试。

## 结论

- 架构可以部署到生产，但必须使用 HTTPS、强随机环境变量、外部 TLS 网关和 PostgreSQL 数据库备份。
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
7. Linux 总终端现在通过受管 Agent 自动注册为设备，并使用只读宿主机挂载采集真实磁盘容量；受管设备不能在控制台轮换密钥或删除。

## 生产前必须确认

- `.env` 中 PostgreSQL 凭据、管理员密码和 `SETTINGS_ENCRYPTION_KEY` 不提交 Git；数据库账号由安装器自动生成；`SETTINGS_ENCRYPTION_KEY` 丢失会使数据库中的通知凭据不可恢复。
- `production` profile 不再允许回退到 H2 默认库；缺少安装向导写入的 PostgreSQL 凭据或 `SETTINGS_ENCRYPTION_KEY` 时，服务应直接失败并要求补齐配置。
- 外层 TLS 网关正确转发 `/api/`、`/ws/`、Cookie 和 `X-Forwarded-*`；生产设置 `SESSION_COOKIE_SECURE=true` 与精确的 `ALLOWED_ORIGINS`。
- PostgreSQL 仅在 Compose 内网可达，Redis 不发布到公网；按 `docs/controller-server.md` 做备份、升级和恢复演练。
- 受监控主机使用预编译 Agent 时无需安装 Go；源码安装才需要 Go 1.24+。密钥轮换后必须在目标机重新部署配置。
- Agent 上报接口使用独立设备密钥；鸿蒙 App 使用用户会话，不能复用 Agent 密钥。
- PostgreSQL、Redis 和服务端仅通过 Compose 内网通信，数据库端口不发布到宿主机。
- 控制端安装器默认不做破坏性清理，显式传入 `--cleanup` 才会移除本项目旧容器和镜像；PostgreSQL/Redis 数据卷以及其他项目资源始终保留。
- Linux 总终端的 `controller-agent` 仅使用本机 Web 入口、只读宿主机文件系统与独立缓冲卷；Windows Docker Desktop 安装默认不启用它，以免采集到 Linux 虚拟机而非 Windows 宿主机。
- Agent 安装命令支持从仓库脚本直接执行；没有本地源码时会自动拉取源码构建，生产环境仍建议传入预编译二进制。

## 验证记录

已通过：

- `pnpm --dir web test`
- `pnpm --dir web typecheck`
- `pnpm --dir web build`
- `go test ./...`
- `go vet ./...`
- 目标服务器 Maven 3.9.9 / JDK 21 容器中的 `mvn -q clean test`
- PowerShell 安装器语法解析
- `git diff --check`
- PostgreSQL Compose 配置的 `docker compose config --quiet`
- PostgreSQL 16.15 临时库上的 Flyway V1 迁移、Hibernate schema 校验和 production profile 启动
- 目标服务器只读环境检查：CentOS Stream 8、Docker 26.1.3、Compose v2.27、宝塔运行状态、监听端口和部署目录
- 目标服务器安装器 `bash -n` 与代码/文档同步校验

当前限制：目标服务器已部署 PostgreSQL 版本并停留在首次安装向导。由于公网域名、TLS 入口和首个管理员密码属于部署方选择，本次没有代替用户提交向导；完成向导后应再次确认生产服务和登录流程。

```powershell
mvn -q test
docker compose config
docker compose up --build -d
docker compose ps
```

远程部署验收记录（2026-08-19）：CentOS Stream 8、Docker 26.1.3、Compose v2.27；旧项目容器、项目镜像和旧数据卷已删除，其他 Compose 项目与宿主机独立服务未改动。旧编译产物已通过 `clean test` 重建，项目源码与服务器目录的旧数据库关键词扫描为零。`postgres`、`redis`、`setup`、`server`、`web` 均为 healthy，`http://127.0.0.1:18080/healthz` 返回 `ok`，`/api/setup/status` 返回 `ready`。Compose 仅发布 Web 的 `18080` 端口；项目 PostgreSQL、Redis、Spring Boot 和 setup 端口保持内网。
