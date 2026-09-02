# 受监控服务器搭建材料

受监控服务器只安装一个 Agent。每台机器在星辰监控总控的“设备管理”中创建一条设备记录，拿到设备 ID 和一次性 Agent 密钥后，再在目标主机安装。

第一次接入设备可先阅读[新手使用指南的“接入第一台服务器”](user-guide.md#7-接入第一台服务器)。控制台自动生成的命令应优先于手工拼接；本页用于查阅完整 Agent 参数和高级采集配置。

## Linux

在线安装器默认安装预编译 Agent，流程与 Nezha 的一键安装方式一致：识别操作系统和 CPU 架构，从 GitHub Release 下载对应压缩包，强制校验 `checksums.txt` 后安装 systemd 服务。GitHub 暂时不可用时才回退到 Gitee/GitHub 源码构建。Docker 仍可用，但必须显式添加 `--docker`；这样不会因为目标机恰好装有 Docker 而采集到错误的虚拟机环境。

控制台默认使用总控同域入口，目标服务器无需访问代码托管平台；也可在命令上方明确切换到 Gitee 或 GitHub。复制按钮输出的是纯文本命令，不包含 Markdown 链接、历史版本号或多级下载回退。

```bash
curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 'https://monitor.example.com/api/setup/agent-installer?platform=linux' -o xingchen-agent.sh && chmod +x xingchen-agent.sh && env XINGCHEN_SERVER='https://monitor.example.com' XINGCHEN_DEVICE_ID='<设备ID>' XINGCHEN_AGENT_KEY='<一次性密钥>' ./xingchen-agent.sh --interval 3s
```

Gitee 源只替换安装脚本下载地址，安装参数和密钥注入方式保持一致：

```bash
curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 \
  'https://gitee.com/starchen520/monitor-for-server/raw/main/deploy/install-agent.sh' \
  -o xingchen-agent.sh
```

GitHub 下载地址为 `https://raw.githubusercontent.com/Pstarchen/monitor-for-server/main/deploy/install-agent.sh`，控制台选择后会自动生成完整命令。

`XINGCHEN_SERVER` 可以填写域名、`域名:端口` 或完整 `http(s)://` 地址。安装器会先访问 HTTPS 健康检查；如果 HTTPS 不可用但 HTTP 健康检查可用，会回退到 HTTP 并在配置中启用明文连接。生产环境建议配置 HTTPS；HTTP 仅适合临时或内网部署。原生模式会把配置写到 `/etc/xingchen-agent/agent.json`，离线上报缓冲写入 `/var/lib/xingchen-agent/spool`，程序安装到 `/usr/local/bin/xingchen-agent`。

需要个性化指标时，可在 `custom_metrics` 中配置最多 32 个程序。程序通过参数数组直接执行，不经过 Shell；`kind` 支持 `number`、`text`、`exit_code`，每项最多运行 3 秒并截断 4096 字符输出。例如：

```json
"custom_metrics": [
  {"name": "queue_depth", "command": "/usr/local/bin/queue-depth", "args": [], "kind": "number"},
  {"name": "release", "command": "/usr/local/bin/release-name", "args": [], "kind": "text"}
]
```

告警规则选择“自定义监控项”并填写相同名称后，可对数值结果设置阈值；文本结果仅展示，不参与数值告警。

如果主机存在 `/var/run/docker.sock` 或 Docker 兼容的 Podman socket，Agent 会额外读取容器状态、CPU、内存和累计网络流量；受管 Docker Agent 也会尝试 `/host` 对应路径。没有 socket 或权限不足时自动跳过，不影响其他主机指标。运行时 socket 具备高权限，只应在受信任主机上挂载。

安全巡检默认启用防火墙状态和计划任务摘要，但不会读取日志或文件内容。需要读取 Linux 标准系统日志（syslog、messages、auth.log、secure）时添加 `--system-logs`；需要日志尾部或文件完整性检测时，显式添加一个或多个 `--log-path`、`--integrity-path`；路径必须为绝对路径，且只读取白名单范围。Windows 安装器对应参数为 `-LogPath` 和 `-IntegrityPath`。

安装器会自动探测这两个标准路径；使用非标准 Docker/Podman socket 时，显式传入 `--docker-socket /path/to/runtime.sock`（或设置 `XINGCHEN_DOCKER_SOCKET`）。Docker 模式会把它以只读方式映射到 Agent 容器的固定路径，自动更新时也会保留映射；本机 systemd 模式会将 Agent 服务加入 socket 所属组，避免常见的 `root:docker 0660` 权限导致容器列表为空。若指定路径不存在或不是 Unix socket，安装器会直接报错并停止。

安装完成后，安装脚本会保存为 `/opt/xingchen/agent/agent.sh`。直接执行可打开管理菜单，也可以非交互执行：

```bash
/opt/xingchen/agent/agent.sh status
/opt/xingchen/agent/agent.sh logs
/opt/xingchen/agent/agent.sh restart
/opt/xingchen/agent/agent.sh update
/opt/xingchen/agent/agent.sh uninstall
```

默认卸载会保留配置和离线缓存；彻底删除时使用 `uninstall --purge`。管理脚本会记录安装模式和 Release 源，不会记录 Agent 密钥。

内网可用 `--image registry.example.com/xingchen-agent:版本` 或 `XINGCHEN_AGENT_IMAGE` 指定 OCI 镜像。镜像代理和 GHCR 都不可用时，Docker 安装/更新会依次从 Gitee、GitHub 源码构建镜像；Gitee Git 仓库本身不作为 OCI 镜像仓库。Docker 不可用时可传 `--binary /path/to/xingchen-agent` 使用本机 systemd 服务；未提供二进制时同样按 Gitee、GitHub 顺序拉取源码。可重复传入 `--source-url` 配置私有源码源，并用 `--source-ref` 固定分支或标签。

Linux 原生模式安装后默认启用每日 Agent 自动更新。更新器使用 Release API 的最新稳定版本，下载对应架构压缩包并强制校验 SHA256；下载失败或校验失败时保留当前程序，不会替换成未验证文件。更新前会在 `/var/lib/xingchen-agent/backups` 保留最近 5 份带时间戳的备份，启动失败会自动恢复旧程序。可用 `--no-auto-update` 关闭定时更新。检查和手动执行更新：

```bash
systemctl status xingchen-agent-update.timer
/opt/xingchen/agent/agent.sh update
/opt/xingchen/agent/agent.sh list-versions
/opt/xingchen/agent/agent.sh rollback v1.20.4
```

也可以直接指定版本安装或更新：`./xingchen-agent.sh --version v1.20.6`。回退只接受 Release 中存在的稳定版本；不要把分支名、提交 SHA 或任意 URL 当作版本号。

支持的周期为 `1s`、`3s`、`10s`、`30s`、`60s`。低配置主机可添加 `--skip-processes --skip-connections`；需要完整进程清单时添加 `--all-processes --process-limit 128`（最多 256 个），也可用 `--skip-ports`、`--skip-containers` 或对应的 `--port-limit`、`--container-limit` 控制明细量。本机回退模式安装后检查：

```bash
systemctl status xingchen-agent
journalctl -u xingchen-agent -n 100 --no-pager
```

配置位于 `/etc/xingchen-agent/agent.json`，权限为 `0600`；缓冲目录位于 `/var/lib/xingchen-agent/spool`，备份目录位于 `/var/lib/xingchen-agent/backups`。从旧版升级的主机会保留原有路径和服务名，以避免中断上报。

## Windows

请用管理员 PowerShell 运行。控制台会根据所选安装源下载脚本，临时注入 Agent 密钥，并在完成后删除脚本和环境变量。安装器会识别 Windows x64/ARM64，从 Release 下载并校验 `xingchen-agent_<版本>_windows_<架构>.zip`：

```powershell
$env:XINGCHEN_AGENT_KEY = '<一次性密钥>'
& .\deploy\install-agent.ps1 `
  -ServerUrl 'monitor.example.com' `
  -DeviceId '<设备ID>' `
  -Interval '3s' `
  -DiskMountpoint 'C:\','D:' `
  -LogPath 'C:\inetpub\logs\LogFiles\W3SVC1\u_ex240831.log' `
  -IntegrityPath 'C:\inetpub\wwwroot' `
  -MonitoredService 'W3SVC','MSSQLSERVER'
```

安装器会创建自动启动的 `XingchenAgent` 服务，并将配置写入 `%ProgramData%\XingchenMonitor\agent.json`，仅 SYSTEM 与 Administrators 可读。检查：

```powershell
Get-Service XingchenAgent
Get-Content "$env:ProgramData\XingchenMonitor\agent.json" | ConvertFrom-Json | Select-Object server_url,device_id,interval
```

Windows Agent 默认注册每日自动更新任务；需要关闭时在安装命令中添加 `-NoAutoUpdate`。

Windows 管理命令：`-Action update` 更新到最新版本，`-Action rollback -Version v1.20.4` 回退到指定版本，`-Action list-versions` 查看可用版本，`-Action uninstall` 卸载（加 `-Purge` 同时删除配置和缓存）。

## 更新和改信息

- 修改设备名称、分组、位置和主 IP：在总终端“设备管理”编辑，不需要重装 Agent。
- 修改采集周期、磁盘白名单或服务检查：重新生成安装命令，在目标机重新运行安装器；安装器会更新现有容器或本机服务。
- 轮换密钥：总终端管理员执行“轮换密钥”，旧密钥立即失效，然后在目标机重新运行安装器。
- 更新 Agent 版本：运行 `/opt/xingchen/agent/agent.sh update`，或用 `./xingchen-agent.sh --version v1.20.6` 安装固定版本。原生更新会下载 Release、校验 SHA256、备份旧程序并在新服务启动失败时自动恢复；只有需要 Docker 采集模式时才添加 `--docker --image ghcr.io/pstarchen/monitor-for-server-agent:v1.20.6`。

安装器传入域名时会优先探测 HTTPS，失败后再探测 HTTP；若最终使用 HTTP，Agent 数据将明文传输，生产环境应尽快配置证书。总控修改“Agent 上报周期”后，已安装 Agent 会在下一次成功上报时自动同步，无需重装。不要把 Agent 密钥放入 URL、日志、工单或鸿蒙 App。
