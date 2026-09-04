import { describe, expect, it } from 'vitest'
import { buildAgentInstallCommand, type AgentInstallCommandOptions } from './agent-install'

const baseOptions: AgentInstallCommandOptions = {
  platform: 'linux',
  serverUrl: 'https://monitor.example.com',
  deviceId: '123e4567-e89b-42d3-a456-426614174000',
  collectionSeconds: 30,
  diskMountpoints: ['/', '/data'],
  lightweight: false,
  collectAllProcesses: true,
  processCollectionLimit: 128,
}

function commandUrl(command: string): URL {
  const matched = command.match(/-Uri '(https?:\/\/[^']+)'| '(https?:\/\/[^']+)' \| bash/)
  const value = matched?.[1] ?? matched?.[2]
  if (!value) throw new Error(`install command URL not found: ${command}`)
  return new URL(value)
}

describe('buildAgentInstallCommand', () => {
  it('builds a single-line controller-hosted Linux bootstrap command', () => {
    const command = buildAgentInstallCommand(baseOptions)
    const url = commandUrl(command)

    expect(command.split('\n')).toHaveLength(1)
    expect(command).toContain("curl -fsSL --max-redirs 0 --proto '=https' --proto-redir '=https'")
    expect(command.endsWith('| bash')).toBe(true)
    expect(url.origin).toBe('https://monitor.example.com')
    expect(url.pathname).toBe('/api/setup/agent-bootstrap')
    expect(url.searchParams.get('platform')).toBe('linux')
    expect(url.searchParams.get('deviceId')).toBe(baseOptions.deviceId)
    expect(url.searchParams.get('interval')).toBe('30s')
    expect(url.searchParams.getAll('disk')).toEqual(['/', '/data'])
    expect(url.searchParams.get('collectAllProcesses')).toBe('true')
    expect(url.searchParams.get('processLimit')).toBe('128')
    expect(command).not.toMatch(/agent-installer|sha256sum|format=sha256/)
    expect(command).not.toMatch(/XINGCHEN_(AGENT_KEY|ENROLLMENT_TOKEN)/)
    expect(command).not.toMatch(/github|gitee|jsdelivr|raw\.githubusercontent/i)
  })

  it('encodes lightweight options without exposing shell syntax', () => {
    const command = buildAgentInstallCommand({
      ...baseOptions,
      diskMountpoints: ['/srv/data (primary)'],
      lightweight: true,
      collectAllProcesses: false,
    })
    const url = commandUrl(command)

    expect(url.searchParams.getAll('disk')).toEqual(['/srv/data (primary)'])
    expect(url.searchParams.get('lightweight')).toBe('true')
    expect(url.searchParams.has('collectAllProcesses')).toBe(false)
    expect(url.searchParams.has('processLimit')).toBe(false)
  })

  it('builds a single-line Windows bootstrap command', () => {
    const command = buildAgentInstallCommand({
      ...baseOptions,
      platform: 'windows',
      diskMountpoints: ['C:\\', 'D:\\Data'],
    })
    const url = commandUrl(command)

    expect(command.split('\n')).toHaveLength(1)
    expect(command.startsWith('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command')).toBe(true)
    expect(command).toContain('Invoke-RestMethod -TimeoutSec 60 -MaximumRedirection 0')
    expect(command.endsWith('| Invoke-Expression"')).toBe(true)
    expect(url.pathname).toBe('/api/setup/agent-bootstrap')
    expect(url.searchParams.get('platform')).toBe('windows')
    expect(url.searchParams.getAll('disk')).toEqual(['C:\\', 'D:\\Data'])
    expect(command).not.toMatch(/agent-installer|Get-FileHash|format=sha256/)
    expect(command).not.toMatch(/XINGCHEN_(AGENT_KEY|ENROLLMENT_TOKEN)/)
  })

  it('uses only the explicitly configured HTTP protocol', () => {
    const command = buildAgentInstallCommand({
      ...baseOptions,
      serverUrl: 'http://127.0.0.1:18080',
      collectAllProcesses: false,
    })

    expect(command).toContain("--proto '=http' --proto-redir '=http'")
    expect(commandUrl(command).origin).toBe('http://127.0.0.1:18080')
  })

  it('rejects malformed origins, devices and collection options', () => {
    expect(() => buildAgentInstallCommand({ ...baseOptions, serverUrl: 'https://user:secret@monitor.example.com' })).toThrow(/Controller/)
    expect(() => buildAgentInstallCommand({ ...baseOptions, serverUrl: 'https://monitor.example.com/path' })).toThrow(/Controller/)
    expect(() => buildAgentInstallCommand({ ...baseOptions, deviceId: "device'; curl evil" })).toThrow(/设备 ID/)
    expect(() => buildAgentInstallCommand({ ...baseOptions, collectionSeconds: 2 })).toThrow(/采集周期/)
    expect(() => buildAgentInstallCommand({ ...baseOptions, diskMountpoints: ["/data'; curl evil"] })).toThrow(/磁盘白名单/)
    expect(() => buildAgentInstallCommand({ ...baseOptions, lightweight: true })).toThrow(/不能同时/)
    expect(() => buildAgentInstallCommand({ ...baseOptions, processCollectionLimit: 257 })).toThrow(/进程上限/)
  })
})
