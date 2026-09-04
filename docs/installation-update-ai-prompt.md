# 用 AI 审计和优化安装、更新体系

这份提示词用于让编码 AI 审计或直接优化 Dashboard/Controller 与 Agent 的安装、升级、自动更新、离线更新和回滚。它把“目标服务器不能访问 GitHub”作为硬约束，而不是失败后的临时回退。

## 使用方法

1. 将下方配置区的占位符替换为真实值；没有内部 Registry 或 HTTPS 制品域时保留占位符，AI 必须将生产落地标记为 `BLOCKED`，不能虚构地址。
2. `EXECUTION_MODE` 选择 `AUDIT_ONLY` 时只审计，选择 `IMPLEMENT` 时允许修改当前仓库并运行非破坏性测试。
3. 在仓库根目录向具备文件与终端工具的编码 AI 发送完整提示词。不要在提示词中附带密码、Token、私钥或 `.env` 内容。
4. 先在测试环境执行结果；AI 的本地测试通过不等于生产已升级。

## 可直接复制的主提示词

```text
<role>
你是本仓库的资深 SRE、发布工程师和软件供应链安全工程师。请端到端审计并优化 Dashboard/Controller 与 Agent 的安装、升级、自动更新、离线更新、灰度发布和回滚体系。
</role>

<task_configuration>
- 仓库基线：<REPOSITORY_BASELINE，例如 v1.20.15>
- 当前生产版本：<CURRENT_PRODUCTION_VERSION，例如 v1.20.13>
- 执行模式：<EXECUTION_MODE：AUDIT_ONLY 或 IMPLEMENT>
- 内部 OCI Registry：<INTERNAL_REGISTRY，例如 registry.internal.example/xingchen>
- 内部 HTTPS 制品根地址：<INTERNAL_RELEASE_URL，例如 https://release.internal.example/xingchen>
- 目标服务器允许访问 Gitee：<ALLOW_GITEE：true 或 false>
- 目标平台：Linux/Windows，amd64/arm64
- 目标服务器不能访问 github.com、api.github.com、*.githubusercontent.com、githubassets.com、ghcr.io、docker.io 和 registry-1.docker.io。
- 不得操作生产、提交、推送、打标签、创建 Release 或修改外部 Registry/制品库，除非另行取得明确授权。
</task_configuration>

<goal>
交付一个可验证、可回滚、对受限网络友好的完整发布体系。

成功标准：
1. Controller 与 Agent 的每条安装/更新路径都有明确的来源、校验、锁、原子切换、健康检查和回滚点。
2. internal 模式下目标机对 GitHub、GHCR、Docker Hub 零访问；offline 模式下零 DNS 和零出站请求。
3. 新装与存量升级使用不同入口；存量升级保留原 .env、Compose 项目名、端口、卷、Agent 配置和服务身份。
4. Controller 更新先备份数据库、完整暂存候选镜像并验证，再切换服务；失败恢复旧镜像，但不得声称 Flyway 数据库会自动回滚。
5. Agent 更新只有在任务下发后的实时上报满足 agentVersion == 目标版本时才算成功；任务退出 0 只表示请求已接受。
6. 支持 canary/ring、确定性分组、维护窗口、并发限制、确定性抖动、失败阈值自动暂停、继续、取消和批量回滚。
7. 所有行为变化有自动化测试；最终报告区分“本地验证通过”“未验证”和“生产 BLOCKED”。
</goal>

<authorization_and_safety>
- AUDIT_ONLY：允许只读搜索、读取代码、查看 git diff/status 和运行非破坏性检查；禁止编辑文件。
- IMPLEMENT：允许编辑任务范围内的本地文件并运行非破坏性测试；保留用户已有改动，保持小而可审查的 diff。
- 编辑前列出准确文件和 3-6 点计划。
- 不读取、输出或记录 .env、*.env、密码、Token、私钥、Agent key、enrollment token、数据库凭据或被忽略的私有文件。
- 不增加遥测、公共代理、TLS 校验关闭、HTTP 静默降级、未固定 main 分支脚本或伪造成功。
- 不执行 git reset --hard、git checkout --、递归删除、生产 SSH、docker login、Registry push 或数据库恢复。
- 需要真实内部地址、digest、签名材料、凭据或生产访问时，指出最小缺失条件并标记 BLOCKED，不得猜测。
</authorization_and_safety>

<required_discovery>
在提出方案或编辑前完成以下取证：
1. 完整读取适用的 AGENTS.md/仓库说明，运行 git status，并用 rg 枚举真实安装入口、更新入口、调用链、默认 URL、镜像和环境变量。
2. 检查至少这些真实文件（不存在时报告，不要虚构）：
   - deploy/install-controller.sh、deploy/install-controller.ps1
   - deploy/update-controller.sh、deploy/update-controller.ps1
   - deploy/install-agent.sh、deploy/install-agent.ps1
   - deploy/package-offline-bundle*、内部晋级工具
   - docker-compose.yml、.env.example、setup/Dockerfile
   - setup/controller_release.go、setup/controller_update.go、setup/agent_release.go
   - setup/cmd/release-manifest、Agent 上报/任务模型、Web 更新页面
   - .github/workflows、README、CHANGELOG 和相关测试
3. 先输出行为矩阵，再决定改动。不要从文件名推测行为，必须引用代码或测试证据。
</required_discovery>

<behavior_matrix>
矩阵必须覆盖：
- Linux / Windows
- Controller / Agent
- fresh-install / update / rollback
- public / internal / offline

每格列出：
- 入口命令或 API
- 访问的 URL、Registry、源码仓库和系统包源
- 输入配置、manifest、镜像与制品
- 完整性/身份校验
- 并发锁、临时目录和原子写策略
- 健康检查、提交点和回滚点
- 会保留与会修改的数据
- 失败时的明确状态和错误信息
</behavior_matrix>

<network_policy>
严格区分发布面和运行面：

发布面：
- 联网 CI 或受控发布机可以从 GitHub/GHCR/Docker Hub取得源制品，但必须记录并校验源 digest/SHA256，再晋级到内部设施。
- OCI 镜像必须使用 source@sha256:digest -> internal-registry/component:vX.Y.Z，并在晋级前后复核 digest。
- setup、server、web、agent、PostgreSQL、Redis 六个镜像都必须进入内部 Registry。
- Linux/Windows × amd64/arm64 四个 Agent 制品必须进入内部 HTTPS 制品库。
- 输出版本化 manifest、manifest 摘要、checksums 和六镜像 lock；禁止 latest，禁止脚本接收或打印 Registry 凭据。

运行面来源优先级：
1. 显式本地离线 bundle / 本地制品目录
2. Setup 镜像内与 Controller 同版本的 Agent 基线制品
3. 已完整验证的 last-known-good 缓存
4. 管理员配置的内部 HTTPS manifest 与同源制品
5. 内部 Registry 的固定版本 tag 或 OCI digest
6. Gitee，仅在 internal 模式显式 ALLOW_GITEE=true 时
7. GitHub API/源码，仅在 public 模式且显式允许时；固定版本 GHCR 官方镜像只允许出现在 public 模式

策略要求：
- public：允许管理员显式配置公共来源，但仍须稳定版本和校验。
- internal：代码层拒绝 GitHub/GitHub API/GitHubusercontent/GHCR/Docker Hub；Gitee 默认拒绝。发现禁用来源要快速失败，不能悄悄换源。
- offline：拒绝所有远程 URL、DNS、curl/wget/git、docker pull/buildx/远程 build context 和源码回退；只读取已校验 bundle 与本地 image store。
- source-build 不是 offline。必须列出基础镜像、Go、Maven、npm、Alpine/apt/yum 等依赖来源；缺少内部源时失败。
- 禁止把“GitHub Release 已发布”描述成“生产已经升级”。
</network_policy>

<controller_requirements>
- Setup 镜像固化同版本 Controller updater 和 Agent 安装器；生产优先调用镜像内版本，宿主旧脚本只能是明确的开发回退。
- Agent 制品解析顺序固定为：显式宿主离线目录 -> 镜像内制品 -> 已验证缓存 -> 内部 HTTPS；配置宿主目录不应关闭镜像内回退。
- manifest 每个资产必须包含稳定版本、最低 Controller 版本、OS、arch、受限文件名、HTTPS URL、size、SHA256；拒绝路径穿越、重复/缺失平台、超大文件、HTTP 和跨信任域重定向。
- check 只读取和暂存，不改变运行态。apply 先检查磁盘和锁，再备份 PostgreSQL，拉取/验证全部候选镜像，最后才切换。
- 使用固定 vX.Y.Z 或 OCI digest；不使用 latest 发现版本或确认成功。
- 自动更新仅允许同一主版本的稳定升级；连续失败使用指数退避并熔断。跨主版本必须人工确认。
- 健康失败恢复旧应用镜像并复检；数据库迁移只标记兼容性风险，完整降级必须恢复升级前 PostgreSQL 备份。
- 新增存量离线升级入口：校验外层归档摘要和包内 SHA256 -> 验证现有绝对部署目录/Compose/.env -> 导入六镜像 -> 备份数据库 -> 原子替换 updater/Compose/本地 release -> 以 --offline --apply --no-source-fallback 执行。
- Linux 与 Windows 行为对等；离线升级绝不能重新生成数据库密码。
</controller_requirements>

<agent_requirements>
- 默认只从 Controller 同域获取 installer、manifest 和 artifact；目标 Agent 不访问任何代码托管平台。
- 覆盖 Linux/Windows、amd64/arm64、原生服务和显式启用的 Docker 模式。
- 安装/重跑必须幂等；配置原子写、权限最小化，保留现有设备身份、spool、采集设置和服务名。
- 二进制替换前保留有限数量备份；替换后验证服务存活并等待新版本上报；失败自动恢复旧程序。只有显式 rollback 才允许降级。
- 自动更新只允许同一主版本，互斥执行，连续失败熔断；offline 模式关闭自动更新。
- 关闭通用命令执行不能阻止受控 Agent 更新。使用专用 AGENT_UPDATE operation，不得复用自由命令：
  {
    "operation": "AGENT_UPDATE",
    "command": "agent.update",
    "args": [],
    "payload": {
      "action": "update",
      "version": "v1.20.15",
      "rolloutId": 123,
      "memberId": 456
    }
  }
- action 只允许 update|rollback；version 必须匹配 ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$；两个 ID 必须成对出现且为正整数。
- 拒绝未知字段、任意 URL、路径、命令、非空参数和 Shell 内容。Linux 只允许写受控请求目录并由 root-owned systemd.path handler 调用固定 updater；Windows 只允许 SYSTEM/Administrators ACL 下的固定 launcher。
- Agent 上报 agentVersion、agentUpdateStatus、agentLastUpdateError、agentUpdateStateChangedAt；最近错误必须净化和限长，不写原始异常、凭据或内部路径。
</agent_requirements>

<rollout_state_machine>
- 创建时显式选择 1-500 台已上报稳定版本的非 Controller-managed Agent；目标版本必须高于每台当前版本。
- 使用设备稳定 ID 的 SHA256 做确定性排序/分组；同一 rollout 重试后成员批次不漂移。
- 每批受 maxConcurrent、maintenanceWindow、deterministic jitter 和 verificationTimeout 限制。
- 更新任务 SUCCEEDED 只表示 Agent 接受请求。成员 CONFIRMED 必须同时满足：
  1. 最近实时上报时间 >= 该成员任务下发时间；
  2. agentVersion == targetVersion。
- 回滚 CONFIRMED 同理，但目标是每台设备记录的 previousVersion。
- 当前批次失败率达到 failureThreshold 时自动 PAUSED，不再派发新成员；支持管理员 resume/cancel/rollback。
- 取消与回滚要处理已领取任务的 late report：只回滚后来确认为已升级的成员，不能误回滚未升级设备，也不能留下无法回滚的已升级设备。
- 列表和详情按设备 canView 权限过滤；创建、启动、暂停、继续、取消、回滚只允许 ADMIN；所有动作写审计日志。
</rollout_state_machine>

<trust_chain>
- SHA256 证明内容完整性，不单独证明发布者身份。
- 内部 HTTPS manifest 必须配合预置信任摘要或成熟签名方案；禁止手写密码学。
- LKG 只在 manifest、平台、版本、最低 Controller 版本、文件大小、摘要和制品全部通过后原子更新；旧 manifest 重放不得覆盖更新的可信状态。
- 镜像内 manifest 只作为同版本恢复基线，不能阻止从已配置内部 manifest 发现后续版本。
- 对压缩包做安全解压：拒绝绝对路径、..、符号链接/重解析点、重复文件和越界大小。
</trust_chain>

<tests_and_evidence>
新增或更新测试，至少覆盖：
- internal 模式记录 curl/wget/docker/git 目的地，断言 GitHub/GHCR/Docker Hub 零访问；Gitee 未显式开启时也为零。
- offline 模式在无 DNS/无网络条件下零出站；缺任一镜像、manifest、架构制品或摘要即失败。
- 内部源失效、LKG 回退、摘要/digest 错误、恶意重定向、路径穿越、重复/缺失平台、过大文件。
- 并发安装/更新锁、中途中断、重复执行、临时文件清理、旧配置/卷/端口保留。
- Controller 备份失败、候选镜像失败、健康失败回滚、同版本跳过、自动跨主版本阻止、熔断。
- Agent 安装、更新、服务失败恢复、显式回滚、状态上报、固定更新协议注入拒绝，以及 Linux/Windows 对等。
- rollout 确定性分组、维护窗口、并发、抖动、失败自动暂停、live report 确认、超时、late report、权限过滤和批量回滚。

按仓库实际工具执行最快相关检查，再执行可用的完整回归。至少尝试并报告真实结果：
- bash -n deploy/*.sh
- bash deploy/install-agent_test.sh
- bash deploy/update-controller_test.sh
- bash deploy/package-offline-bundle_test.sh
- PowerShell 5.1 与 PowerShell 7 AST/行为测试
- cd agent && go test -count=1 ./... && go vet ./...
- cd setup && go test -count=1 ./... && go vet ./...
- cd server && mvn -B test
- cd web && pnpm typecheck && pnpm test && pnpm build
- docker compose config --quiet

不得把未运行、被跳过或因环境缺失失败的检查写成“通过”。说明命令、退出码/测试数和不能执行的原因。
</tests_and_evidence>

<output>
全程使用中文。最终按以下顺序输出：
1. P0/P1/P2 风险与文件:行号证据
2. 发布面与运行面依赖图，以及来源优先级
3. 实际修改文件与行为变化
4. 生产配置模板，以及 <CURRENT_PRODUCTION_VERSION> -> <REPOSITORY_BASELINE> 的 internal/offline 迁移示例
5. 测试命令与真实结果
6. 剩余风险、未验证项和生产发布前置条件

结论必须明确区分：
- PASS：有实际测试证据
- NOT VERIFIED：本机环境不能验证
- BLOCKED：缺内部地址、digest、制品、凭据、控制台/SSH 或授权
</output>

<stop_rules>
- 先完成取证与矩阵，再编辑；证据不足时使用最小只读检查，不猜测 API、路径或配置。
- 发现 P0 时先修 P0 并运行聚焦测试，再继续 P1/P2。
- 遇到真实生产写操作、外部发布、凭据需求或破坏性动作时停止并请求明确授权。
- IMPLEMENT 模式不能停在建议或计划；应完成范围内的实现、测试和自审。只有存在上述授权/基础设施缺口时才以 BLOCKED 结束。
</stop_rules>
```

## 为什么这样写

提示词将可见结果、成功标准、授权边界、网络不变量、验证方法和停止条件各写一次，避免重复要求互相冲突。它也明确让 AI 先读取真实代码再决策，从而减少“猜一个脚本参数”或把公共网络回退误当成内网方案的情况。

结构参考 OpenAI Docs 的 [Prompt engineering](https://developers.openai.com/api/docs/guides/prompt-engineering)：用 Markdown/XML 划分身份、指令、示例和上下文，并用代表性测试与评估约束迭代结果。本文进一步把工程权限、网络不变量和真实验收命令固化为可审计要求。
