# 星辰监控新手使用指南

这份指南面向第一次部署服务器监控系统的用户。你不需要提前安装 PostgreSQL、Redis，也不需要手工建表或执行 SQL。按照本文顺序完成后，你将拥有一套可以登录、接入服务器、查看指标、发送告警并自动备份和更新的监控系统。

如果你已经完成安装，只想查某项功能，可以直接跳到[控制台功能怎么用](#控制台功能怎么用)或[日常运维速查](#日常运维速查)。页面内也可以点击右上角问号进入“使用指南”，按功能名称搜索操作步骤。

## 1. 先了解三个概念

### 1.1 总控服务器

总控服务器运行 Web 控制台、服务端、安装与更新服务、PostgreSQL 和 Redis。管理员在浏览器里访问它，所有被监控服务器也向它上报数据。

总控通过 Docker Compose 运行以下组件：

- `web`：浏览器页面和反向代理入口，默认端口为 `18080`。
- `server`：处理登录、设备、指标、告警和通知。
- `setup`：负责首次配置、备份、恢复和总控更新。
- `postgres`：保存账号、配置、设备、指标和告警。
- `redis`：缓存和实时消息。
- `controller-agent`：仅 Linux 总控默认启用，用于采集总控宿主机指标。

PostgreSQL、Redis 和服务端端口默认只在 Docker 内网开放。公网只应开放 Web 入口。

### 1.2 被监控服务器和 Agent

每台被监控服务器安装一个 Agent。Agent 采集 CPU、内存、磁盘、网络、进程、端口和可选的容器信息，然后通过 HTTP(S) 主动连接总控。通常不需要在被监控服务器上开放入站端口。

### 1.3 设备 ID 和一次性接入令牌

在控制台“设备管理”中创建设备后，会得到设备 ID 和只显示一次的接入令牌。安装 Agent 时两者必须同时使用：

- 设备 ID 表示数据属于哪台设备。
- 接入令牌证明这次安装已获授权，15 分钟后过期且只能消费一次。
- 安装器交换得到的长期 Agent 密钥直接写入受限配置文件，不显示在安装命令中。

不要把接入令牌、Agent 密钥、API Token、管理员密码或 `.env` 内容发到聊天群、工单和截图中。

## 2. 推荐的首次部署顺序

第一次使用时，建议严格按下面的顺序操作：

1. 准备一台 Linux 总控服务器和一个域名。
2. 安装 Docker Engine 与 Docker Compose v2。
3. 克隆项目并运行总控安装器。
4. 打开 `/setup`，填写站点和管理员信息。
5. 登录控制台，创建第一个数据库备份。
6. 配置并测试至少一种通知渠道。
7. 创建设备，在目标服务器运行控制台生成的 Agent 命令。
8. 确认设备在线并有指标，再创建告警规则和服务监控。
9. 测试告警流程，最后启用每日自动备份和自动更新。

先接通数据再配置告警，可以避免因为设备尚未上报而误判故障。

## 3. 安装前准备

### 3.1 推荐配置

小规模使用可以从以下配置开始：

- 64 位 Linux，推荐当前受支持的 Ubuntu、Debian、Rocky Linux 或同类发行版。
- 2 核 CPU、4 GB 内存、至少 20 GB 可用磁盘。
- Docker Engine 24 或更高版本。
- Docker Compose v2，命令格式是 `docker compose`，不是旧版 `docker-compose`。
- 可访问总控所需的内部 Registry/制品服务或 Gitee；完全断网环境提前准备架构对应的离线 bundle。GitHub 不是目标服务器的必需依赖。
- 生产环境准备一个域名和有效 HTTPS 证书。

设备数量、指标保留时间和采集频率越高，磁盘使用量越大。生产环境应持续观察总控磁盘空间。

### 3.2 Linux 前置检查

在总控服务器终端执行：

```bash
docker --version
docker compose version
docker info
git --version
```

成功标准：四条命令都能正常返回，`docker info` 不出现连接守护进程失败。

如果普通用户执行 Docker 命令提示权限不足，可以临时在命令前加 `sudo`。是否把用户加入 `docker` 组应按你的服务器安全策略决定，因为该组接近 root 权限。

确认默认 Web 端口没有被占用：

```bash
sudo ss -lntp | grep ':18080' || true
```

没有输出表示端口通常可用。如果已经被其他程序占用，需要在首次启动前修改 `.env` 中的 `WEB_PORT`；不要等向导完成后再改端口。

### 3.3 Windows 前置检查

Windows 可以运行总控，但生产环境更推荐 Linux。若用于本机体验或测试：

1. 安装 Docker Desktop，并切换为 Linux containers。
2. 启动 Docker Desktop，等待状态显示引擎已运行。
3. 使用 PowerShell 检查：

```powershell
docker --version
docker compose version
docker info
git --version
```

Windows 总控不会自动采集 Windows 宿主机。完成总控安装后，还要把它当作普通 Windows 设备安装 Agent。

### 3.4 域名、端口和防火墙

生产环境推荐使用 `https://monitor.example.com` 这类域名。请提前完成：

- 域名 A/AAAA 记录指向总控公网地址。
- 防火墙或安全组放行 80/443；如果暂时直接访问 `18080`，只在初始化期间按需放行。
- Caddy、Nginx、Traefik、宝塔反向代理或云负载均衡器把 HTTPS 请求转发到 `127.0.0.1:18080`。
- 反向代理开启 WebSocket，并透传 `Host`、`X-Forwarded-Host`、`X-Forwarded-For`、`X-Forwarded-Proto`。

不要把 PostgreSQL、Redis 或 Spring Boot 端口直接暴露到公网。

## 4. 安装总控

### 4.1 Linux：从 Gitee 安装

```bash
git clone --depth 1 --branch v1.20.16 https://gitee.com/starchen520/monitor-for-server.git xingchen-monitor && cd xingchen-monitor && sudo bash ./deploy/install-controller.sh --build
```

### 4.2 Linux：能够访问 GitHub 时

```bash
git clone --depth 1 --branch v1.20.16 https://github.com/Pstarchen/monitor-for-server.git xingchen-monitor && cd xingchen-monitor && sudo bash ./deploy/install-controller.sh
```

安装器会自动完成这些工作：

1. `public` 模式自动补齐 curl、Docker Engine 和 Compose v2；`internal/offline` 只检查本地依赖。
2. 生成随机 PostgreSQL 凭据并写入私有 `.env`。
3. 优先从配置的受信内部 Registry 拉取固定版本镜像，再尝试镜像自身地址。
4. 镜像不可用时，仅按显式配置的 `XINGCHEN_SOURCE_REPOSITORIES` 顺序构建；默认不访问任何源码仓库。
5. 启动数据库和临时安装环境。
6. 等待 `http://127.0.0.1:18080/healthz` 健康检查通过。

安装完成后，终端会提示打开：

```text
http://<总控服务器IP>:18080/setup
```

### 4.3 Windows：运行总控安装器

在项目目录打开 PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\install-controller.ps1
```

确认 Docker Desktop 正在运行。如果命令提示无法连接 Docker daemon，先启动 Docker Desktop，再重新执行安装器。

### 4.4 安装器常用选项

Linux 和 Windows 选项一一对应：

| 用途 | Linux | Windows |
| --- | --- | --- |
| 安装后启用每日 04:00 自动更新 | `--auto-update` | `-AutoUpdate` |
| 使用当前目录源码构建 | `--build` | `-Build` |
| 跳过镜像，直接从双源码仓库构建 | `--source-build` | `-SourceBuild` |
| 跳过配置的镜像前缀 | `--no-mirror` | `-NoMirror` |
| 镜像失败后不回退源码构建 | `--no-source-fallback` | `-NoSourceFallback` |
| 清理本项目旧容器和本地镜像 | `--cleanup` | `-Cleanup` |

例如，Linux 首次安装并启用自动更新：

```bash
sudo bash ./deploy/install-controller.sh --auto-update
```

`--cleanup`/`-Cleanup` 会删除本项目旧容器和本地镜像，但保留 PostgreSQL、Redis 数据卷。它不是“恢复出厂设置”，也不会清空已有数据。

### 4.5 安装完成后的检查

Linux：

```bash
docker compose --profile host-monitoring ps
curl -fsS http://127.0.0.1:18080/healthz
```

Windows：

```powershell
docker compose ps
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:18080/healthz
```

成功标准：容器状态为运行中或 healthy，健康检查返回 HTTP 200。

## 5. 完成首次 `/setup` 向导

浏览器打开 `/setup` 后，只需要填写站点和第一个管理员。数据库已经由安装器准备好，不要在这里寻找数据库地址或密码输入框。

### 5.1 每个字段怎么填

| 字段 | 怎么填 | 示例和注意事项 |
| --- | --- | --- |
| 公网入口 | 用户和 Agent 实际访问的完整来源 | `https://monitor.example.com`；临时测试可填 `http://192.168.1.10:18080`。不能带路径、查询参数或末尾业务页面。 |
| 允许的 Web 来源 | 允许打开控制台的浏览器来源 | 通常与公网入口完全相同。多个来源使用英文逗号分隔，每项都写完整的 `http(s)://主机[:端口]`。 |
| 站点名称 | 页面和通知里显示的名称 | 例如“公司服务器监控”。 |
| 服务时区 | IANA 时区名称 | 中国大陆通常填 `Asia/Shanghai`。它影响告警、审计、维护窗口和定时任务时间。 |
| 管理员用户名 | 第一个登录账号 | 默认可用 `admin`，也可以改成不易猜到的名称。 |
| 管理员密码 | 至少 12 位的独立强密码 | 不要与服务器 SSH、邮箱或其他后台共用。 |
| 再次输入管理员密码 | 与上一项完全一致 | 建议使用密码管理器保存。 |

提交后，安装服务会写入生产 `.env` 并重建 `server` 和 `web`。页面短暂不可访问是正常现象，等待服务启动完成后刷新即可。

### 5.2 如果先用 IP、以后再换 HTTPS 域名

1. 先用 `http://<IP>:18080` 完成初始化。
2. 配置正式域名、证书和反向代理。
3. 登录后进入“系统设置 > 站点与部署”。
4. 把公网入口改为正式 HTTPS 地址并保存。
5. 确认服务端 `.env` 中的 `PUBLIC_BASE_URL` 和 `ALLOWED_ORIGINS` 都使用正式 HTTPS 来源，`SESSION_COOKIE_SECURE=true`。
6. 重建 Web 和服务端：

```bash
docker compose up -d --force-recreate server web
```

来源不一致时，浏览器可能出现登录失败、请求被拒绝或 WebSocket 无法连接。

## 6. 登录、公开状态页和账号角色

访问公网入口的根路径 `/` 会看到公开状态页；旧地址 `/status` 会自动跳转。点击登录入口，使用首次向导创建的管理员账号进入控制台。

### 6.1 三种角色

| 角色 | 适合谁 | 权限范围 |
| --- | --- | --- |
| ADMIN | 系统负责人 | 管理系统设置、账号、设备、规则、备份和更新。 |
| OPERATOR | 日常运维人员 | 管理被授权的设备、告警和任务，不能修改全局管理配置。 |
| VIEWER | 只读用户或值班查看账号 | 查看被授权设备的指标和告警。 |

创建普通账号：进入“账号权限”，点击“创建账号”，填写用户名、显示名称、角色和至少 12 位初始密码。对非管理员账号，再点击设备权限图标，逐台分配“查看数据、管理资料、处理告警、执行任务”。

### 6.2 修改自己的资料、密码和启用双因素认证

点击右上角用户菜单进入个人资料：

- 修改显示名称后保存。
- 修改密码时必须输入当前密码；成功后当前会话会轮换。
- 启用 TOTP 双因素认证时，先输入当前密码，使用身份验证器扫描二维码，再输入 6 位验证码确认。
- 停用双因素认证也需要当前密码和当前 6 位验证码。

建议至少为管理员账号启用双因素认证。

## 7. 接入第一台服务器

### 7.1 创建设备

1. 进入“设备管理”。
2. 点击“添加设备”。
3. 至少填写“设备名称”，例如“生产 API-01”。
4. 按实际情况填写主 IP、分组、位置、标签、环境、责任人和资产编号。
5. 决定是否在公开状态页展示；生产内部设备不需要公开时取消勾选。
6. 点击“创建设备”。

创建成功后会立即打开“Agent 接入”弹窗。不要先关闭它。

### 7.2 在 Agent 接入弹窗中选择参数

- “监控平台域名或地址”：应是目标服务器能够访问的总控地址，生产环境使用 HTTPS。
- 安装脚本固定从总控同域下载；目标服务器只需能访问总控，不需要连接 GitHub、Gitee 或公共 CDN。
- “Linux/Windows”：选择目标服务器真实系统。
- “采集周期”：新手建议保留 3 秒；设备很多或总控配置较低时可改为 10 秒或 30 秒。
- “磁盘白名单”：只想采集特定挂载点时填写，例如 Linux 的 `/, /data` 或 Windows 的 `C:\, D:\`。
- “轻量采集”：低配置或连接很多的服务器可启用，它会跳过进程和连接统计。
- “完整进程”：只有确实需要完整进程清单时启用，并设置合理上限。

参数选好后分别点击“复制令牌”和“复制安装命令”。命令包含正确的设备 ID 和总控地址，但不包含接入令牌或长期 Agent 密钥；执行安装器前会校验总控返回的 SHA256，安装器提权并准备好制品后再在终端中静默询问令牌。应优先使用该流程，不要手工拼接。

### 7.3 Linux 安装 Agent

1. SSH 登录刚才创建的目标服务器。
2. 粘贴控制台生成的整条命令并执行。
3. 安装器会请求 sudo 权限；按提示输入目标服务器自己的 sudo 密码。
4. 等待出现 Agent 已启动或状态检查提示。

控制台生成的命令形式大致如下，示例设备 ID 不能直接照抄：

```bash
curl -fsSL --max-redirs 0 --proto '=https' --proto-redir '=https' 'https://monitor.example.com/api/setup/agent-bootstrap?platform=linux&deviceId=123e4567-e89b-42d3-a456-426614174000&interval=3s' | bash
```

安装器默认用预编译程序注册本机 systemd 服务；只有命令中显式添加 `--docker` 才用容器模式。检查状态和日志：

```bash
/opt/xingchen/agent/agent.sh status
/opt/xingchen/agent/agent.sh logs
```

### 7.4 Windows 安装 Agent

1. 在目标 Windows 服务器上，以管理员身份打开 PowerShell。
2. 粘贴控制台“Windows”页签生成的单行短命令。
3. 等待脚本下载安装程序、写入配置并创建 `XingchenAgent` 服务。
4. 检查服务：

```powershell
Get-Service XingchenAgent
```

服务应为 `Running`。配置文件位于：

```text
%ProgramData%\XingchenMonitor\agent.json
```

Windows 没有预编译程序时，安装器需要 Git 和 Go 1.24+ 从源码构建；生产服务器更推荐通过 `-BinaryPath` 提供可信的预编译 `xingchen-agent.exe`。完整参数见[受监控服务器搭建材料](monitored-agent.md)。旧版主机会继续显示旧服务名和路径，重新运行安装命令即可平滑升级。

### 7.5 确认接入成功

回到“设备管理”并刷新。正常情况下，设备会从“待接入”变为“在线”，并显示主机名、IP、操作系统和最新资源使用率。

点击设备名称检查：

- “趋势与主机”有 CPU、内存、磁盘和网络数据。
- “磁盘”显示正确的挂载点。
- “进程、端口、容器、网卡”按 Agent 能力显示明细。
- “资产与记录”可记录交接、变更和现场处理信息。
- “状态时间线”会记录首次接入、离线和恢复。

若 1 分钟后仍是“待接入”，先看目标服务器 Agent 日志，再检查它能否访问 `<公网入口>/healthz`。

### 7.6 轮换密钥和重新安装

只有管理员能轮换密钥。轮换后旧密钥立即失效，因此应：

1. 在“设备管理”点击该设备的密钥图标。
2. 保存新密钥或复制新安装命令。
3. 立即到目标服务器重新运行安装器。
4. 确认设备重新在线后再关闭凭据弹窗。

修改设备名称、分组、资产信息不需要重装 Agent。总控中修改默认上报周期后，在线 Agent 会在下一次成功上报时同步。

## 8. 控制台功能怎么用

### 8.1 运行总览

“运行总览”适合每天先看一遍：

- 在线/离线设备数量是否符合预期。
- CPU、内存、磁盘压力排行中是否有异常节点。
- 最近告警是否有未处理项。
- 服务监控是否出现失败或延迟升高。

点击设备或告警可以进入详细页面。总览是快速定位入口，不替代设备详情和告警事件中的完整信息。

### 8.2 设备管理和设备详情

设备列表支持按名称、地址、分组、标签、环境、在线状态和健康状态筛选，也可以导出当前筛选结果为 CSV。

设备详情常用页签：

- “趋势与主机”：查看时间范围内的资源曲线、温度、SMART 和主机信息。
- “资产与记录”：维护责任人、位置、保修期以及运维工作记录。
- “磁盘”：查看空间、读写速率和 SMART 状态。
- “进程”：查看进程快照及选中进程的趋势。
- “服务”：查看 Agent 配置中声明的系统服务状态。
- “端口”：查看监听地址、端口和 PID。
- “容器”：查看 Docker 容器状态、资源和网络吞吐。
- “安全巡检/自定义项”：查看 Agent 显式配置的安全和自定义采集结果。

### 8.3 创建告警规则

进入“告警规则”，点击“新建规则”：

1. 填写容易理解的名称，例如“生产节点 CPU 持续过高”。
2. 选择全部设备或某一台设备。运维账号只能选择有权限的设备。
3. 选择指标，例如 CPU、内存、磁盘、设备离线、TCP 连接数、SMART 失败磁盘、进程缺失、服务异常或自定义指标。
4. 对数值指标填写阈值；对进程、服务或自定义项填写与 Agent 上报完全一致的目标名称。
5. 选择“提示、警告、严重”级别并启用规则。
6. 保存后观察实际运行情况，再逐步调整阈值。

建议先用较宽松阈值观察一天，避免一开始产生大量无意义告警。设备离线阈值还会受到“系统设置 > 监控策略”中的离线判定影响。

### 8.4 处理告警事件

“告警事件”会显示级别、设备、规则、触发值、通知状态和处理人。

- “确认”表示有人已经接手，不表示故障恢复。
- 指标回到正常范围或服务探测恢复后，系统才会自动标记已恢复。
- 可以筛选待处理告警并批量确认。
- 通知列显示已发送或被维护窗口静默。

正确流程是：确认告警、进入设备/服务详情定位、处理故障、等待系统检测恢复，并在需要时补充设备工作记录。

### 8.5 维护静默

计划发布、重启或机房检修前，进入“维护静默”创建窗口：

1. 填写窗口名称和原因。
2. 选择全部设备、指定设备以及可选的规则范围。
3. 选择开始和结束时间，核对时区。
4. 选择仅一次、每天或每周；重复窗口可设置结束时间。
5. 启用并保存。

窗口内仍会记录告警，只暂停通知。窗口结束时如果故障仍未恢复，系统会补发通知。维护静默不是关闭监控。

### 8.6 配置服务监控

“服务监控”从总控主动探测目标，适合监控网站、端口、数据库握手、网络设备和外部任务。

常见选择：

| 目标 | 探测类型 | 目标示例 |
| --- | --- | --- |
| 网站健康接口 | HTTP GET | `https://example.com/health` |
| 主机是否可达 | ICMP Ping | `192.168.1.20` |
| TCP 端口 | TCPing | `example.com:443` |
| FTP/SFTP | FTP 或 SFTP/SSH 握手 | `ftp.example.com:21`、`host:22` |
| 网络设备 | SNMP v2c | `switch.example.com:161` |
| Redis/PostgreSQL/MySQL | 对应协议握手 | `db.example.com:5432` |
| cron、备份、CI | 外部心跳 | 保存后复制系统生成的命令 |

创建时还要设置：

- 探测间隔和超时。
- 连续失败次数，避免单次网络抖动立即报警。
- 延迟阈值。
- HTTPS 证书到期天数。
- HTTP 期望状态码和响应体必须包含的文字。
- 是否在公开状态页显示。

保存普通探测后可点击“立即探测”验证。外部心跳令牌只在创建时显示一次，应立即把生成的 `curl` 命令放进 cron、CI 或备份脚本的成功末尾。

### 8.7 配置通知

只有管理员可以修改通知。进入“系统设置”，选择邮件、钉钉、企业微信或通用 Webhook：

1. 填写服务商提供的主机、Webhook 或凭据。
2. 开启对应通道。
3. 先点击页面顶部“保存设置”。
4. 再点击“发送测试邮件/消息”。
5. 到实际收件箱或群机器人确认收到。
6. 在“最近投递记录”查看成功、失败原因；失败项可使用当前配置重试。

通用 Webhook 支持通用 JSON、Slack、Discord、飞书/Lark 和纯文本格式。敏感字段留空保存时会保留旧值；不要为了“确认内容”反复覆盖已工作的密钥。

### 8.8 网络发现

“网络发现”从总控扫描私网，适合补齐不知道具体地址的设备：

1. 输入 RFC1918 私网 CIDR，例如 `192.168.1.0/24`。
2. 输入要探测的端口，例如 `22, 80, 443, 8080`，最多 32 个。
3. 新手保留默认超时和并发，点击“开始扫描”。
4. 等待任务完成，查看可达地址、开放端口和延迟。
5. 对确认属于自己的主机点击“使用地址添加设备”。

只支持 `/24` 到 `/32` 的 RFC1918 私网，不会扫描公网。扫描结果只是发现线索，添加设备后仍要安装 Agent 才会有完整主机指标。

### 8.9 网络拓扑和运行报告

网络拓扑根据服务监控的可解析目标自动生成关系。先创建服务监控，再到“网络拓扑”点击节点查看相关探测和影响范围。

“运行报告”可选择 24 小时、7 天或 30 天，查看节点资源压力、服务可用率和告警活动，并导出 CSV。没有数据时先确认 Agent 和服务监控已经运行足够时间。

### 8.10 动态域名解析（DDNS）

DDNS 通过 Webhook 把 Agent 上报的新 IP 推给你的 DNS 服务：

1. 进入“动态域名解析”，新建配置。
2. 填写名称、域名、请求方式和 Webhook URL。
3. 按 DNS 服务接口填写请求头 JSON、请求体模板和凭据。
4. 模板可使用页面提示的 `#domain#`、`#ip#`、`#type#`、`#record#`、`#access_id#`、`#access_secret#`。
5. 先保存并测试更新。
6. 回到“设备管理”编辑目标设备，启用 DDNS 并关联该配置。

更新已有 DDNS 配置时，凭据字段留空会保留旧值。先测试成功再启用，避免错误模板批量修改 DNS。

### 8.11 API Token

API Token 用于移动端、脚本或 MCP 客户端，不要用管理员 Cookie 代替：

1. 进入“API Token”，点击“创建 Token”。
2. 填写能识别用途的名称。
3. 从默认只读权限开始，只勾选客户端确实需要的 scope。
4. 可填写服务器 ID 白名单；留空表示不额外限制设备，但仍受账号本身权限约束。
5. 设置有效期，生产环境不建议无期限。
6. 创建后立即复制明文或完成二维码绑定。

明文关闭后不能再次查看。如果泄露或不再使用，立即吊销；使用它的客户端会马上失去访问权限。

### 8.12 任务执行

任务执行可以远程运行受控命令，默认关闭，风险较高。只有确实需要时才在目标 Agent 安装参数中加入：

- Linux：`--allow-command-execution`
- Windows：`-AllowCommandExecution`

然后在“任务执行”中选择有权限的设备，分别填写命令和参数。参数必须每行一个，不使用管道、重定向、`&&` 等 Shell 语法，因为命令不会经过 Shell 解析。设置合理超时和输出上限，创建后查看排队、运行、成功/失败、标准输出和标准错误。

不要对不可信设备启用命令执行，也不要用它代替成熟的配置管理和发布系统。

### 8.13 审计日志

管理员可在“审计日志”按操作者、动作、目标或摘要搜索关键变更。发现异常操作时，先停用或收紧相关账号权限，再修正配置。审计日志用于追溯，不等于数据库备份。

## 9. 备份、恢复和更新

### 9.1 第一次备份

完成首次配置后，进入“备份与恢复”，点击“立即备份”。等待状态回到“就绪”，并确认“可用备份”出现一个 PostgreSQL SQL 文件。

备份文件位于总控项目目录的 `backups/`，默认权限为 `0600`。它和 `.env` 都包含敏感信息，应限制服务器目录权限，并把备份定期复制到独立存储。只保存在同一块硬盘上不能防止主机磁盘损坏。

### 9.2 自动备份

在“备份与恢复”中：

1. 开启“每天 03:00 自动创建”。
2. 设置保留数量，允许 1 到 100，建议从 7 开始。
3. 点击“保存策略”。

任务按“服务时区”执行。超出保留数量后会删除最旧的 SQL 文件，因此长期归档需要另行同步。

### 9.3 恢复备份

恢复会停止 `server` 和 `web`，并用选中的 SQL 覆盖当前监控数据库：

1. 先确认选中的文件时间和故障发生时间。
2. 如果当前数据库仍可用，先额外保留一份当前备份。
3. 点击目标文件的“恢复”并确认。
4. 等待任务完成和服务自动重启。
5. 重新登录，检查账号、设备、规则和最新数据。

恢复期间控制台暂时不可访问是正常现象。不要重复点击恢复或同时执行总控更新。

### 9.4 在控制台更新总控

管理员进入“系统设置 > 系统更新”：

1. 先到“备份与恢复”创建升级前备份。
2. 点击“检查更新”。
3. 查看当前版本、最新稳定版本、发布时间和 Release 说明。
4. 确认确实有新版本后点击“立即更新”。
5. 控制台重启期间耐心等待；恢复后页面会自动刷新状态。
6. 检查总控组件版本、设备在线状态和通知投递。

稳定版本使用 `vX.Y.Z`。发布流程只有在 setup、server、web 和 Agent 的同版本镜像全部构建完成后才发布制品和离线包；目标服务器通过本地或内部 HTTPS manifest 发现版本，不依赖 GitHub API。控制台会显示 manifest 来源及 last-known-good 缓存状态。

### 9.4.1 更新页面的逐项操作和判断标准

不要把“立即更新”当成普通的保存按钮。它会启动总控更新任务，并按顺序重建和重启服务。建议在维护窗口内由一名管理员完成，另一名值班人员负责观察：

1. **确认当前状态**：在“系统更新”页先看当前版本、最新稳定版本、最近检查时间和服务列表。若已经显示“正在检查”或“正在更新并重启”，不要再次点击任何更新按钮。
2. **创建升级前备份**：进入“备份与恢复”，点击“立即备份”。只有当状态回到“就绪”，并且“可用备份”中出现刚刚生成的 SQL 文件时，才继续下一步。记录文件时间和文件名。
3. **检查候选版本**：返回“系统更新”，点击“检查更新”。等待按钮结束加载，确认出现“发现可用更新”，核对目标版本、发布时间和 Release 说明。若目标版本低于当前版本，先停止并确认是否真的需要降级。
4. **检查变更窗口**：确认没有人在执行数据库恢复、Agent 密钥轮换、批量任务或其他发布操作；通知值班人员控制台会短暂不可访问。
5. **启动更新**：点击“立即更新”，在确认框中阅读“拉取镜像、依次重启服务、不会删除监控数据”的提示，确认无误后点击“开始更新”。一次点击即可，不要刷新后重复提交。
6. **等待重启**：更新状态会变为“正在更新并重启”。这段时间出现登录失败、首页打不开或 WebSocket 断开属于预期现象。通常等待 2-5 分钟；不要手工启动旧容器，也不要同时执行恢复。
7. **验证服务版本**：页面恢复后重新进入“系统设置 > 系统更新”，确认 setup、server、web 版本一致，健康状态均为“运行正常”。
8. **验证业务链路**：依次打开运行总览、设备管理、告警事件和通知投递记录，确认至少一台设备重新在线、趋势产生新数据、告警列表可读、测试通知可以发送。
9. **记录结果**：把升级前后的版本、开始/完成时间、备份文件名和异常信息写入交接记录。没有完成业务验证前，不要关闭维护窗口。

出现问题时按下面顺序收集信息：

```bash
docker compose --profile host-monitoring ps
docker compose logs --tail 100 setup
docker compose logs --tail 100 server
docker compose logs --tail 100 web
curl -fsS https://<你的域名>/healthz
```

如果控制台仍可访问，优先查看“系统更新”页的错误提示和服务状态；如果控制台不可访问，先看 `setup` 日志和 `/healthz`，不要连续重试。更新任务失败不会删除数据卷，但失败时也不会自动切回旧镜像，因为新版本可能已经执行数据库迁移。需要降级时，先确认目标版本兼容性，再结合升级前 PostgreSQL 备份恢复。

### 9.5 命令行检查和更新

Linux：

```bash
sudo bash ./deploy/update-controller.sh --check
sudo bash ./deploy/update-controller.sh --apply
```

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\update-controller.ps1 -Check
powershell -ExecutionPolicy Bypass -File .\deploy\update-controller.ps1 -Apply
```

`--check`/`-Check` 只准备候选镜像并报告，`--apply`/`-Apply` 会应用并重启总控服务。

自动更新在控制台开启后每天 04:00 按服务时区执行。更新过程不会删除 PostgreSQL 和 Redis 数据卷。

### 9.6 为什么更新失败后不自动切回旧镜像

服务端启动时，Flyway 可能已经对数据库执行了前向迁移。旧应用镜像不一定兼容新数据库结构，因此“切回旧镜像”不等于安全回滚，反而可能造成第二次故障。

需要降级时，必须先确认目标版本的数据库兼容性；必要时同时恢复升级前 PostgreSQL 备份和对应版本镜像。不要只改镜像标签后直接启动旧版本。

## 10. 日常运维速查

### 10.1 总控状态和日志

```bash
docker compose --profile host-monitoring ps
docker compose logs --tail 100 setup
docker compose logs --tail 100 server
docker compose logs --tail 100 web
docker compose logs --tail 100 controller-agent
```

持续查看服务端日志：

```bash
docker compose logs -f --tail 100 server
```

健康检查：

```bash
curl -fsS http://127.0.0.1:18080/healthz
curl -fsS https://monitor.example.com/healthz
```

### 10.2 Linux Agent 管理

```bash
/opt/xingchen/agent/agent.sh status
/opt/xingchen/agent/agent.sh logs
/opt/xingchen/agent/agent.sh restart
/opt/xingchen/agent/agent.sh update
/opt/xingchen/agent/agent.sh list-versions
/opt/xingchen/agent/agent.sh rollback v1.20.4
```

默认卸载会保留配置和离线缓存：

```bash
/opt/xingchen/agent/agent.sh uninstall
```

彻底删除配置和缓存：

```bash
/opt/xingchen/agent/agent.sh uninstall --purge
```

`--purge` 不可恢复，执行前确认目标确实是要移除的 Agent。

### 10.3 Windows Agent 管理

```powershell
Get-Service XingchenAgent
Restart-Service XingchenAgent
sc.exe query XingchenAgent
sc.exe qc XingchenAgent
```

更新和回退：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\install-agent.ps1 -Action update
powershell -ExecutionPolicy Bypass -File .\deploy\install-agent.ps1 -Action list-versions
powershell -ExecutionPolicy Bypass -File .\deploy\install-agent.ps1 -Action rollback -Version v1.20.4
```

重新运行控制台生成的安装命令可以更新配置和程序。Windows Agent 配置目录为 `%ProgramData%\XingchenMonitor`，程序目录为 `%ProgramFiles%\XingchenMonitor`；更新前会保留 `.backup`，新服务启动失败会自动恢复。

### 10.4 推荐检查频率

- 每天：查看离线设备、严重告警、服务失败和通知投递失败。
- 每周：检查磁盘增长、备份是否持续成功、未使用 Token 和长期未处理告警。
- 每月：检查新版本 Release、账号权限、管理员双因素认证、证书到期和恢复演练计划。
- 重大更新前：创建备份、记录当前版本、阅读 Release 说明并预留维护窗口。

## 11. 常见问题排查

### 11.1 安装器提示找不到 Docker 或 Compose

现象：提示 `Docker Engine and Docker Compose v2 are required`。

检查：

```bash
docker --version
docker compose version
docker info
```

处理：安装或启动 Docker Engine。Windows 要确认 Docker Desktop 正在运行 Linux containers。旧命令 `docker-compose` 存在不代表 Compose v2 可用。

### 11.2 总控容器启动了，但网页打不开

依次检查：

```bash
docker compose ps
docker compose logs --tail 100 web
curl -v http://127.0.0.1:18080/healthz
```

- 本机健康、外部不通：检查安全组、防火墙、端口映射和反向代理。
- 本机也不通：查看 `web`、`server`、`setup` 日志。
- HTTPS 页面 502：检查反向代理目标是否为正确的 `WEB_PORT`，以及容器是否已健康。

### 11.3 `/setup` 提交后暂时 502 或页面断开

向导提交后会重建生产服务，短暂中断属于正常现象。等待 30 到 120 秒，检查：

```bash
docker compose ps
docker compose logs --tail 100 setup
docker compose logs --tail 100 server
```

不要反复提交向导。若服务日志明确报错，再按日志处理。

### 11.4 登录后立即退出、403 或 WebSocket 断开

重点核对公网入口和允许来源是否为浏览器地址的同一来源，包括协议和端口：

- `https://monitor.example.com` 与 `http://monitor.example.com` 不同。
- `https://monitor.example.com` 与 `https://monitor.example.com:8443` 不同。
- HTTPS 站点需要安全 Cookie 和正确的 `X-Forwarded-Proto`。

修正后重建：

```bash
docker compose up -d --force-recreate server web
```

### 11.5 设备一直“待接入”或突然离线

在目标服务器检查 Agent 状态和日志，并测试：

```bash
curl -v https://monitor.example.com/healthz
```

常见原因：总控地址写错、DNS 解析失败、证书不受信任、出口防火墙阻断、设备 ID/密钥不匹配、管理员已经轮换密钥、Agent 服务未运行。

密钥问题不要反复猜测。管理员直接轮换一次，使用新生成的完整命令重新安装。

### 11.6 设备在线，但看不到进程、容器或磁盘

- 进程为空：检查是否启用了轻量采集或 `--skip-processes`。
- 端口为空：检查是否使用 `--skip-ports`，以及 Agent 权限。
- 容器为空：Agent 可能无法访问 Docker/Podman socket；主机指标仍可正常工作。
- 某个磁盘缺失：检查安装命令的磁盘白名单；留空通常表示按默认策略采集。
- SMART 缺失：目标机需要 `smartctl` 和读取设备的权限；虚拟磁盘通常没有 SMART。

### 11.7 告警触发了，但没有通知

1. 查看告警事件的通知列，确认是否被维护窗口静默。
2. 进入“系统设置”确认通道已启用并保存。
3. 发送测试通知。
4. 查看“最近投递记录”的服务商返回或错误信息。
5. 检查 SMTP、Webhook 允许列表、签名密钥和出站网络。

“确认告警”不会阻止后续恢复通知；维护窗口才负责按时间范围静默通知。

### 11.8 检查更新显示缓存或发布源不可用

版本检查缓存 20 分钟是正常设计。内部 manifest 或显式启用的外部源临时失败时会保留 last-known-good 缓存并显示提示。判断发布是否完整时，应同时检查 manifest、四个应用镜像、PostgreSQL/Redis 依赖镜像和四个平台 Agent 制品。

命令行更新失败时查看输出中的具体镜像源。更新器按配置的内部镜像、镜像自身地址和源码仓库顺序回退；完全断网环境应使用离线 bundle，不要等待公共源超时。

### 11.9 数据库恢复或更新后控制台暂时不可用

恢复和更新都会重启服务。先观察任务和容器状态，不要同时发起第二个恢复或更新：

```bash
docker compose ps
docker compose logs --tail 200 setup
docker compose logs --tail 200 server
```

如果数据库迁移已经发生，不要擅自切回旧镜像。使用升级前备份并按版本兼容性方案恢复。

## 12. 安全和数据边界

- 生产环境使用 HTTPS，不让 Agent 通过公网明文 HTTP 上报。
- 不公开 PostgreSQL、Redis、Docker socket 和 Spring Boot 端口。
- `.env`、`backups/`、Agent 配置、长期 Agent 密钥和 API Token 都按凭据保护。
- 管理员使用独立强密码和 TOTP；普通人员按最小角色和设备权限分配。
- API Token 使用最小 scope、设备白名单和有效期，不再使用时立即吊销。
- 只有可信服务器才启用命令执行和文件操作能力。
- Docker socket 即使只读挂载也具有较高风险，只在受信任主机上启用容器采集。
- 备份至少保留一份在总控主机之外，并定期做恢复演练。
- 删除设备会同时删除关联监控数据和告警；操作前确认对象和备份。
- Agent `uninstall --purge` 会删除本机配置和离线缓存；普通 `uninstall` 会保留它们。
- 总控安装器的 `--cleanup` 只清理本项目容器和本地镜像，保留数据库卷；它不是完整卸载。

## 13. 继续深入

- [部署与完整运维参考](deployment.md)
- [总控服务器搭建材料](controller-server.md)
- [受监控服务器与 Agent 参数](monitored-agent.md)
- [系统架构与安全边界](architecture.md)
- [HTTP 与 WebSocket API](api.md)
- [华为 HarmonyOS Push Kit V3 接入](huawei-push-kit.md)
