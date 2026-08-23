# 受监控服务器搭建材料

受监控服务器只安装一个 Agent。每台机器在总终端“设备管理”中创建一条设备记录，拿到设备 ID 和一次性 Agent 密钥后，再在目标主机安装。

## Linux

在线安装器默认优先使用 Docker：Docker 命令和守护进程可用时，直接拉取公开的 `ghcr.io/pstarchen/monitor-for-server-agent:latest` 镜像并启动容器，不需要 Go 或 git。只有 Docker 不可用时，安装器才使用 `--binary` 指定的本机程序，或拉取源码并用 Go 1.24+ 构建。

```bash
export GUANLAN_AGENT_KEY='<一次性密钥>'
curl -fsSL https://raw.githubusercontent.com/Pstarchen/monitor-for-server/main/deploy/install-agent.sh | \
sudo --preserve-env=GUANLAN_AGENT_KEY bash -s -- \
  --server-url monitor.example.com \
  --device-id '<设备ID>' \
  --interval 3s \
  --disk / \
  --service nginx
```

`--server-url` 只填写域名或 `域名:端口` 即可。安装器会先访问 HTTPS 健康检查；如果 HTTPS 不可用但 HTTP 健康检查可用，会自动回退到 HTTP 并在配置中启用明文连接。也支持直接传入完整的 `http(s)://` 地址。生产环境建议配置 HTTPS；HTTP 仅适合没有证书的临时或内网部署。安装器会把配置写到 `/etc/guanlan-agent/agent.json`，把离线上报缓冲保存在 Docker 卷 `guanlan-agent-spool`，并以只读方式挂载宿主机文件系统用于采集真实主机指标。检查状态：

```bash
docker ps --filter name=guanlan-agent
docker logs --tail 100 guanlan-agent
```

内网可用 `--image registry.example.com/guanlan-agent:版本` 或 `GUANLAN_AGENT_IMAGE` 指定镜像。Docker 不可用时可传 `--binary /path/to/guanlan-agent` 使用本机 systemd 服务；也可用 `--no-docker --binary /path/to/guanlan-agent` 强制本机模式。未提供二进制时会通过 `--source-url` 指定的仓库拉取源码构建。

Linux Docker 模式安装后默认启用每日 Agent 自动更新。更新器依次尝试可用的 `ghcr.nju.edu.cn` 和 `ghcr.1ms.run`，失败后回退到官方 GHCR；可通过 `GUANLAN_AGENT_IMAGE_MIRRORS` 自定义镜像前缀，或用 `--no-auto-update` 关闭。检查和手动执行更新：

```bash
systemctl status guanlan-agent-update.timer
sudo systemctl start guanlan-agent-update.service
```

支持的周期为 `1s`、`3s`、`10s`、`30s`、`60s`。低配置主机可添加 `--skip-processes --skip-connections`。本机回退模式安装后检查：

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
  -ServerUrl 'monitor.example.com' `
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

Windows Agent 默认注册每日自动更新任务；需要关闭时在安装命令中添加 `-NoAutoUpdate`。

## 更新和改信息

- 修改设备名称、分组、位置和主 IP：在总终端“设备管理”编辑，不需要重装 Agent。
- 修改采集周期、磁盘白名单或服务检查：重新生成安装命令，在目标机重新运行安装器；安装器会更新现有容器或本机服务。
- 轮换密钥：总终端管理员执行“轮换密钥”，旧密钥立即失效，然后在目标机重新运行安装器。
- 更新 Agent 版本：重新运行 Linux 安装命令会拉取最新镜像并重建容器；固定版本可传 `--image ghcr.io/pstarchen/monitor-for-server-agent:v1.2.3`。本机模式则替换 `--binary` 指向的新程序并重跑安装器。

安装器传入域名时会优先探测 HTTPS，失败后再探测 HTTP；若最终使用 HTTP，Agent 数据将明文传输，生产环境应尽快配置证书。总控修改“Agent 上报周期”后，已安装 Agent 会在下一次成功上报时自动同步，无需重装。不要把 Agent 密钥放入 URL、日志、工单或鸿蒙 App。
