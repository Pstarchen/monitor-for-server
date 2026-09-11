import type { ContainerMetric, DiskMetric, Metric, ProcessMetric } from '@/types'

export function networkRateAvailable(metric: Pick<Metric, 'network'>): boolean {
  return metric.network?.available !== false && metric.network?.ratesAvailable !== false
}

export function diskRateAvailable(disks: DiskMetric[]): boolean {
  return disks.length > 0 && (disks.every((disk) => disk.ioAvailable == null) || disks.some((disk) => disk.ioAvailable === true))
}

export function containerCpu(container: ContainerMetric): number | null {
  return container.statsAvailable === false || container.cpuSampled === false ? null : container.cpuPercent
}

export function processCpu(process: ProcessMetric): number | null {
  return process.cpuSampled === false ? null : process.cpuPercent
}

export function containerValue(container: ContainerMetric, key: 'memoryPercent' | 'memoryUsageBytes' | 'memoryLimitBytes' | 'networkTxBytes' | 'networkRxBytes'): number | null {
  return container.statsAvailable === false ? null : container[key]
}
