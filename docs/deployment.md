# 部署与运维

第一次部署请先阅读[新手使用指南](user-guide.md)，其中包含逐步安装、首次配置、控制台使用、备份更新和按症状排错。材料也已按角色拆分：总控管理员可阅读[总终端服务器搭建材料](controller-server.md)，接入服务器时阅读[受监控服务器搭建材料](monitored-agent.md)。本页保留完整的运维参考和高级参数。

## 前置条件

- Linux Controller 使用 root/sudo 运行。`public` 模式可通过受支持的发行版包管理器自动安装 `curl`、Git、Docker Engine 24+ 与 Docker Compose v2；传入 `--no-install-dependencies` 后只检查、不安装。
- `internal` 与 `offline` 不访问公网软件包源，必须由内部配置管理预装依赖，或直接使用包含所需镜像的已校验离线 bundle。
- Docker Compose 会自动启动 PostgreSQL 16 和 Redis。数据库、用户和密码由控制端安装器自动生成，数据库端口只在 Compose 内网可见，无需安装数据库客户端或执行 SQL。
- 生产域名和 TLS 证书；生产环境不得直接暴露明文 HTTP。仅首次用 IP 初始化时可按总终端安装材料显式启用临时 HTTP。
- Linux 被监控主机默认使用 systemd 安装从总控同域获取并校验的预编译 Agent，不要求 Go 或 Git。只有管理员显式配置受信源码仓库并启用源码回退时，才需要 Go 1.24+ 与 Git；只有显式使用容器模式时才要求 Docker Engine。
- Windows 被监控主机需要 Windows 服务管理权限；Windows Docker Desktop 不能代表 Windows 宿主机，因此仍使用原生 Agent。

## Docker Compose 部署

Linux 生产环境推荐使用 `deploy/xingchen.sh`。它保留一条命令准备环境、Docker Compose 编排和统一运维的体验，但入口固定到稳定版本，不执行代码托管平台的可变 `raw main`，也不以 `latest` 判定升级。

能够访问 GitHub 和 GHCR 时：

```bash
curl -fsSL --proto '=https' --tlsv1.2 'https://raw.githubusercontent.com/Pstarchen/monitor-for-server/v1.20.19/deploy/xingchen.sh' -o xingchen.sh && chmod +x xingchen.sh && sudo ./xingchen.sh install --version v1.20.19
```

中国大陆服务器或无法访问 GitHub/GHCR 时：

```bash
curl -fsSL --proto '=https' --tlsv1.2 'https://gitee.com/starchen520/monitor-for-server/raw/v1.20.19/deploy/xingchen.sh' -o xingchen.sh && chmod +x xingchen.sh && sudo CN=true ./xingchen.sh install --version v1.20.19
```

`CN=true` 固定使用 Gitee 的对应版本编排文件，并直接从 `ccr.ccs.tencentyun.com/xc_monitor` 拉取 setup、server、web、agent、PostgreSQL 和 Redis 六个多架构镜像，不访问 GitHub、GitHub API、GHCR 或 Docker Hub，也不在目标机编译应用。该模式仍然联网：依赖补齐需要 Linux 发行版包源，运行镜像需要腾讯云 TCR。所有这些外部源都不可达时必须改用内部源或离线 bundle。默认安装目录是 `/opt/guanlan-monitor`，可通过 `--install-dir <绝对路径>` 修改。

高级或配置管理场景可以取得完整仓库后直接运行底层安装器。安装器会自动生成数据库与总控 Agent 凭据，将本机作为“总控服务器”显示到“设备管理”。未完成安装时，服务会以临时 bootstrap 配置启动，Web 只提供 `/setup` 向导：

```bash
bash ./deploy/install-controller.sh
docker compose --profile host-monitoring ps
```

在 `public` 模式运行上述命令时，缺少的 `curl`、Git、Docker Engine 或 Compose v2 会先通过受支持的系统包管理器安装。要禁止安装器修改系统软件包，使用：

```bash
bash ./deploy/install-controller.sh --no-install-dependencies
```

`internal/offline` 会隐式采用同等的“只检查”策略，绝不为了补依赖访问发行版公网镜像；依赖不完整时应先接入内部包源并由运维系统安装，或改用已校验离线 bundle。

需要从当前工作区源码构建总控镜像时：

```bash
bash ./deploy/install-controller.sh --build
```

`--build` 仍可能访问 Docker 基础镜像和 Go/Maven/npm 包源，因此不是离线模式。完全断网必须使用已校验的离线 bundle；内部源码构建则要把所有基础镜像与包管理源一并配置为内部可达地址。

需要跳过镜像仓库并直接从已配置源码仓库构建 Docker 镜像时：

```bash
bash ./deploy/install-controller.sh --source-build
```

然后打开：

```bash
http://<服务器IP>:18080/setup
```

安装器会生成 PostgreSQL 凭据并启动数据库。首次向导只需配置站点入口、来源、时区和首个管理员；Web 端口、绑定地址和 Compose 项目名在总终端启动前确定。向导写入生产 `.env` 后会同时重建 `server` 和 `web`，因此提交后会进入公开状态页，不会回到 Setup 或出现 502；服务完全就绪后可从状态页进入登录控制台。Flyway 在服务端启动时创建或升级表结构。数据库凭据只写入总终端私有配置，不会进入日志。

Linux 总终端不需要单独安装 Agent。安装器启动的 `controller-agent` 通过本机网关上报宿主机指标，生产服务就绪后“设备管理”会出现“总控服务器”。它读取宿主机而非容器的 CPU、内存、网络和磁盘信息；不要在控制台轮换或删除这台系统管理设备。

### 站点信息配置

首次向导中的字段直接决定浏览器、反向代理和 Agent 的访问方式：

- `站点名称`：登录页、侧栏和通知中显示的产品名称。
- `网站图标`：浏览器标签页显示的图标，默认使用 `/favicon.svg`；也可以填写站内路径或 HTTPS 图片地址，或上传不超过 50MB 的图片文件。上传文件保存在总控持久卷中。
- `公网入口`：用户和 Agent 实际访问的完整地址，例如 `https://monitor.example.com` 或临时初始化用的 `http://<服务器IP>:18080`；不要填写路径、查询参数或片段。
- `允许的 Web 来源`：逗号分隔的浏览器来源，必须包含公网入口；有多个域名时逐项填写完整的 `http(s)://host[:port]`。
- `服务时区`：使用 IANA 名称，例如 `Asia/Shanghai`，用于告警和审计时间展示。
- Web 端口与绑定地址由总终端安装器在首次启动前写入 `.env`，默认是 `18080` 和 `0.0.0.0`。只通过宝塔/Caddy/Nginx 反代时，在安装器启动前将绑定地址改为 `127.0.0.1`。浏览器向导不会再修改这两项，避免提交时切断当前页面。

正式域名和 TLS 生效后，在“系统设置”同步修改站点入口，确保 `PUBLIC_BASE_URL`、`ALLOWED_ORIGINS` 使用 HTTPS 且来源完全一致，并执行 `docker compose up -d --force-recreate server web`。不要把数据库密码、Agent 密钥或管理员密码写进站点地址。

安装完成后，直接访问 `PUBLIC_BASE_URL` 对应的域名根路径即可进入公开状态页，不需要追加 `/status`。安装向导会同时重建 `server` 和 `web`，确保当前源码中的根路径规则已生效。若是已有实例升级了这项规则，请执行：

```bash
docker compose up -d --build --no-deps server web
```

旧的 `/status` 和 `/status/` 地址会自动重定向到根路径。

无法使用浏览器时，命令行安装器仍然可用：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\install-controller.ps1
```

Linux：

```bash
bash ./deploy/install-controller.sh
```

安装成功后会创建 `/usr/local/bin/xingchen`，可以直接执行统一管理动作：

```bash
sudo xingchen status
sudo xingchen logs
sudo xingchen restart
sudo xingchen update
```

不带动作运行 `sudo xingchen` 会打开交互菜单。`status` 展示 Compose 服务状态，`logs` 显示最近 200 行总控日志，`restart` 重新创建并等待现有服务健康，`update` 执行稳定版本更新。快捷命令会从实际安装脚本推断自定义部署目录；管理器沿用已有制品源、Git origin（若存在）、镜像前缀和网络策略。已有部署无需包含 `.git`，明确指定稳定版本时也不需要查询 Git。`restart` 与重复安装尊重 `CONTROLLER_AGENT_ENABLED=false`，保留已有宿主 Agent 名称和分组。

只有显式 `--source gitee|github` 才会改用对应的在线来源。切源时，即使版本号相同，更新器也会核对容器实际使用的镜像引用并重新部署。已有 `internal/offline` 部署不能通过普通 `xingchen update` 隐式改成公网模式，应继续使用底层更新器或离线 bundle。

### 在线更新

从 `v1.20.19` 起，控制台与 `xingchen update` 通过同一在线引导器更新。已完成该版本安装或迁移的在线部署，优先在“系统设置 → 系统更新”中检查并更新，或运行 `sudo xingchen update`；需要固定目标时使用 `sudo xingchen update --version v1.20.19`。升级后确认 setup、server、web 及已启用的 controller-agent 版本一致、服务健康。

引导器拉取已配置仓库中目标版本的 Setup 镜像，检查 OCI 版本、实际架构和本地镜像 ID；从该固定 ID 提取更新包，校验六个受管文件的 SHA256 后，运行包内的新版更新器。更新包包含目标 Compose、Linux/Windows 更新器、在线引导器和管理命令。整个过程持有同一文件锁，不依赖服务器上的源码仓库，也不会因镜像拉取失败转为源码构建。

已包含在线引导器的部署，可先对已选版本执行在线预检。下面的版本号需替换为实际已发布且包含更新包的版本：

```bash
sudo bash ./deploy/bootstrap-controller-update.sh --project-root /opt/guanlan-monitor --version vX.Y.Z --check
sudo xingchen update --install-dir /opt/guanlan-monitor --source gitee --version vX.Y.Z
```

`--check` 拉取并验证候选镜像和部署文件，不修改 `.env` 或重启现有服务；它沿用当前网络策略，不能用于把 `offline` 部署切到在线。显式 `--source gitee` 才会将离线安装迁移到 `public` 模式，使用 Gitee 发现稳定版本、腾讯云 TCR 提供六个镜像；只有候选验证和备份完成后才写入新网络策略，同时清除旧的固定 manifest 配置。该切换不要求访问 GitHub、GHCR 或 Docker Hub，但仍要求访问 Gitee、TCR 及必要的系统包源。普通在线更新保持现有来源。

#### 旧版一次性迁移

`v1.20.18` 及更早版本的 Setup 不含新引导器和更新包，旧控制台即使显示“检查更新”，也不能据此认定它支持新链路。已有 `.env`、Compose 和数据库的实例应执行存量迁移，不要重新运行 `install`。没有 `.git` 的 `v1.20.16` 离线部署也可通过下面的入口迁移到 `v1.20.19`，无须先克隆仓库或手工修改数据库密码、Agent 密钥等配置。

先确认备份可恢复、磁盘预算充足、没有其他更新任务，并准备 Bash、curl、sha256sum、timeout、flock、realpath 和可用的 Docker Compose v2。以下命令适用于 Linux；只需把 `project_root` 改为**已有部署的绝对目录**。两个摘要来自已发布 `v1.20.19` 标签，不能随意替换版本或把下载地址改为 `main`：

```bash
sudo bash <<'MIGRATE'
set -euo pipefail
umask 077
project_root=/opt/guanlan-monitor
test -f "${project_root}/.env"
test -f "${project_root}/docker-compose.yml"
test -d "${project_root}/deploy"
test ! -L "${project_root}"
test ! -L "${project_root}/deploy"
stage="$(mktemp -d)"
trap 'rm -rf -- "${stage}"' EXIT
base_url='https://gitee.com/starchen520/monitor-for-server/raw/v1.20.19/deploy'
for script in xingchen.sh bootstrap-controller-update.sh; do
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 120 \
    "${base_url}/${script}" -o "${stage}/${script}"
done
(
  cd "${stage}"
  sha256sum --check <<'SHA256'
e9162ce36ed27ff386f19049d3583ab8f8cb94d07adab2128fea15d7267f51c8  xingchen.sh
b9ab49eb71fb53f1e4581f53d334e5d7e9fd3fb5467cba7a4cd532ec4fb47f7d  bootstrap-controller-update.sh
SHA256
)
bootstrap="${project_root}/deploy/bootstrap-controller-update.sh"
test ! -L "${bootstrap}"
if [[ -e "${bootstrap}" ]]; then
  cmp -- "${stage}/bootstrap-controller-update.sh" "${bootstrap}"
else
  install -m 0755 "${stage}/bootstrap-controller-update.sh" "${bootstrap}"
fi
bash "${stage}/xingchen.sh" update --install-dir "${project_root}" \
  --source gitee --version v1.20.19 --yes
MIGRATE
```

此处 `--yes` 仅跳过管理器的交互确认，不跳过校验、备份或健康检查。下载或摘要校验失败时不会执行下载内容；已有引导器与固定版本不同则停止，应先确认它的来源。迁移前仅补齐已校验的引导器，原管理脚本由正式更新事务替换；失败后可先排障，再使用同一入口重试。成功后会生成 `xingchen` 快捷命令，后续使用控制台或 `sudo xingchen update`。明确指定版本时不需要 Git 查询，未指定版本的 Gitee 版本发现仍需要 Git，但部署目录不需要 `.git`。

#### 更新失败与恢复边界

在线切换保存原始 `.env`、Compose 和受管脚本；健康检查失败或收到 HUP/INT/TERM 时，恢复原文件与实际运行过的旧镜像，再做一次健康检查。候选和回滚启动均禁止 Compose 隐式拉取或构建。恢复失败保留权限受限的 `.controller-update-snapshot.*`，后续更新拒绝覆盖，需先检查该快照和容器状态；强制断电或 SIGKILL 后遗留的快照也按此处理。数据库备份单独保留，数据库不会自动回退。

命令退出码 `75` 表示另一个更新持有 `.controller-update.lock`；锁文件本身存在不代表任务仍在运行，不要删除锁文件来强行并发更新。可查看 `docker ps --filter name=xingchen-controller-update-run`、部署目录中的 `docker compose ps` 和 `docker compose logs --tail 100 setup`。页面暂时断开时应先确认 Runner 状态，不要立即重复更新。

退出码 `10` 表示候选失败但旧部署恢复并通过健康检查，`11` 表示自动恢复失败，需要人工处理；二者都不表示数据库已恢复。保留升级前 SQL 备份、原配置快照和旧镜像，先评估 Flyway 迁移兼容性，再决定是否恢复对应数据库与应用版本。不要通过删除 `.controller-update-snapshot.*` 或执行 `docker compose down -v` 绕过故障。

#### 升级前的磁盘预算

`XINGCHEN_UPDATE_MIN_FREE_BYTES` 默认的 1 GiB 只是最低预检门槛，不是数据库和镜像的完整空间预算。应在宿主机检查部署目录与 Docker 数据目录所在文件系统，同时预留新旧镜像共存、下载解压、SQL 备份和更新期间数据库写入的空间：

```bash
cd /opt/guanlan-monitor
df -h .
df -h "$(docker info --format '{{.DockerRootDir}}')"
docker system df
```

管理器更新先在 PostgreSQL 容器 `/tmp` 生成完整 SQL，再复制到项目 `backups/`；复制期间两份 SQL 会同时存在。若 Docker 与项目共用磁盘，除候选镜像外，至少还要容纳两份预估 SQL 备份并留余量。控制台备份则直接流式写入项目目录。不要仅按压缩备份大小或数据库卷大小推断 SQL 大小；可参考最近一次完整 SQL 备份，并考虑数据增长。Runner 不能访问宿主机 Docker 数据目录时，仍需在宿主机人工检查该磁盘。

空间不足应先扩容或将已验证的历史备份转存到独立存储，再按明确的镜像引用清理可重建制品；保留本次恢复所需的旧镜像与备份，不要清理 PostgreSQL/Redis 数据卷，也不要为了通过检查下调空间门槛。CLI 升级备份不会在更新前自动清理，控制台的备份保留数量也不能代替磁盘预算。

#### 底层更新器

底层更新器是执行指定镜像目标的引擎，不负责发现最新版。维护已有脚本调用或配置自动任务时可使用：

```bash
sudo bash ./deploy/update-controller.sh --check
sudo bash ./deploy/update-controller.sh --apply
sudo bash ./deploy/update-controller.sh --auto
```

普通 `--apply` 在切换任何 Compose 服务前创建一致性 PostgreSQL 备份；备份失败会终止更新，现有服务保持不切换。候选镜像准备和版本校验也发生在切换前，只有备份与校验均成功才进入服务切换；应用健康失败时恢复旧镜像，数据库备份保留供管理员评估 Flyway 兼容性后人工恢复。

更新器默认给予单个内部镜像前缀 45 秒快速失败时间，镜像自身地址最多拉取 180 秒，单个源码镜像最多构建 1200 秒，Compose 操作最多执行 900 秒。可通过 `XINGCHEN_UPDATE_MIRROR_TIMEOUT_SECONDS`、`XINGCHEN_UPDATE_PULL_TIMEOUT_SECONDS`、`XINGCHEN_SOURCE_BUILD_TIMEOUT_SECONDS` 和 `XINGCHEN_UPDATE_COMPOSE_TIMEOUT_SECONDS` 调整；`XINGCHEN_UPDATE_MIN_FREE_BYTES` 默认要求至少 1 GiB 可用空间。外层任务上限覆盖完整回退链，更新失败不会删除数据库卷。

稳定发布使用 `vX.Y.Z`。`CN=true` 部署从 Gitee 稳定标签发现新版本，并且只在 TCR 验证完成后才向 Gitee 推送版本标签；GitHub 部署从已公开 Release 发现版本。内部或离线部署优先读取本地或 `XINGCHEN_RELEASE_MANIFEST_URLS` 配置的 HTTPS manifest，并保存 last-known-good 缓存。联网 CI 先创建 draft Release，等待四个项目镜像、四个平台 Agent 制品、manifest、校验文件和两个架构离线包全部验证完成后才公开发布，避免目标机看见半成品版本。

更新器不内置公共镜像加速器。控制台发起更新时拉取固定的 `vX.Y.Z` 或管理员配置的 OCI digest，并校验 OCI 版本标签，避免旧 `latest` 混入升级。自动更新只允许同一主版本内前进，跨主版本必须由管理员评估后手动执行。控制台和统一管理命令的在线入口关闭源码回退。底层更新器仍保留显式维护能力：按 `XINGCHEN_SOURCE_REPOSITORIES` 使用目标版本标签构建，GitHub 只有显式配置时才参与；`--source-build` 直接走配置的源码列表，`--no-source-fallback` 在镜像拉取失败时直接报错，`--build` 只构建当前目录源码。

### 哪吒机制对照与腾讯云发布

安装流程参考[哪吒 Dashboard 安装](https://nezha.wiki/guide/dashboard.html)、[Agent 安装](https://nezha.wiki/guide/agent.html)及 [Agent 更新配置](https://nezha.wiki/configuration/agent.html)。本项目继续使用 Docker Compose、独立 Setup 服务和当前版本协议：

| 环节 | 本项目入口与行为 |
| --- | --- |
| Dashboard 首次安装 | 固定稳定标签的 `xingchen.sh install`，补齐依赖、拉取镜像、等待健康，再进入 `/setup` 创建管理员 |
| 国内在线源 | `CN=true` 使用 Gitee 标签与腾讯云 TCR 六镜像，更新沿用部署来源 |
| Dashboard 更新 | `xingchen update` 或控制台更新；手动检查刷新发布源，备份和候选验证完成后切换 |
| Agent 安装 | 设备页生成总控同域短命令，校验安装器和制品，交换一次性接入令牌 |
| Agent 更新 | 固定 updater 或“Agent 发布”灰度任务；默认从总控同域下载，自动更新限同一主版本 |
| 更新成功判定 | Dashboard 验证服务健康；灰度 Agent 必须出现任务下发后的目标版本上报 |
| 离线与回滚 | 已校验 bundle、原配置和数据库备份；Agent 恢复旧程序，数据库恢复由管理员执行 |

当前国内镜像仓库为 `ccr.ccs.tencentyun.com/xc_monitor`，组件名称统一为 `monitor-for-server-{setup,server,web,agent,postgres,redis}`。GitHub Actions 使用仓库变量 `TCR_REGISTRY`、`TCR_NAMESPACE`、`TCR_USERNAME` 和仓库 Secret `TCR_PASSWORD`；本机登录保存在 Docker credential store，不能代替 CI 的 Secret。脚本不接受密码参数，手动发布机复用已有 Docker 登录。

两条发布工作流各自按 Git ref 排队，构建后把实际输出 digest 交给 `deploy/mirror-release-image.sh`。复制前要求清单包含唯一的 Linux `amd64` 和 `arm64`，使用 `skopeo copy --all --preserve-digests` 从 `source@sha256:...` 复制，目标摘要一致才成功。目标已有相同摘要时跳过传输；失败有两轮受限重试。六个目标镜像还必须通过匿名拉取检查，才能公开完整 Release。离线包的 PostgreSQL/Redis 从腾讯云固定 index digest 解析唯一的目标架构 manifest，再按该子摘要拉取并验证本地架构，包内保留原有镜像别名，避免 Docker 传统镜像存储在切换架构时覆盖同一 index digest 失败。

若镜像和 Agent 工作流已经成功，而离线打包或上传失败，可在修复发布工具后续跑现有草稿：

```bash
gh workflow run controller-images.yml --ref main -f release_version=v1.20.19
```

`release_version` 必须是已存在的稳定版本草稿；已公开或不存在的 Release 会被拒绝。续跑使用指定版本标签的源码、安装器和已成功的 Agent 工作流，复用腾讯云已有基础镜像，不重新构建或同步镜像；发布工具来自本次选定的 workflow ref。续跑与同版本标签发布共用并发锁，仍需通过镜像、Agent 制品和离线包校验才会公开。留空该参数维持原有镜像构建流程。

发布机可用以下只读命令核验已经公开的版本；无需启动本机 Docker 引擎：

```bash
docker buildx imagetools inspect ccr.ccs.tencentyun.com/xc_monitor/monitor-for-server-setup:v1.20.19
```

仓库中的未发布改动不会自动进入上述版本或生产服务器。新版本应完成 CI、腾讯云制品和离线包校验后，再将相同稳定标签同步到 Gitee，以免国内安装先发现尚未就绪的版本。

### 内部源与完全离线安装

内部 Registry 应同步 setup、server、web、agent、PostgreSQL 和 Redis 六个镜像；内部 HTTPS 制品服务应同步 `manifest.json`、`manifest.json.sha256`、四个平台 Agent 压缩包和 `checksums.txt`。稳定版 Setup 镜像内置同版本的四个平台 Agent 制品，在内部服务暂不可用且没有缓存时可作为末级本地基线；配置的内部 manifest 和 last-known-good 缓存仍优先，以便发现后续版本。

推荐由可联网的受控发布机执行内部晋级。输入 image lock 中六个源镜像都必须固定 `sha256:` digest；`source` 只写显式 Registry 和 repository，不写 tag。PostgreSQL 和 Redis 也是发布契约的必填项，不存在时晋级会在访问 Registry 前失败。Registry 凭据由预先完成的 `docker login` 或 credential store 提供，不写进参数。输入结构如下，所有摘要占位符必须替换为真实的 64 位小写十六进制值：

```json
{
  "schemaVersion": 1,
  "version": "v1.20.19",
  "images": {
    "setup": { "source": "ghcr.io/example/xingchen-setup", "digest": "sha256:<64 lowercase hex>" },
    "server": { "source": "ghcr.io/example/xingchen-server", "digest": "sha256:<64 lowercase hex>" },
    "web": { "source": "ghcr.io/example/xingchen-web", "digest": "sha256:<64 lowercase hex>" },
    "agent": { "source": "ghcr.io/example/xingchen-agent", "digest": "sha256:<64 lowercase hex>" },
    "postgres": { "source": "docker.io/library/postgres", "digest": "sha256:<64 lowercase hex>" },
    "redis": { "source": "docker.io/library/redis", "digest": "sha256:<64 lowercase hex>" }
  }
}
```

晋级命令：

```powershell
.\deploy\promote-internal-release.ps1 `
  -Version v1.20.19 `
  -TargetRegistry registry.internal.example/xingchen `
  -ArtifactDir D:\release\agent `
  -ArtifactBaseUrl https://release.internal.example/xingchen `
  -ImageLockFile D:\release\source-images.lock.json `
  -OutputDir D:\publish\xingchen\v1.20.19 `
  -WriteEnvExample
```

`-Check` 只做本地 JSON、四平台 Agent 制品和 checksum 校验，`-DryRun` 另外输出六条 `source@digest -> target:vX.Y.Z` 计划；两者都不访问 Registry，不写输出目录。默认模式逐个晋级并复核目标 digest，最后生成 `controller-images.lock.json` 和可选的 `controller-images.env.example`；两者的六个运行时镜像引用均为内部 `target@sha256:...`，不包含 GHCR、Docker Hub 或 `latest`。`OutputDir` 的文件需由内部发布系统映射到 `$ArtifactBaseUrl/$Version/`；脚本不猜测对象存储 API，也不会把文件上传到未声明的终端。

生产目标机的 `.env` 至少应把以下值替换成晋级工具生成的真实 digest、内部 URL 和 manifest 摘要。不要照抄占位符：

```dotenv
XINGCHEN_NETWORK_MODE=internal
XINGCHEN_ALLOW_GITEE=false
XINGCHEN_CONTROLLER_ALLOW_GITHUB_API=false
XINGCHEN_SETUP_IMAGE=registry.internal.example/xingchen/setup@sha256:<digest>
XINGCHEN_SERVER_IMAGE=registry.internal.example/xingchen/server@sha256:<digest>
XINGCHEN_WEB_IMAGE=registry.internal.example/xingchen/web@sha256:<digest>
XINGCHEN_AGENT_IMAGE=registry.internal.example/xingchen/agent@sha256:<digest>
XINGCHEN_POSTGRES_IMAGE=registry.internal.example/xingchen/postgres@sha256:<digest>
XINGCHEN_REDIS_IMAGE=registry.internal.example/xingchen/redis@sha256:<digest>
XINGCHEN_RELEASE_MANIFEST_URLS=https://release.internal.example/xingchen/v1.20.19/manifest.json
XINGCHEN_RELEASE_MANIFEST_SHA256=<manifest.json 的 SHA256>
XINGCHEN_AGENT_RELEASE_BASE_URLS=https://release.internal.example/xingchen
XINGCHEN_SOURCE_REPOSITORIES=
```

首次安装使用以下命令；`internal` 会在任何拉取前拒绝 GitHub、GHCR、Docker Hub 和未显式开启的 Gitee：

```bash
bash ./deploy/install-controller.sh --network-mode internal --no-source-fallback
```

已有内部部署更新前，必须先在 `.env` 配置目标版本的内部镜像 digest、manifest URL 和摘要，并确保部署目录中已有经过校验的受信 bootstrap。Setup 镜像 digest 必须对应目标版本，bootstrap 不会改写 digest 引用。旧内部部署若缺少入口脚本，应从受信内部发布材料补齐并校验，继续使用内部源，不要切换到公共 Gitee。

若部署使用本地 manifest，须同步更新本地清单、对应 Agent 制品及摘要。改用内部 HTTPS 清单时，应清空旧的 `XINGCHEN_RELEASE_MANIFEST_PATH`，并将部署目录默认的 `release/manifest.json` 备份移出活动位置；Setup 容器内该默认路径为 `/workspace/release/manifest.json`。本地清单优先于远程 URL，旧文件摘要不匹配时会直接报错，不会尝试新的内部 URL。更新后应确认 Agent 版本查询和同域制品下载正常。

将下列路径替换为实际已有部署目录，再检查和应用指定版本：

```bash
sudo bash /opt/guanlan-monitor/deploy/bootstrap-controller-update.sh --project-root /opt/guanlan-monitor --version v1.20.19 --check
sudo bash /opt/guanlan-monitor/deploy/bootstrap-controller-update.sh --project-root /opt/guanlan-monitor --version v1.20.19 --apply
```

完全断网时，在联网发布机下载并校验 `xingchen-monitor-offline-vX.Y.Z-amd64.tar.gz` 或 `-arm64.tar.gz` 及同名 `.sha256`，通过受控介质传入目标机后执行：

```bash
sha256sum -c xingchen-monitor-offline-vX.Y.Z-amd64.tar.gz.sha256
tar -xzf xingchen-monitor-offline-vX.Y.Z-amd64.tar.gz
cd xingchen-monitor-offline-vX.Y.Z-amd64
sudo ./install-offline.sh
```

包内安装器会再次校验全部文件、导入六个镜像、固定目标版本，并以 `--offline --no-source-fallback` 启动；缺少任何镜像或 Agent 制品都会在启动前失败。

已有 `v1.20.15` 部署升级到 `v1.20.16` 时不要运行 `install-offline.*`。先验证外层 `.sha256` 并解压，再从包内执行存量升级入口，其中 `--project-root` / `-ProjectRoot` 必须是已有部署的绝对目录：

```bash
sudo ./upgrade-offline.sh --project-root /opt/guanlan-monitor --check
sudo ./upgrade-offline.sh --project-root /opt/guanlan-monitor --apply
```

```powershell
.\upgrade-offline.ps1 -ProjectRoot 'D:\xingchen-monitor' -Check
.\upgrade-offline.ps1 -ProjectRoot 'D:\xingchen-monitor' -Apply
```

该入口先复核包内 `SHA256SUMS`，再校验现有 Compose 与 `.env`、导入并检查六个本地镜像、备份 PostgreSQL、原子替换 updater/Compose/release，最后以 `offline` 和 `--pull never` 切换服务。它不会生成或替换原数据库密码。数据库迁移仍是前向迁移，生产执行前必须验证备份可恢复。

### 数据库备份与恢复

管理员可在控制台“备份与恢复”创建 PostgreSQL SQL 备份、查看恢复点并恢复指定文件。备份由 setup 服务调用 PostgreSQL 容器内的 `pg_dump` 执行，不依赖 server 镜像安装额外工具；文件保存到项目目录 `backups/`，权限为 `0600`，默认保留最近 7 个，可通过 `CONTROLLER_BACKUP_RETENTION` 设置为 1-100 个。恢复任务会先停止 `server` 和 `web`，导入完成后自动拉起；任务状态可在页面轮询，失败时会尝试重新启动服务。

需要每天自动备份时，在 `.env` 设置：

```dotenv
CONTROLLER_BACKUP_AUTO=true
CONTROLLER_BACKUP_RETENTION=7
```

自动任务按 `APP_TIMEZONE` 每天 03:00 执行。备份文件和 `.env` 含有数据库及站点机密，必须限制项目目录访问并纳入离线备份策略。

更新器在健康检查失败后会尝试恢复更新前的应用镜像并再次执行健康检查；原配置使用 OCI digest 时，会先给旧 image ID 创建仅供本机使用的回滚别名，避免重新启动失败的新 digest。更新器不会自动回退数据库。Flyway 迁移是前向执行的，旧应用镜像不一定兼容已经升级的数据库结构；控制台会将数据库兼容性标记为需要人工确认，生产降级必要时必须同时恢复升级前的 PostgreSQL 备份和对应版本镜像。

升级前只清理本项目旧容器和本地镜像（保留 PostgreSQL/Redis 数据卷）时使用 `--cleanup`；不带该参数不会做破坏性清理。镜像默认从 GHCR 拉取，可通过 `XINGCHEN_SETUP_IMAGE`、`XINGCHEN_SERVER_IMAGE`、`XINGCHEN_WEB_IMAGE` 和 `XINGCHEN_AGENT_IMAGE` 指向内部仓库或固定版本。若 `.env` 缺少有效的 PostgreSQL 密码，安装器会重新生成 bootstrap 配置，不会复用旧数据库配置。

生产环境生成的配置至少包含：

```dotenv
SESSION_COOKIE_SECURE=true
ALLOWED_ORIGINS=https://monitor.example.com
PUBLIC_BASE_URL=https://monitor.example.com
```

启动服务（安装器已执行过时无需重复执行）：

```bash
docker compose --profile host-monitoring ps
docker compose logs --tail 100 server
```

完成向导后入口以页面提示为准。首次生产启动时，服务端从向导写入的 `BOOTSTRAP_ADMIN_USERNAME` 与 `BOOTSTRAP_ADMIN_PASSWORD` 创建管理员；已有管理员时不会覆盖密码。

## TLS 入口

Compose 中的 Web 容器负责静态资源、REST 与 WebSocket 内部代理。生产环境应在其前方配置 Caddy、Nginx、Traefik 或云负载均衡器终止 TLS，并将流量转发到 `WEB_PORT`。入口必须：

- 透传 `Host`、`X-Forwarded-Host`、`X-Forwarded-For` 和 `X-Forwarded-Proto`。
- 为 `/ws/` 开启 WebSocket Upgrade。
- 仅允许公网访问 Web 入口，不发布 PostgreSQL、Redis 和 Spring Boot 端口。
- 配合 `SESSION_COOKIE_SECURE=true` 和精确的 HTTPS `ALLOWED_ORIGINS`。

宝塔反向代理可将 `http://127.0.0.1:<WEB_PORT>` 作为目标，并开启 WebSocket。域名证书生效后，将 `.env` 中的 `PUBLIC_BASE_URL`、`ALLOWED_ORIGINS` 改为 `https://monitor.xciy.cn`，把 `SESSION_COOKIE_SECURE=true`、`ALLOW_INSECURE_HTTP=false`，然后重建 `server web`。

## 创建设备

1. 登录 Web 控制台并打开“设备管理”。
2. 添加设备后复制设备 ID、一次性接入令牌和页面生成的安装命令。
3. 接入令牌只显示一次、15 分钟后过期且只能消费一次；过期或安装失败时可为该设备重新签发，不需要接触长期 Agent 密钥。

## Linux Agent

Agent 接入采用控制台生成一条短命令的体验，但下载入口始终是 Controller 同域。该短命令只承担 bootstrap：分别下载完整安装器与 SHA256，精确匹配后才执行。命令不包含接入令牌或 Agent 密钥；完整安装器完成提权、准备好目标制品后在交互终端静默询问一次性令牌，再通过 `/api/agent/v1/enroll` 的 JSON body 交换长期密钥。非交互自动化可临时使用 `XINGCHEN_ENROLLMENT_TOKEN`，旧自动化的 `XINGCHEN_AGENT_KEY` 入口继续兼容；两者都会在安装器退出时清除。

控制台只通过总控同域入口下发安装器及其 SHA256；安装器随 Setup 镜像固化并优先于宿主机工作目录中的副本，更新镜像后不会继续下发旧脚本。目标服务器无需直接访问代码托管平台，也不会执行 Gitee 或 GitHub `main` 分支上的未固定脚本。

```bash
curl -fsSL --max-redirs 0 --proto '=https' --proto-redir '=https' 'https://monitor.example.com/api/setup/agent-bootstrap?platform=linux&deviceId=123e4567-e89b-42d3-a456-426614174000&interval=3s&disk=%2F&disk=%2Fdata' | bash
```

不要手工替换安装器 URL。若总控需要从外部同步版本或源码，应在总控侧配置受信内部制品源或 `XINGCHEN_SOURCE_REPOSITORIES`；GitHub 仍只能作为管理员显式启用的末级回退。已有的 `--image`、`--binary`、`--source-url`、内部 release 基址与离线安装方式继续作为高级入口，不受控制台短命令影响。

低配置或连接密集型主机可添加 `--skip-processes --skip-connections`。使用 `--process java`（可重复指定，最多 32 个）可额外保留关键进程，即使其不在 CPU 排名前 12；需要完整进程清单时添加 `--all-processes --process-limit 128`（最多 256 个），也可用 `--skip-ports`、`--skip-containers` 或对应的 `--port-limit`、`--container-limit` 控制明细量。Windows 安装器对应使用 `-MonitoredProcess java`、`-CollectAllProcesses`。如明确需要远程一次性命令或 MCP 文件操作，再分别添加 `--allow-command-execution`、`--allow-file-operations`；两项默认关闭。支持 `1s`、`3s`、`10s`、`30s`、`60s`，不传 `--disk` 时采集全部可用分区。

需要个性化指标时，在 Agent 配置的 `custom_metrics` 数组中添加最多 32 个参数化程序。程序不经过 Shell，每项最多运行 3 秒，`kind` 支持 `number`、`text`、`exit_code`；服务端设备详情会展示结果，告警规则可对数值项设置阈值。详见 `docs/monitored-agent.md` 中的 JSON 示例。Linux 还可添加 `--system-logs` 采集存在的标准系统日志文件（最多展示每个文件最近 20 行）。

`XINGCHEN_SERVER` 可以填写域名或 `域名:端口`，安装器会优先探测 `https://主机/healthz`。远程 HTTP 不会自动启用，只有明确传入 `--allow-insecure-http` 才允许明文连接；HTTPS 下载也禁止重定向降级到 HTTP。原生模式默认从总控取得 Linux/Windows amd64/arm64 制品并校验 manifest 中的大小和 SHA256；更新失败会恢复旧程序并验证服务存活。Docker 模式必须显式添加 `--docker`，并建议用 `--image` 或 `XINGCHEN_AGENT_IMAGE` 指向内部 OCI 仓库。源码回退仅使用显式配置的 `--source-url` 和 `--source-ref`。

原生安装和更新在替换程序前还会运行候选二进制的 `--version`，确认实际版本与目标一致；固定版本源码回退默认检出同名稳定标签，不会把当前分支内容标成目标版本。总控远程制品源在下载过程中推进新版时，已选旧版本可继续从当前或上一份受信缓存取得，仍校验清单、兼容性和制品摘要。

已有 Linux Agent 日常升级应执行 updater 的 `update`，保留原 JSON 配置、设备身份与 spool。重新运行 `install` 仍会按安装参数生成配置，不应用作保留所有自定义采集项的升级入口。

- 容器：`xingchen-agent`，重启策略为 `unless-stopped`
- 配置：`/etc/xingchen-agent/agent.json`，只读挂载到容器
- 缓冲：Docker 卷 `xingchen-agent-spool`
- 宿主机：只读挂载到 `/host`，并使用 host network/PID 采集主机指标

安装器会保存统一管理脚本，不需要再记 Docker 与 systemd 的不同命令：

```bash
/opt/xingchen/agent/agent.sh status
/opt/xingchen/agent/agent.sh logs
/opt/xingchen/agent/agent.sh restart
/opt/xingchen/agent/agent.sh update
/opt/xingchen/agent/agent.sh list-versions
/opt/xingchen/agent/agent.sh rollback v1.20.4
/opt/xingchen/agent/agent.sh uninstall
```

直接运行 `/opt/xingchen/agent/agent.sh` 会打开交互菜单。默认卸载会保留配置和离线缓存，只有 `uninstall --purge` 才会一并删除。

总控制品暂时不可用时，安装器不会自行访问代码托管平台；只有管理员通过 `--source-url` 或 `XINGCHEN_REPOSITORY_URLS` 显式配置受信仓库后才尝试源码构建，此时需要 Go 1.24+、git 和 systemd。也可用 `--binary /path/to/xingchen-agent` 指定本地程序。使用 `--no-docker` 可明确保持原生模式。此模式安装结果：

- 程序：`/usr/local/bin/xingchen-agent`
- 配置：`/etc/xingchen-agent/agent.json`，权限 `0600`
- 缓冲：`/var/lib/xingchen-agent/spool`
- 服务：`xingchen-agent.service`

本机回退模式检查状态：

```bash
systemctl status xingchen-agent
journalctl -u xingchen-agent -n 100 --no-pager
```

## Windows Agent

以管理员 PowerShell 运行：

```powershell
& .\deploy\install-agent.ps1 `
  -ServerUrl 'monitor.example.com' `
  -DeviceId '<设备ID>' `
  -Interval '3s' `
  -DiskMountpoint 'C:\','D:\' `
  -MonitoredService 'W3SVC','MSSQLSERVER'
```

脚本会用隐藏输入读取控制台签发的一次性接入令牌。自动化场景可在受控进程环境中临时提供 `XINGCHEN_ENROLLMENT_TOKEN`，不要把令牌写入脚本参数、URL 或日志。

轻量采集可添加 `-SkipProcesses -SkipConnections`；需要完整进程清单时添加 `-CollectAllProcesses -ProcessCollectionLimit 128`（上限 256）。端口和容器也可分别通过 `-SkipPorts`、`-SkipContainers` 关闭，或用 `-PortCollectionLimit`、`-ContainerCollectionLimit` 调低明细上限。如明确需要远程一次性命令或 MCP 文件操作，再分别添加 `-AllowCommandExecution`、`-AllowFileOperations`，两项默认关闭。不传 `-DiskMountpoint` 时采集全部可用分区。

使用预编译程序时添加 `-BinaryPath 'C:\staging\xingchen-agent.exe'`。脚本注册自动启动的 `XingchenAgent` Windows 服务，并将配置写入 `%ProgramData%\XingchenMonitor\agent.json`，ACL 仅允许 SYSTEM 与管理员访问。即使已安装 Docker Desktop，Windows 也保持原生服务模式，以免采集到 Docker 的 Linux 虚拟机而不是 Windows 宿主机。

检查状态：

```powershell
Get-Service XingchenAgent
Get-Content "$env:ProgramData\XingchenMonitor\agent.json" | ConvertFrom-Json | Select-Object server_url,device_id,interval
```

不要输出或展示 `agent_key` 字段。

Windows 同一总控、同一设备的重复安装会复用现有身份，结构化合并原配置，并保留未显式覆盖的采集项、缓存路径和自定义指标；配置先写入受限临时文件再替换。Windows updater 在停服务前完成备份和候选暂存，等待服务停止后替换；新程序启动失败时先停新服务再恢复旧程序，并复检服务状态。

## Agent 灰度发布与回滚

管理员可在“Agent 发布”创建草稿，显式选择已上报稳定版本且非 Controller 内置的 Agent。Controller 内置 Agent 始终随 Controller 镜像更新，不进入独立 rollout。发布按设备稳定 ID 确定性排序，支持首批灰度比例、1-20 个批次、维护窗口、最大并发、确定性抖动、版本确认超时和当前批次失败率阈值。

下发使用专用 `AGENT_UPDATE` operation，`command` 固定为 `agent.update`，`args` 必须为空，payload 只包含 `action=update|rollback`、稳定版本以及成对的正整数 `rolloutId/memberId`。该路径不依赖通用 `allow_command_execution`；Agent 不能从任务中接收 URL、文件路径、Shell 或任意参数。Linux 通过 root-owned `systemd.path` handler 调用固定 updater，Windows 通过受 SYSTEM/Administrators ACL 保护的固定 launcher 调用 updater。

任务返回 `SUCCEEDED` 仅代表更新请求已原子入队。成员只有在任务下发时间之后（含同一时间戳）的实时报告中出现目标 `agentVersion` 才进入 `CONFIRMED`；超时或任务失败会计入当前批次失败率并可自动暂停。取消后已被 Agent 领取的任务仍会对账 late report，后续回滚只选择实际确认升级的成员。管理员应先在小批量非关键节点验证，再扩大批次；回滚目标是每台设备在创建 rollout 时记录的 `previousVersion`。

## 通知配置

邮件、钉钉、企业微信和通用 Webhook 可在 Web 控制台的“系统设置”中启用、编辑和测试。SMTP 密码、Webhook 和钉钉加签密钥写入数据库前使用 AES-256-GCM 加密，页面只显示是否已配置；钉钉安全关键词会自动附加到消息内容，避免关键词校验导致发送失败。通用 Webhook 可选择通用 JSON、Slack、Discord、飞书/Lark 或纯文本格式，服务端对通用端点只校验 HTTP 2xx。`.env` 中的值作为未设置数据库覆盖值时的回退（可使用 `DINGTALK_KEYWORD`、`DINGTALK_SIGN_SECRET`、`GENERIC_WEBHOOK_URL`、`GENERIC_WEBHOOK_FORMAT`）；修改环境回退值后重建服务端容器：

```powershell
docker compose up -d --force-recreate server
```

HarmonyOS App 的设备通知使用华为 Push Kit V3 服务账号和独立的 `PUSH_KIT_*` 环境变量，不属于上述通用通知通道。配置步骤、版本边界和 App Token 生命周期见 [华为 HarmonyOS Push Kit V3 接入](huawei-push-kit.md)。

## 备份与升级

升级前在控制台“备份与恢复”创建一致性 PostgreSQL 逻辑备份，并将部署使用的 `.env`，特别是 `SETTINGS_ENCRYPTION_KEY`，保存在独立秘密管理系统。数据库备份和配置应作为同一恢复点保存，具体行为见[数据库备份与恢复](#数据库备份与恢复)。Redis 仅用于在线状态加速，不是主要备份目标。

已迁移到新版在线链路的部署，使用控制台或 `sudo xingchen update`；旧版先完成[一次性迁移](#旧版一次性迁移)，完全离线则使用已校验 bundle 的存量升级入口。直接执行 `docker compose pull/up` 不会替换旧部署脚本与 Compose，也绕过了上述备份、版本校验和事务恢复流程，不能代替正常升级。Flyway 会在服务端启动时执行迁移，生产升级前应先在测试环境验证备份恢复。

## 故障排查

- Web 显示 502：检查 `docker compose ps` 与 `docker compose logs server`，确认服务端健康检查通过。
- 登录后写操作返回 403：确认浏览器允许同站 Cookie，入口域名与 `ALLOWED_ORIGINS` 完全一致。
- WebSocket 反复断开：确认外层代理转发 Upgrade 请求头，且会话 Cookie 可发送到 `/ws/metrics`。
- 设备一直待接入：打开设备详情查看“Agent 接入诊断”。`等待 Agent 接入` 表示尚未收到首次上报；`Agent 已离线` 表示已超过失联阈值。然后在目标机检查 `docker logs --tail 100 xingchen-agent` 或 `journalctl -u xingchen-agent -n 100 --no-pager`，核对设备 ID、服务端 HTTPS 地址和密钥；密钥轮换后旧值立即失效。
- Agent 日志提示延迟上报：检查 DNS、证书链和防火墙。缓冲文件会保留在 spool 目录并在恢复后补传。
- Linux 安装器仍提示 Go 1.24+：Docker 命令不存在、守护进程不可达，或显式使用了 `--no-docker`；先运行 `docker info` 检查。要强制使用本机程序，请同时指定 `--no-docker --binary /path/to/xingchen-agent`。
- Agent 镜像无法拉取：优先用 `--image` 或 `XINGCHEN_AGENT_IMAGE` 指向受信内部 Registry；完全断网时使用已校验的离线 bundle。只有明确采用 GHCR 时才检查其网络和包可见性。
- 总控镜像无法拉取：优先配置四个 `XINGCHEN_*_IMAGE` 为内部 Registry 的同版本镜像，或导入包含六个镜像的离线 bundle；具备受信源码网络时也可使用 `bash ./deploy/install-controller.sh --build` 本地构建。
- 设备离线但无告警：检查系统离线判定时间、离线规则阈值和规则是否启用。
