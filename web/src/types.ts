export type Role = 'ADMIN' | 'OPERATOR' | 'VIEWER'
export type DeviceStatus = 'PENDING' | 'ONLINE' | 'OFFLINE'
export type AgentUpdateStatus = 'IDLE' | 'CHECKING' | 'DOWNLOADING' | 'APPLYING' | 'SUCCEEDED' | 'FAILED' | 'PAUSED' | 'ROLLING_BACK'
export type DeviceHealthState = 'HEALTHY' | 'PENDING' | 'OFFLINE' | 'DEGRADED'
export type DeviceHealthSeverity = 'INFO' | 'WARNING' | 'CRITICAL'
export type DeviceHealthCheckState = 'PASS' | 'PENDING' | 'WARN' | 'FAIL'
export type AlertSeverity = 'INFO' | 'WARNING' | 'CRITICAL'
export type AlertStatus = 'OPEN' | 'ACKNOWLEDGED' | 'RESOLVED'
export type AlertMetric = 'CPU_USAGE' | 'MEMORY_USAGE' | 'DISK_USAGE' | 'LOAD_1' | 'DISK_READ_BPS' | 'DISK_WRITE_BPS' | 'CONTAINER_CPU_USAGE' | 'CONTAINER_MEMORY_USAGE' | 'GPU_USAGE' | 'BATTERY_PERCENT' | 'SMART_FAILURES' | 'INTEGRITY_CHANGES' | 'FIREWALL_INACTIVE' | 'TCP_CONNECTIONS' | 'NETWORK_RECV_BPS' | 'NETWORK_SENT_BPS' | 'TEMPERATURE' | 'FAN_RPM' | 'DEVICE_OFFLINE' | 'PROCESS_MISSING' | 'SERVICE_NOT_RUNNING' | 'CUSTOM_METRIC'

export interface User {
  id: number
  username: string
  displayName: string
  role: Role
  enabled: boolean
  twoFactorEnabled: boolean
  createdAt: string
}

export interface DevicePermission {
  deviceId: string
  deviceName: string
  canView: boolean
  canManage: boolean
  canAlert: boolean
  canTask: boolean
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
  commandLine: string
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
export interface CustomMetricResult { name: string; kind: string; value: number | null; text: string | null; exitCode: number; success: boolean; error: string | null }

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
  systemLogs: LogFileMetric[]
  integrity: IntegrityMetric[]
  customMetrics: CustomMetricResult[]
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
  tags: string[]
  assetTag: string | null
  ownerName: string | null
  vendor: string | null
  model: string | null
  serialNumber: string | null
  environment: string | null
  purchaseDate: string | null
  warrantyExpiresAt: string | null
  description: string | null
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
  health: DeviceHealth
  agentVersion: string | null
  agentUpdateStatus: AgentUpdateStatus
  agentLastUpdateError: string | null
  agentUpdateStateChangedAt: string | null
}

export interface DeviceNote {
  id: number
  deviceId: string
  deviceName: string
  author: string
  content: string
  createdAt: string
}

export interface DeviceStatusEvent {
  id: number
  previousStatus: DeviceStatus | null
  status: DeviceStatus
  reason: string
  changedAt: string
}

export interface DeviceHealthCheck {
  code: string
  state: DeviceHealthCheckState
  label: string
  detail: string
}

export interface DeviceHealth {
  deviceStatus: DeviceStatus
  state: DeviceHealthState
  reasonCode: string
  reason: string
  severity: DeviceHealthSeverity
  lastSeenAt: string | null
  lastSeenAgeSeconds: number | null
  offlineAfterSeconds: number
  latestCollectedAt: string | null
  dataAgeSeconds: number | null
  expectedBy: string | null
  checks: DeviceHealthCheck[]
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

export interface DeviceEnrollmentToken {
  token: string
  expiresAt: string
}

export interface AlertRule {
  id: number
  name: string
  deviceId: string | null
  deviceName: string | null
  metric: AlertMetric
  threshold: number
  severity: AlertSeverity
  targetName: string | null
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
  notificationSuppressed: boolean
  notifiedAt: string | null
}

export interface AlertAcknowledgeRequest { ids: number[] }

export type MaintenanceRecurrence = 'NONE' | 'DAILY' | 'WEEKLY'

export interface MaintenanceWindow {
  id: number
  name: string
  deviceId: string | null
  deviceName: string | null
  ruleId: number | null
  ruleName: string | null
  scopeDeviceId: string | null
  startsAt: string
  endsAt: string
  timezone: string
  recurrence: MaintenanceRecurrence
  repeatUntil: string | null
  reason: string | null
  enabled: boolean
  active: boolean
  updatedAt: string
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

export interface ReportDevice {
  id: string
  name: string
  status: DeviceStatus
  samples: number
  averageCpu: number
  averageMemory: number
  averageDisk: number
  peakPressure: number
}

export interface ReportService {
  id: number
  name: string
  type: ServiceCheckType
  samples: number
  availabilityPercent: number
  averageLatencyMs: number
  incidents: number
}

export interface MonitorReport {
  from: string
  to: string
  generatedAt: string
  totalDevices: number
  onlineDevices: number
  offlineDevices: number
  alertCount: number
  activeAlertCount: number
  devices: ReportDevice[]
  services: ReportService[]
}

export interface NotificationDelivery {
  id: number
  channel: 'email' | 'dingtalk' | 'wecom' | 'generic' | string
  status: 'SUCCESS' | 'FAILED' | 'SKIPPED' | string
  message: string
  error: string | null
  attempts: number
  createdAt: string
  finishedAt: string | null
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
  payloadFormat?: 'GENERIC_JSON' | 'SLACK' | 'DISCORD' | 'LARK' | 'PLAIN_TEXT' | string
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
  generic: WebhookSettings
  pushKit: PushKitSettings
}

export interface MetricHistoryPoint {
  collectedAt: string
  cpuUsage: number
  memoryUsage: number
  swapUsage: number
  load1: number
  load5: number
  load15: number
  temperatureCelsius: number
  diskUsage: number
  networkSentBps: number
  networkRecvBps: number
}

export interface MetricHistoryResponse {
  deviceId: string
  range: string
  from: string
  to: string
  sampleStepSeconds: number
  points: MetricHistoryPoint[]
}

export interface PushKitSettings {
  enabled: boolean
  configured: boolean
  source: 'DATABASE' | 'ENVIRONMENT' | 'NONE'
  projectId: string
  keyId: string
  subAccount: string
  privateKeyConfigured: boolean
  category: string
  ttlSeconds: number
  batchSize: number
  maxAttempts: number
}

export interface PushKitInstallation {
  id: string
  platform: 'HARMONYOS'
  tokenSuffix: string | null
  appVersion: string | null
  deviceModel: string | null
  enabled: boolean
  lastRegisteredAt: string | null
  lastTestAt: string | null
  createdAt: string
  updatedAt: string
}

export interface PushKitValidationResult {
  status: 'VALID'
  message: string
  checkedAt: string
}

export interface TopologyNode {
  id: string
  label: string
  kind: 'CONTROLLER' | 'DEVICE' | 'EXTERNAL' | string
  status: string
  hostname: string | null
  address: string | null
  cpuUsage: number | null
  memoryUsage: number | null
  diskUsage: number | null
  serviceCount: number
}

export interface TopologyEdge {
  id: string
  source: string
  target: string
  label: string
  type: ServiceCheckType
  status: 'UP' | 'DOWN' | 'UNKNOWN' | 'DISABLED' | string
  latencyMs: number | null
  targetHost: string
}

export interface Topology {
  nodes: TopologyNode[]
  edges: TopologyEdge[]
  monitoredServices: number
  unresolvedServices: number
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
  version?: string
  health: string
}

export interface ControllerUpdateStatus {
  state: ControllerUpdatePhase
  currentRevision?: string
  latestRevision?: string
  currentVersion?: string
  latestVersion?: string
  updateAvailable: boolean
  message?: string
  releaseName?: string
  releaseNotes?: string
  releaseUrl?: string
  releasePublishedAt?: string
  releaseCached?: boolean
  releaseWarning?: string
  releaseSource?: string
  releaseVerification?: string
  checkedAt?: string
  updatedAt?: string
  autoUpdate: boolean
  autoFailureCount?: number
  autoPaused?: boolean
  autoPausedUntil?: string
  nextAutoUpdateAt?: string
  trigger?: 'manual' | 'automatic'
  phase?: string
  rollbackState?: string
  backupName?: string
  databaseCompatibility?: string
  services: ControllerServiceStatus[]
}

export interface ControllerBackupFile {
  name: string
  size: number
  createdAt: string
}

export type ControllerBackupPhase = 'IDLE' | 'CREATING' | 'RESTORING' | 'ERROR'

export interface ControllerBackupStatus {
  state: ControllerBackupPhase
  message?: string
  startedAt?: string
  finishedAt?: string
  lastBackup?: string
  lastAutoRunDate?: string
  autoBackup: boolean
  retention: number
  backups: ControllerBackupFile[]
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
export type AgentTaskOperation = 'COMMAND' | 'FILE_LIST' | 'FILE_READ' | 'FILE_WRITE' | 'FILE_DELETE' | 'AGENT_UPDATE'

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

export type AgentRolloutStatus = 'DRAFT' | 'RUNNING' | 'PAUSED' | 'CANCELED' | 'SUCCEEDED' | 'FAILED' | 'ROLLING_BACK' | 'ROLLED_BACK'
export type AgentRolloutMemberStatus = 'PENDING' | 'QUEUED' | 'ACCEPTED' | 'CONFIRMED' | 'FAILED' | 'CANCELED'
  | 'ROLLBACK_PENDING' | 'ROLLBACK_QUEUED' | 'ROLLBACK_ACCEPTED' | 'ROLLBACK_CONFIRMED' | 'ROLLBACK_FAILED'

export interface AgentRolloutMember {
  id: number
  deviceId: string
  deviceName: string
  previousVersion: string
  ring: number
  order: number
  eligibleAt: string | null
  taskId: number | null
  status: AgentRolloutMemberStatus
  attempt: number
  queuedAt: string | null
  error: string | null
  confirmedAt: string | null
}

export interface AgentRollout {
  id: number
  targetVersion: string
  maintenanceWindowId: number | null
  canaryPercent: number
  ringCount: number
  currentRing: number
  maxConcurrent: number
  jitterSeconds: number
  failureThreshold: number
  verificationTimeoutSeconds: number
  status: AgentRolloutStatus
  statusReason: string | null
  createdBy: string
  createdAt: string
  updatedAt: string
  startedAt: string | null
  completedAt: string | null
  rollbackStartedAt: string | null
  rollbackTotal: number | null
  members: AgentRolloutMember[]
}

export type ServiceCheckType = 'HTTP_GET' | 'ICMP_PING' | 'TCPING' | 'FTP' | 'SFTP' | 'SNMP' | 'REDIS_PING' | 'POSTGRESQL' | 'MYSQL' | 'HEARTBEAT'

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
  expectedStatus: number | null
  bodyContains: string | null
  credentialConfigured: boolean
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

export type DiscoveryScanStatus = 'QUEUED' | 'RUNNING' | 'SUCCEEDED' | 'FAILED' | 'CANCELED'

export interface DiscoveryScan {
  id: number
  cidr: string
  ports: number[]
  timeoutMs: number
  concurrency: number
  status: DiscoveryScanStatus
  totalHosts: number
  scannedHosts: number
  discoveredHosts: number
  createdBy: string
  createdAt: string
  startedAt: string | null
  finishedAt: string | null
  error: string | null
}

export interface DiscoveryResult {
  id: number
  address: string
  hostname: string | null
  reachable: boolean
  openPorts: number[]
  latencyMs: number | null
  discoveredAt: string
}

export interface DiscoveryDetail {
  scan: DiscoveryScan
  results: DiscoveryResult[]
}
