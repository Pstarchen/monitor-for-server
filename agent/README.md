# 观澜 Agent

Agent 默认读取当前目录的 `agent.json`，也可通过 `-config` 或 `GUANLAN_AGENT_CONFIG` 指定配置文件。生产环境必须使用 HTTPS；只有本机开发地址会默认允许 HTTP。

Linux 安装器优先拉取 `ghcr.io/pstarchen/monitor-for-server-agent:latest`。镜像以 `/guanlan-agent` 为入口，支持 `linux/amd64` 和 `linux/arm64`；安装器负责挂载配置、缓冲卷及只读宿主机根目录。

```powershell
go build -o bin/guanlan-agent.exe ./cmd/agent
./bin/guanlan-agent.exe -config ./agent.json
```

Agent 每轮先将报告原子写入磁盘缓冲，再按时间顺序上报。服务器不可达时数据保留，恢复后自动补传；超过 `max_buffered_reports` 时仅删除最旧报告。

## 采集范围

- `skip_process_collection`：跳过进程扫描，适用于受限容器或低配置主机。
- `skip_connection_count`：跳过 TCP 连接枚举，降低连接密集型主机的采集开销。
- `disk_mountpoints`：仅采集列出的挂载点；空数组表示采集全部可用分区。
- `host_root`：仅供 Linux 总终端的受管 Agent 使用。设置为只读宿主机挂载目录（安装器使用 `/host`）后，磁盘容量从宿主机读取；普通 Agent 保持空值。
- `monitored_services`：检查指定 systemd 服务或 Windows 服务状态。
- `allow_command_execution`：启用服务端一次性命令任务，默认关闭；只有明确开启后 Agent 才会轮询和执行任务。
- `allow_file_operations`：启用 MCP 文件任务（列目录、读写和删除），默认关闭；建议仅配合服务器白名单和最小 Token scope 使用。
- `command_poll_interval`：任务轮询周期，默认 1 秒。
- `max_command_output_bytes`：单个 stdout/stderr 的最大回传字节数，默认 65536。

Linux 安装器可在确认主机用途后通过 `--allow-command-execution` 和 `--allow-file-operations` 写入上述开关；Windows 安装器对应使用 `-AllowCommandExecution` 和 `-AllowFileOperations`。未传参数时两项均保持关闭。

以上字段均可在 `agent.example.json` 中查看完整示例。省略时保持完整采集。
