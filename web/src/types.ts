export type Role = 'ADMIN' | 'OPERATOR' | 'VIEWER'
export type DeviceStatus = 'PENDING' | 'ONLINE' | 'OFFLINE'
export type AlertSeverity = 'INFO' | 'WARNING' | 'CRITICAL'
export type AlertStatus = 'OPEN' | 'ACKNOWLEDGED' | 'RESOLVED'
export type AlertMetric = 'CPU_USAGE' | 'MEMORY_USAGE' | 'DISK_USAGE' | 'LOAD_1' | 'DISK_READ_BPS' | 'DISK_WRITE_BPS' | 'CONTAINER_CPU_USAGE' | 'CONTAINER_MEMORY_USAGE' | 'GPU_USAGE' | 'BATTERY_PERCENT' | 'SMART_FAILURES' | 'INTEGRITY_CHANGES' | 'FIREWALL_INACTIVE' | 'TCP_CONNECTIONS' | 'NETWORK_RECV_BPS' | 'NETWORK_SENT_BPS' | 'TEMPERATURE' | 'DEVICE_OFFLINE'

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
  smart?: SmartHealthMetric | null
}

export interface SmartHealthMetric {
  status: 'PASSED' | 'FAILED' | 'UNKNOWN' | string
  message: string
  temperature: number
  powerOnHours: number
  percentageUsed: number
  mediaErrors: number
  unsafeShutdowns: number
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

export interface NetworkInterfaceMetric {
  name: string
  mtu: number
  hardwareAddr: string
  flags: string[]
  addresses: string[]
}

export interface PortMetric {
  protocol: string
  address: string
  port: number
  pid: number
}

export interface ContainerMetric {
  id: string
  name: string
  image: string
  state: string
  status: string
  cpuPercent: number
  memoryUsageBytes: number
  memoryLimitBytes: number
  memoryPercent: number
  networkRxBytes: number
  networkTxBytes: number
  restartCount: number
}

export interface FanMetric { name: string; rpm: number }
export interface BatteryMetric { name: string; percent: number; status: string }
export interface GpuMetric { index: number; name: string; usagePercent: number; memoryUsedBytes: number; memoryTotalBytes: number; temperature: number }
export interface FirewallMetric { provider: string; state: 'ACTIVE' | 'INACTIVE' | 'UNKNOWN' | string; message?: string }
export interface CronJobMetric { source: string; user: string; schedule: string; command: string }
export interface LogFileMetric { path: string; sizeBytes: number; modifiedAt: string; lines: string[] }
export interface IntegrityMetric { path: string; sha256: string; sizeBytes: number; modifiedAt: string }

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
  networkSentBytes: number
  networkRecvBytes: number
  tcpConnections: number
  temperatureMax: number
  gpuUsage: number | null
  batteryPercent: number | null
  containerCpuUsage: number | null
  containerMemoryUsage: number | null
  smartPassed: number
  smartFailed: number
  smartUnknown: number
  integrityChanges: number
  firewallInactive: number | null
  networkInterfaces: NetworkInterfaceMetric[]
  ports: PortMetric[]
  containers: ContainerMetric[]
  disks: DiskMetric[]
  processes: ProcessMetric[]
  services: ServiceMetric[]
  fans: FanMetric[]
  batteries: BatteryMetric[]
  gpus: GpuMetric[]
  firewall: FirewallMetric | null
  cronJobs: CronJobMetric[]
  logs: LogFileMetric[]
  integrity: IntegrityMetric[]
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
  ddnsEnabled: boolean
  ddnsConfigId: number | null
  publicVisible: boolean
  status: DeviceStatus
  lastSeenAt: string | null
  agentKeyPrefix: string
  controllerManaged: boolean
  createdAt: string
  hardware: Record<string, unknown>
  latest: Metric | null
}

export type DdnsProvider = 'DUMMY' | 'WEBHOOK'
export type DdnsHttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'
export interface DdnsConfig {
  id: number
  name: string
  provider: DdnsProvider
  domains: string[]
  webhookConfigured: boolean
  method: DdnsHttpMethod
  enabled: boolean
  ipv4Enabled: boolean
  ipv6Enabled: boolean
  maxRetries: number
  lastStatus: string | null
  lastError: string | null
  lastUpdatedAt: string | null
  credentialOneConfigured: boolean
  credentialTwoConfigured: boolean
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
  smartFailures: number
  integrityChanges: number
  firewallInactive: number
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
  keyword?: string
  keywordConfigured?: boolean
  signSecretConfigured?: boolean
}

export interface Settings {
  metricRetentionDays: number
  deviceOfflineAfterSeconds: number
  defaultCollectionSeconds: number
  siteName: string
  siteIconUrl: string
  publicBaseUrl: string
  timezone: string
  enableMcp: boolean
  secretStorageReady: boolean
  email: EmailSettings
  dingtalk: WebhookSettings
  wecom: WebhookSettings
}

export interface PublicBrand {
  siteName: string
  siteIconUrl: string
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
  publicBaseUrl: string
  allowedOrigins: string
  siteName: string
  timezone: string
  adminUsername: string
  adminPassword: string
  adminPasswordConfirm: string
}

export type ControllerUpdatePhase = 'IDLE' | 'CHECKING' | 'UPDATING' | 'ERROR'

export interface ControllerServiceStatus {
  name: 'setup' | 'server' | 'web' | string
  revision?: string
  health: string
}

export interface ControllerUpdateStatus {
  state: ControllerUpdatePhase
  currentRevision?: string
  latestRevision?: string
  updateAvailable: boolean
  message?: string
  checkedAt?: string
  updatedAt?: string
  autoUpdate: boolean
  nextAutoUpdateAt?: string
  services: ControllerServiceStatus[]
}

export interface ApiToken {
  id: number
  name: string
  tokenPrefix: string
  scopes: string[]
  serverIds: string[]
  expiresAt: string | null
  lastUsedAt: string | null
  lastUsedIp: string | null
  revokedAt: string | null
  createdAt: string
}

export interface CreatedApiToken {
  token: ApiToken
  secret: string
}

export type AgentTaskStatus = 'QUEUED' | 'RUNNING' | 'SUCCEEDED' | 'FAILED' | 'TIMED_OUT' | 'CANCELED'
export type AgentTaskOperation = 'COMMAND' | 'FILE_LIST' | 'FILE_READ' | 'FILE_WRITE' | 'FILE_DELETE'

export interface AgentTask {
  id: number
  deviceId: string
  deviceName: string
  operation: AgentTaskOperation
  command: string
  args: string[]
  timeoutSeconds: number
  maxOutputBytes: number
  status: AgentTaskStatus
  createdBy: string
  createdAt: string
  startedAt: string | null
  finishedAt: string | null
  exitCode: number | null
  stdout: string
  stderr: string
  error: string
}

export type ServiceCheckType = 'HTTP_GET' | 'ICMP_PING' | 'TCPING' | 'HEARTBEAT'

export interface ServiceCheckResult {
  checkedAt: string
  success: boolean
  latencyMs: number
  statusCode: number | null
  certificateExpiresAt: string | null
  error: string | null
}

export interface ServiceCheck {
  id: number
  name: string
  target: string
  type: ServiceCheckType
  intervalSeconds: number
  timeoutMs: number
  publicVisible: boolean
  sortOrder: number
  enabled: boolean
  failureThreshold: number
  latencyThresholdMs: number
  certificateThresholdDays: number
  alertActive: boolean
  createdAt: string
  updatedAt: string
  latest: ServiceCheckResult | null
  availabilityPercent: number | null
  history: ServiceCheckResult[]
  heartbeatTokenPrefix?: string | null
  heartbeatToken?: string | null
  heartbeatPath?: string | null
}

export interface PublicServiceCheckResult {
  checkedAt: string
  success: boolean
  latencyMs: number
  statusCode: number | null
  certificateExpiresAt: string | null
}

export interface PublicServiceCheck {
  id: number
  name: string
  type: ServiceCheckType
  sortOrder: number
  latest: PublicServiceCheckResult | null
  availabilityPercent: number | null
  history: PublicServiceCheckResult[]
}

export interface PublicDevice {
  id: string
  name: string
  groupName: string | null
  os: string | null
  status: DeviceStatus
  lastSeenAt: string | null
  cpuUsage: number
  memoryUsage: number
  diskUsage: number
  networkSentBps: number
  networkRecvBps: number
  networkSentBytes: number
  networkRecvBytes: number
  uptimeSeconds: number
}

export interface PublicOverview {
  siteName: string
  generatedAt: string
  totalDevices: number
  onlineDevices: number
  offlineDevices: number
  networkSentBps: number
  networkRecvBps: number
  totalNetworkSentBytes: number
  totalNetworkRecvBytes: number
  devices: PublicDevice[]
  services: PublicServiceCheck[]
}
