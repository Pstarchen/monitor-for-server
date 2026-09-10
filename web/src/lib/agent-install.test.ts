import { describe, expect, it } from 'vitest'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, delimiter } from 'node:path'
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
  const matched = command.match(/-Uri '(https?:\/\/[^']+)'| -- '(https?:\/\/[^']+)' #$/)
  const value = matched?.[1] ?? matched?.[2]
  if (!value) throw new Error(`install command URL not found: ${command}`)
  return new URL(value)
}

describe('buildAgentInstallCommand', () => {
  it('builds a single-line controller-hosted Linux bootstrap command', () => {
    const command = buildAgentInstallCommand(baseOptions)
    const url = commandUrl(command)

    expect(command.split('\n')).toHaveLength(1)
    expect(command).toContain('curl -fsSL --max-redirs 0')
    expect(command).toContain('--tlsv1.2')
    expect(command.startsWith('bash -c ')).toBe(true)
    expect(command.endsWith(' #')).toBe(true)
    expect(command).not.toContain('| bash')
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

    expect(command).not.toContain('--tlsv1.2')
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

const bash = process.env.XINGCHEN_TEST_BASH
  ?? (process.platform === 'win32'
    ? ['D:/Git/bin/bash.exe', 'C:/Program Files/Git/bin/bash.exe'].find(existsSync)
    : '/bin/bash')

describe.runIf(Boolean(bash))('Linux bootstrap command execution', () => {
  function runCommand(downloadStatus: number, installerStatus: number, suffix = '', empty = false) {
    const directory = mkdtempSync(join(tmpdir(), 'xingchen-command-test-'))
    const marker = join(directory, 'executed')
    const payload = join(directory, 'payload')
    const command = buildAgentInstallCommand(baseOptions)
    try {
      writeFileSync(payload, empty ? '' : `#!/usr/bin/env bash\nIFS= read -r input\nprintf '%s' "$input" > "$XINGCHEN_TEST_MARKER"\nexit ${installerStatus}\n`)
      writeFileSync(join(directory, 'curl'), `#!/usr/bin/env bash
set -eu
destination=''
while (( $# )); do
  if [[ "$1" == -o ]]; then destination=$2; shift 2; else shift; fi
done
cp "$XINGCHEN_TEST_PAYLOAD" "$destination"
exit ${downloadStatus}
`, { mode: 0o755 })
      const result = spawnSync(bash!, ['--noprofile', '--norc', '-c', `export PATH="$(cd "$XINGCHEN_TEST_BIN" && pwd):$PATH"; ${command}${suffix}`], {
        encoding: 'utf8',
        input: 'fixture-input\n',
        timeout: 10000,
        env: {
          ...process.env,
          PATH: [directory, dirname(bash!), process.env.PATH ?? ''].join(delimiter),
          TMPDIR: directory.replace(/\\/g, '/'),
          XINGCHEN_TEST_MARKER: marker.replace(/\\/g, '/'),
          XINGCHEN_TEST_PAYLOAD: payload.replace(/\\/g, '/'),
          XINGCHEN_TEST_BIN: directory.replace(/\\/g, '/'),
        },
      })
      if (result.error) throw result.error
      return {
        status: result.status,
        stderr: result.stderr,
        marker: existsSync(marker) ? readFileSync(marker, 'utf8') : null,
        temporaryFiles: readdirSync(directory).filter(name => name.startsWith('xingchen-bootstrap.')),
      }
    } finally {
      rmSync(directory, { recursive: true, force: true })
    }
  }

  it.each([60, 18, 22])('does not execute a partial download when curl exits %i', (status) => {
    const result = runCommand(status, 0)
    expect(result.status).toBe(status)
    expect(result.marker).toBeNull()
    expect(result.stderr).toContain(`curl 退出码 ${status}`)
    expect(result.temporaryFiles).toEqual([])
  })

  it('rejects an empty response instead of reporting an installation success', () => {
    const result = runCommand(0, 0, '', true)
    expect(result.status).toBe(1)
    expect(result.stderr).toContain('引导脚本为空')
    expect(result.marker).toBeNull()
    expect(result.temporaryFiles).toEqual([])
  })

  it('preserves stdin and accepts a CRLF pasted by a browser terminal', () => {
    const result = runCommand(0, 0, '\r\n')
    expect(result.status).toBe(0)
    expect(result.marker).toBe('fixture-input')
    expect(result.temporaryFiles).toEqual([])
  })

  it('preserves the installer failure status and cleans up', () => {
    const result = runCommand(0, 23)
    expect(result.status).toBe(23)
    expect(result.marker).toBe('fixture-input')
    expect(result.temporaryFiles).toEqual([])
  })
})
