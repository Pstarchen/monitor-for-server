# 星辰监控 Agent

Agent 默认读取当前目录的 `agent.json`，也可通过 `-config` 或 `XINGCHEN_AGENT_CONFIG` 指定配置文件。生产环境必须使用 HTTPS；只有本机开发地址会默认允许 HTTP。

Linux 安装器默认从 GitHub Release 下载 `linux/amd64` 或 `linux/arm64` 预编译程序，并在安装前校验 `checksums.txt`；安装到 `/usr/local/bin/xingchen-agent` 后由 `xingchen-agent.service` 管理。GitHub 暂时不可用时才回退到 Gitee/GitHub 源码构建。需要容器隔离或宿主机 Docker 指标时，可显式添加 `--docker` 使用 GHCR 镜像。

安装器命令兼容 Nezha 式环境变量入口：`XINGCHEN_SERVER`、`XINGCHEN_DEVICE_ID`、`XINGCHEN_AGENT_KEY`。安装完成后，`/opt/xingchen/agent/agent.sh update` 会下载最新 Release，更新前在 `/var/lib/xingchen-agent/backups` 保留旧程序；`list-versions` 和 `rollback v1.20.4` 可查看及回退已发布版本。已安装的旧版 Agent 会继续使用原路径，确保升级过程不中断。

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
