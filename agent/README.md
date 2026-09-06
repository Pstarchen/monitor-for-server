# 星辰监控 Agent

Agent 默认读取当前目录的 `agent.json`，也可通过 `-config` 或 `XINGCHEN_AGENT_CONFIG` 指定配置文件。生产环境必须使用 HTTPS；只有本机开发地址会默认允许 HTTP。

生产接入请在总控“设备管理”中创建或选择目标设备，运行控制台生成的同域 bootstrap 命令。bootstrap 分别下载完整安装器及 SHA256，校验一致后才执行。命令不含接入令牌或长期密钥；安装器通过终端隐藏输入读取 15 分钟有效、只能消费一次的接入令牌，在制品准备好后通过 JSON body 向总控交换长期 Agent 密钥，并写入受限配置文件。对已有设备点击“签发接入令牌”不会使现有密钥失效；安装器成功消费令牌时才轮换长期密钥。

Linux 默认安装原生 systemd 服务，支持 `linux/amd64` 和 `linux/arm64`；Windows 使用管理员 PowerShell，支持 x64/ARM64。两端默认向总控同域 `/api/setup/agent-release` 查询版本，从 `/api/setup/agent-artifact` 下载制品，并核对大小、SHA256 和程序实际版本。默认在线配置下，清单和四平台制品随 Setup 镜像内置；配置受信 manifest 后，由对应清单和制品决定可用版本。总控还会检查 `minimumCompatibleControllerVersion`，拒绝不兼容的 Agent。

使用 Gitee 发现版本、腾讯云 TCR 拉取镜像的部署，应先升级总控，再更新独立 Agent。例如总控升级到 `v1.20.19` 后，默认同域来源即可提供该版本 Agent，原生节点无需访问 GitHub、Gitee 或镜像仓库。批量更新路径为“Agent 发布 > 新建发布 > 创建草稿 > 启动发布 > 确认启动”；完成以设备实时上报目标版本为准。

Linux 新装默认使用 `/usr/local/bin/xingchen-agent`、`xingchen-agent.service` 和 `/opt/xingchen/agent/agent.sh`。使用 root 或 `sudo` 执行以下管理命令，普通更新无需重新输入令牌或重装：

```bash
/opt/xingchen/agent/agent.sh status
/opt/xingchen/agent/agent.sh update
/opt/xingchen/agent/agent.sh update v1.20.19
/opt/xingchen/agent/agent.sh list-versions
```

Windows 新装的更新器保存到 `%ProgramData%\XingchenMonitor\update-agent.ps1`，在管理员 PowerShell 中执行 `& "$env:ProgramData\XingchenMonitor\update-agent.ps1" update`；指定版本时在 `update` 后追加 `v1.20.19`。已校验的 `deploy/install-agent.ps1` 也支持 `-Action update`、`-Action rollback -Version v1.20.4`、`-Action list-versions` 和 `-Action status`。

更新器保留安装时记录的来源和服务路径。Linux 旧安装可能继续使用 `guanlan-agent.service`、`/etc/guanlan-agent` 与 `/var/lib/guanlan-agent`；Windows 旧安装保留 `GuanlanAgent` 和 `GuanlanMonitor` 目录。命令应使用该节点实际管理入口，不要为统一名称卸载重装；仅在缺少更新器或更新请求桥时，从同一设备页面取得已校验的安装命令补齐。

原生更新在替换前备份旧程序，启动失败时尝试恢复并检查旧服务。自动更新不会跨主版本，连续 5 次自动失败暂停 24 小时；手动更新不受暂停限制。手动 `rollback v1.20.4` 仅为语法示例，需替换为受信来源仍能下载的稳定版本；它重新下载目标制品，不是自动读取本地备份。默认 `list-versions` 也不等于完整历史 Release 列表。

独立 Docker Agent 需要显式 `--docker`，更新时从总控发现版本，再从节点已配置的镜像仓库拉取固定标签。总控迁移腾讯云不会把既有节点的 GHCR 引用自动改为 TCR；固定 digest 不会被定时更新改写。总控自带 `controller-agent` 则随总控 Compose 升级，不在“Agent 发布”中单独更新。原生 Agent 本身也支持 Docker/Podman 指标，无需仅为采集容器指标而改用 Docker 安装。

非交互接入通过受控进程环境提供 `XINGCHEN_SERVER`、`XINGCHEN_DEVICE_ID` 和 `XINGCHEN_ENROLLMENT_TOKEN`，旧自动化兼容 `XINGCHEN_AGENT_KEY`；不要把凭据写入命令参数或日志。完整安装、网络策略和采集配置见[受监控服务器文档](../docs/monitored-agent.md)。

## 本地开发

```powershell
go build -o bin/xingchen-agent.exe ./cmd/agent
./bin/xingchen-agent.exe -config ./agent.json
```

Agent 每轮先将报告原子写入磁盘缓冲，再按时间顺序上报。服务器不可达时数据保留，恢复后自动补传；超过 `max_buffered_reports` 时仅删除最旧报告。

## 采集范围

- `skip_process_collection`：跳过进程扫描，适用于受限容器或低配置主机。
- `skip_connection_count`：跳过 TCP 连接枚举，降低连接密集型主机的采集开销。
- `disk_mountpoints`：仅采集列出的挂载点；空数组表示采集全部可用分区。
- `host_root`：仅供 Linux 总终端的受管 Agent 使用。设置为只读宿主机挂载目录（安装器使用 `/host`）后，磁盘容量从宿主机读取；普通 Agent 保持空值。
- `docker_socket`：可选 Docker/Podman 兼容 Unix socket 路径；留空时自动探测 `/var/run/docker.sock`、`/run/podman/podman.sock` 及受管 Agent 的 `/host` 对应路径。指定路径失效时仍会回退到自动探测，避免运行时 socket 重建后永久停止采集。Agent 只调用兼容 API 的容器列表和统计 GET 接口，无法访问运行时或权限不足时返回空列表。挂载运行时 socket 等同于授予高权限，请仅在受信任主机上启用。
- `monitored_services`：检查指定 systemd 服务或 Windows 服务状态。
- `monitored_processes`：额外保留指定进程，即使它们不在 CPU 排名前 12；适合持续观察低占用但关键的 Nginx、Java、数据库进程。最多额外保留 32 个配置项。
- `collect_all_processes`：显式开启后按 CPU/内存排序采集最多 256 个进程；`process_collection_limit` 可将上限设为 1-256。默认仍只采集前 12 个并保留 `monitored_processes` 指定项，避免进程密集型主机产生过大的报告。
- `log_paths`：可选的绝对日志文件路径白名单。启用后仅上传每个文件最后 20 行（最多 32 KiB），默认为空，不会读取日志。
- `integrity_paths`：可选的绝对文件或目录白名单。启用后上传 SHA-256、大小和修改时间，用于检测文件被修改；单文件最多 16 MiB，目录最多 512 个文件，默认为空。
- 默认采集监听中的 TCP/UDP 端口和网络接口明细；端口枚举会复用 `skip_connection_count` 开关，受限主机可关闭。
- `skip_port_collection`：仅跳过监听端口枚举，不影响 TCP 连接计数；`port_collection_limit` 可将端口明细限制在 1-512 条。
- `skip_container_collection`：跳过 Docker/Podman 容器摘要；`container_collection_limit` 可将容器明细限制在 1-100 条。
- 进程明细包含截断至 2048 字符的命令行，读取失败时为空，不影响其他指标。
- `allow_command_execution`：启用服务端一次性命令任务，默认关闭；只有明确开启后 Agent 才会轮询和执行任务。
- `allow_file_operations`：启用 MCP 文件任务（列目录、读写和删除），默认关闭；建议仅配合服务器白名单和最小 Token scope 使用。
- `command_poll_interval`：任务轮询周期，默认 1 秒。
- `max_command_output_bytes`：单个 stdout/stderr 的最大回传字节数，默认 65536。

Linux 安装器可在确认主机用途后通过 `--allow-command-execution` 和 `--allow-file-operations` 写入上述开关；Windows 安装器对应使用 `-AllowCommandExecution` 和 `-AllowFileOperations`。未传参数时两项均保持关闭。

以上字段均可在 `agent.example.json` 中查看完整示例。省略时保持完整采集。主机温度、每核 CPU、监听端口、网卡和 Docker 容器信息会随监控报告保存，并在设备详情中按权限展示。
