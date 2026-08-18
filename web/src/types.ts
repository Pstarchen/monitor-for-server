export type Role = 'ADMIN' | 'OPERATOR' | 'VIEWER'
export type DeviceStatus = 'PENDING' | 'ONLINE' | 'OFFLINE'
export type AlertSeverity = 'INFO' | 'WARNING' | 'CRITICAL'
export type AlertStatus = 'OPEN' | 'ACKNOWLEDGED' | 'RESOLVED'
export type AlertMetric = 'CPU_USAGE' | 'MEMORY_USAGE' | 'DISK_USAGE' | 'DEVICE_OFFLINE'

export interface User {
  id: number
  username: string
  displayName: string
  role: Role
  enabled: boolean
  createdAt: string
}

export interface DiskMetric {
  device: string
  mountpoint: string
  fileSystem: string
  totalBytes: number
  usedBytes: number
  freeBytes: number
  usagePercent: number
  readBytesPerSec: number
  writeBytesPerSec: number
}

export interface ProcessMetric {
  pid: number
  name: string
  username: string
  cpuPercent: number
  memoryPercent: number
  status: string
}

export interface ServiceMetric { name: string; status: string }

export interface Metric {
  id: number
  deviceId: string
  collectedAt: string
  cpuUsage: number
  memoryUsage: number
  swapUsage: number
  load1: number
  load5: number
  load15: number
  diskUsage: number
  diskReadBps: number
  diskWriteBps: number
  networkSentBps: number
  networkRecvBps: number
  tcpConnections: number
  disks: DiskMetric[]
  processes: ProcessMetric[]
  services: ServiceMetric[]
}

export interface Device {
  id: string
  name: string
  hostname: string | null
  os: string | null
  architecture: string | null
  primaryIp: string | null
  location: string | null
  groupName: string | null
  status: DeviceStatus
  lastSeenAt: string | null
  agentKeyPrefix: string
  createdAt: string
  hardware: Record<string, unknown>
  latest: Metric | null
}

export interface DeviceCredential {
  device: Device
  agentKey: string
}

export interface AlertRule {
  id: number
  name: string
  deviceId: string | null
  deviceName: string | null
  metric: AlertMetric
  threshold: number
  severity: AlertSeverity
  enabled: boolean
  updatedAt: string
}

export interface AlertEvent {
  id: number
  deviceId: string
  deviceName: string
  ruleId: number
  ruleName: string
  severity: AlertSeverity
  status: AlertStatus
  value: number
  message: string
  startedAt: string
  acknowledgedAt: string | null
  acknowledgedBy: string | null
  resolvedAt: string | null
}

export interface Dashboard {
  totalDevices: number
  onlineDevices: number
  offlineDevices: number
  pendingDevices: number
  activeAlerts: number
  averageCpu: number
  averageMemory: number
  averageDisk: number
  networkSentBps: number
  networkRecvBps: number
  devices: Device[]
  topDevices: Device[]
  recentAlerts: AlertEvent[]
}

export interface EmailSettings {
  enabled: boolean
  configured: boolean
  source: 'DATABASE' | 'ENVIRONMENT' | 'NONE'
  host: string
  port: number
  username: string
  from: string
  recipients: string
  auth: boolean
  startTls: boolean
  passwordConfigured: boolean
}

export interface WebhookSettings {
  enabled: boolean
  configured: boolean
  source: 'DATABASE' | 'ENVIRONMENT' | 'NONE'
  webhookConfigured: boolean
}

export interface Settings {
  metricRetentionDays: number
  deviceOfflineAfterSeconds: number
  defaultCollectionSeconds: number
  siteName: string
  publicBaseUrl: string
  timezone: string
  secretStorageReady: boolean
  email: EmailSettings
  dingtalk: WebhookSettings
  wecom: WebhookSettings
}

export interface AgentBootstrap {
  publicBaseUrl: string
  defaultCollectionSeconds: number
}

export interface AuditLog {
  id: number
  actor: string
  action: string
  target: string
  summary: string
  createdAt: string
}

export interface SetupStatus {
  configured: boolean
  state: 'ready' | 'applying' | 'configured' | 'error' | 'unavailable'
  message?: string
  baseUrl?: string
}

export interface SetupRequest {
  mysqlHost: string
  mysqlPort: number
  databaseName: string
  mysqlUsername: string
  mysqlPassword: string
  publicBaseUrl: string
  allowedOrigins: string
  siteName: string
  timezone: string
  webPort: number
  webBindAddress: '0.0.0.0' | '127.0.0.1'
  adminUsername: string
  adminPassword: string
  adminPasswordConfirm: string
}
