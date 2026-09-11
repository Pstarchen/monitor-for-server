import { describe, expect, it } from 'vitest'
import { containerCpu, containerValue, diskRateAvailable, networkRateAvailable, processCpu } from './metric-availability'
import type { ContainerMetric, DiskMetric, ProcessMetric } from '@/types'

describe('measurement availability', () => {
  it('retains old report semantics and distinguishes first network samples from real zero', () => {
    expect(networkRateAvailable({})).toBe(true)
    expect(networkRateAvailable({ network: { available: true, ratesAvailable: false } })).toBe(false)
    expect(networkRateAvailable({ network: { available: false, ratesAvailable: true } })).toBe(false)
    expect(networkRateAvailable({ network: { available: true, ratesAvailable: true } })).toBe(true)
  })

  it('shows unavailable Docker data and the first CPU sample as unknown', () => {
    const container = { cpuPercent: 0, memoryPercent: 0 } as ContainerMetric
    expect(containerCpu(container)).toBe(0)
    expect(containerValue(container, 'memoryPercent')).toBe(0)
    expect(containerCpu({ ...container, cpuSampled: false })).toBeNull()
    expect(containerValue({ ...container, statsAvailable: false }, 'memoryPercent')).toBeNull()
  })

  it('requires at least one available disk counter for explicit new reports', () => {
    expect(diskRateAvailable([{ ioAvailable: false }] as DiskMetric[])).toBe(false)
    expect(diskRateAvailable([{ ioAvailable: false }, { ioAvailable: true }] as DiskMetric[])).toBe(true)
    expect(diskRateAvailable([{}] as DiskMetric[])).toBe(true)
    expect(diskRateAvailable([{ ioAvailable: false }, {}] as DiskMetric[])).toBe(false)
  })

  it('keeps a process baseline unknown while allowing a measured idle process', () => {
    expect(processCpu({ cpuPercent: 0 } as ProcessMetric)).toBe(0)
    expect(processCpu({ cpuPercent: 0, cpuSampled: false } as ProcessMetric)).toBeNull()
    expect(processCpu({ cpuPercent: 0, cpuSampled: true } as ProcessMetric)).toBe(0)
  })
})
