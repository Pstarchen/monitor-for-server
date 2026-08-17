# 观澜 Agent

Agent 默认读取当前目录的 `agent.json`，也可通过 `-config` 或 `GUANLAN_AGENT_CONFIG` 指定配置文件。生产环境必须使用 HTTPS；只有本机开发地址会默认允许 HTTP。

```powershell
go build -o bin/guanlan-agent.exe ./cmd/agent
./bin/guanlan-agent.exe -config ./agent.json
```

Agent 每轮先将报告原子写入磁盘缓冲，再按时间顺序上报。服务器不可达时数据保留，恢复后自动补传；超过 `max_buffered_reports` 时仅删除最旧报告。
