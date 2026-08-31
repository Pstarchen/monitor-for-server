import { describe, expect, it } from 'vitest'
import { buildAgentInstallCommand, type AgentInstallCommandOptions } from './agent-install'

const baseOptions: AgentInstallCommandOptions = {
  platform: 'linux',
  source: 'controller',
  serverUrl: 'https://monitor.example.com',
  deviceId: 'device-1',
  agentKey: "agent'key",
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
    expect(command).toContain('curl -fL --retry 3')
    expect(command).toContain('chmod +x xingchen-agent.sh')
    expect(command).toContain("env GUANLAN_AGENT_KEY='agent'\"'\"'key'")
    expect(command).toContain("--disk '/' --disk '/data'")
    expect(command).toContain('--all-processes --process-limit 128')
    expect(command).not.toContain('export GUANLAN_AGENT_KEY')
    expect(command).not.toMatch(/v1\.12\.0|v12|jsdelivr|raw\.githubusercontent/)
    expect(command).not.toContain('](')
  })

  it('uses the Gitee main-branch installer without a historical version pin', () => {
    const command = buildAgentInstallCommand({ ...baseOptions, source: 'gitee', lightweight: true })

    expect(command).toContain('https://gitee.com/starchen520/monitor-for-server/raw/main/deploy/install-agent.sh')
    expect(command).toContain('--skip-processes --skip-connections')
    expect(command).not.toContain('--all-processes')
  })

  it('builds a Windows command for the selected source and clears the temporary key', () => {
    const command = buildAgentInstallCommand({ ...baseOptions, platform: 'windows', source: 'gitee' })

    expect(command).toContain('https://gitee.com/starchen520/monitor-for-server/raw/main/deploy/install-agent.ps1')
    expect(command).toContain("$env:GUANLAN_AGENT_KEY = 'agent''key'")
    expect(command).toContain('Remove-Item Env:GUANLAN_AGENT_KEY')
    expect(command).toContain('Remove-Item $installer')
    expect(command).not.toMatch(/jsdelivr|raw\.githubusercontent/)
  })
})
