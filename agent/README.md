# 观澜 Agent

Agent 默认读取当前目录的 `agent.json`，也可通过 `-config` 或 `GUANLAN_AGENT_CONFIG` 指定配置文件。生产环境必须使用 HTTPS；只有本机开发地址会默认允许 HTTP。

```powershell
go build -o bin/guanlan-agent.exe ./cmd/agent
./bin/guanlan-agent.exe -config ./agent.json
```

Agent 每轮先将报告原子写入磁盘缓冲，再按时间顺序上报。服务器不可达时数据保留，恢复后自动补传；超过 `max_buffered_reports` 时仅删除最旧报告。

## 采集范围

- `skip_process_collection`：跳过进程扫描，适用于受限容器或低配置主机。
- `skip_connection_count`：跳过 TCP 连接枚举，降低连接密集型主机的采集开销。
- `disk_mountpoints`：仅采集列出的挂载点；空数组表示采集全部可用分区。
- `monitored_services`：检查指定 systemd 服务或 Windows 服务状态。

以上字段均可在 `agent.example.json` 中查看完整示例。省略时保持完整采集。
