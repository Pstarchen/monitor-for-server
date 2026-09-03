import { describe, expect, it } from 'vitest'
import { buildAgentInstallCommand, type AgentInstallCommandOptions } from './agent-install'

const baseOptions: AgentInstallCommandOptions = {
  platform: 'linux',
  serverUrl: 'https://monitor.example.com',
  deviceId: 'device-1',
  collectionSeconds: 30,
  diskMountpoints: ['/', '/data'],
  lightweight: false,
  collectAllProcesses: true,
  processCollectionLimit: 128,
}

describe('buildAgentInstallCommand', () => {
  it('builds a short controller-hosted Linux install command', () => {
    const command = buildAgentInstallCommand(baseOptions)

    expect(command).toContain('https://monitor.example.com/api/setup/agent-installer?platform=linux')
    expect(command).toContain('installer=$(mktemp "${TMPDIR:-/tmp}/xingchen-agent.XXXXXX.sh")')
    expect(command).toContain('curl -fL --max-redirs 0 --retry 3')
    expect(command).toContain("--proto '=https' --proto-redir '=https'")
    expect(command).toContain('platform=linux&format=sha256')
    expect(command).toContain('sha256sum "$installer"')
    expect(command).toContain('test "$actual_sha" = "$expected_sha"')
    expect(command).toContain('chmod 700 "$installer"')
    expect(command).toContain('trap \'rm -f "$installer"\' EXIT')
    expect(command).toContain("env XINGCHEN_SERVER='https://monitor.example.com' XINGCHEN_DEVICE_ID='device-1' \"$installer\" --interval 30s")
    expect(command).not.toContain('-o xingchen-agent.sh')
    expect(command).toContain("--disk '/' --disk '/data'")
    expect(command).toContain('--all-processes --process-limit 128')
    expect(command).not.toContain('export XINGCHEN_AGENT_KEY')
    expect(command).not.toContain('XINGCHEN_AGENT_KEY=')
    expect(command).not.toContain('XINGCHEN_ENROLLMENT_TOKEN')
    expect(command).not.toContain('if [ "$(id -u)"')
    expect(command).not.toMatch(/v1\.12\.0|v12|jsdelivr|raw\.githubusercontent/)
    expect(command).not.toContain('](')
  })

  it('uses the controller for a lightweight install without external source fallbacks', () => {
    const command = buildAgentInstallCommand({ ...baseOptions, lightweight: true })

    expect(command).toContain('https://monitor.example.com/api/setup/agent-installer?platform=linux')
    expect(command).toContain('--skip-processes --skip-connections')
    expect(command).not.toContain('--all-processes')
    expect(command).not.toContain('raw.githubusercontent.com')
    expect(command).not.toContain('gitee.com')
  })

  it('builds a Windows command without putting the Agent key in PowerShell history', () => {
    const command = buildAgentInstallCommand({ ...baseOptions, platform: 'windows' })

    expect(command).toContain('https://monitor.example.com/api/setup/agent-installer?platform=windows')
    expect(command).toContain('platform=windows&format=sha256')
    expect(command).toContain("[Guid]::NewGuid().ToString('N')")
    expect(command).toContain('Get-FileHash -LiteralPath $installer -Algorithm SHA256')
    expect(command).toContain('Agent 安装器 SHA256 校验失败')
    expect(command).not.toContain('XINGCHEN_AGENT_KEY')
    expect(command).not.toContain("agent'key")
    expect(command).toContain('Remove-Item $installer')
    expect(command).not.toMatch(/gitee|github|jsdelivr|raw\.githubusercontent/)
  })
})
