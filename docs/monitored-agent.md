# 受监控服务器搭建材料

受监控服务器只安装一个 Go Agent。每台机器在总终端“设备管理”中创建一条设备记录，拿到设备 ID 和一次性 Agent 密钥后，再在目标主机安装。

## Linux

推荐把预编译的 `guanlan-agent` 二进制复制到目标主机；没有二进制时，安装器会从仓库源码构建，因此目标机需要 Go 1.24+ 和仓库目录。

```bash
export GUANLAN_AGENT_KEY='<一次性密钥>'
sudo --preserve-env=GUANLAN_AGENT_KEY ./deploy/install-agent.sh \
  --server-url https://monitor.example.com \
  --device-id '<设备ID>' \
  --binary /path/to/guanlan-agent \
  --interval 3s \
  --disk / \
  --service nginx
```

支持的周期为 `1s`、`3s`、`10s`、`30s`、`60s`。低配置主机可添加 `--skip-processes --skip-connections`。安装后检查：

```bash
systemctl status guanlan-agent
journalctl -u guanlan-agent -n 100 --no-pager
```

配置位于 `/etc/guanlan-agent/agent.json`，权限为 `0600`；缓冲目录位于 `/var/lib/guanlan-agent/spool`。

## Windows

请用管理员 PowerShell 运行。建议使用预编译的 `guanlan-agent.exe`，避免在生产机安装 Go：

```powershell
$env:GUANLAN_AGENT_KEY = '<一次性密钥>'
& .\deploy\install-agent.ps1 `
  -ServerUrl 'https://monitor.example.com' `
  -DeviceId '<设备ID>' `
  -BinaryPath 'C:\staging\guanlan-agent.exe' `
  -Interval '3s' `
  -DiskMountpoint 'C:\','D:' `
  -MonitoredService 'W3SVC','MSSQLSERVER'
```

安装器会创建自动启动的 `GuanlanAgent` 服务，并将配置写入 `%ProgramData%\GuanlanMonitor\agent.json`，仅 SYSTEM 与 Administrators 可读。检查：

```powershell
Get-Service GuanlanAgent
Get-Content "$env:ProgramData\GuanlanMonitor\agent.json" | ConvertFrom-Json | Select-Object server_url,device_id,interval
```

## 更新和改信息

- 修改设备名称、分组、位置和主 IP：在总终端“设备管理”编辑，不需要重装 Agent。
- 修改采集周期、磁盘白名单或服务检查：重新生成安装命令，在目标机重新运行安装器；安装器会更新现有服务。
- 轮换密钥：总终端管理员执行“轮换密钥”，旧密钥立即失效，然后在目标机重新运行安装器。
- 更新 Agent 版本：替换 `--binary` 指向的新二进制并重新运行对应安装器，或先停止服务、替换程序后启动。

Agent 默认强制 HTTPS；仅 `localhost` 开发地址可使用 HTTP。不要把 Agent 密钥放入 URL、日志、工单或鸿蒙 App。
