<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import {
  Activity, ArrowDown, ArrowUp, BellRing, CheckCircle2, Clock3, Cpu, HardDrive,
  FileWarning, Gauge, MapPin, MemoryStick, MessageSquare, RefreshCw, Search, Server, ShieldAlert, ShieldCheck, WifiOff,
} from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import MetricCard from '@/components/MetricCard.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import ServiceAvailabilityCard from '@/components/ServiceAvailabilityCard.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import MetricChart from '@/components/MetricChart.vue'
import { api, errorMessage } from '@/lib/api'
import { trendWindow, type TrendRangeHours } from '@/lib/dashboard-trend'
import { dateTime, percent, rate, rateScale, relativeTime, uptime } from '@/lib/format'
import { useVisibilityPolling } from '@/lib/visibility-polling'
import type { Dashboard, Device, DeviceNote, DeviceStatus, Metric, ServiceCheck } from '@/types'

type SortKey = 'attention' | 'cpu' | 'memory' | 'disk' | 'name'

const router = useRouter()
const dashboard = ref<Dashboard | null>(null)
const serviceChecks = ref<ServiceCheck[]>([])
const loading = ref(true)
const refreshing = ref(false)
const error = ref('')
const servicesError = ref('')
const servicesRefreshing = ref(false)
const recentNotes = ref<DeviceNote[]>([])
const notesError = ref('')
const search = ref('')
const status = ref<DeviceStatus | ''>('')
const group = ref('')
const tag = ref('')
const sort = ref<SortKey>('attention')
const trendDeviceIds = ref<string[]>([])
const trendRangeHours = ref<TrendRangeHours>(6)
const trendHistories = ref<Record<string, Metric[]>>({})
const trendLoading = ref(false)
const trendError = ref('')
let refreshTimer = 0
let trendRequestId = 0

const groups = computed(() => Array.from(new Set(
  (dashboard.value?.devices ?? []).map((device) => device.groupName).filter((value): value is string => Boolean(value)),
)).sort((left, right) => left.localeCompare(right, 'zh-CN')))
const tags = computed(() => Array.from(new Set(
  (dashboard.value?.devices ?? []).flatMap((device) => device.tags ?? []),
)).sort((left, right) => left.localeCompare(right, 'zh-CN')))

const filteredDevices = computed(() => {
  const needle = search.value.trim().toLowerCase()
  const statusRank: Record<DeviceStatus, number> = { OFFLINE: 0, PENDING: 1, ONLINE: 2 }
  return (dashboard.value?.devices ?? [])
    .filter((device) => (!status.value || device.status === status.value)
      && (!group.value || device.groupName === group.value)
      && (!tag.value || (device.tags ?? []).includes(tag.value))
      && (!needle || [device.name, device.hostname, device.primaryIp, device.location, device.groupName, device.os, ...(device.tags ?? [])]
        .some((value) => value?.toLowerCase().includes(needle))))
    .slice()
    .sort((left, right) => {
      if (sort.value === 'name') return left.name.localeCompare(right.name, 'zh-CN')
      if (sort.value === 'attention') return statusRank[left.status] - statusRank[right.status]
        || metric(right, 'cpuUsage') - metric(left, 'cpuUsage')
      return metric(right, `${sort.value}Usage`) - metric(left, `${sort.value}Usage`)
    })
})

const onlineServices = computed(() => serviceChecks.value.filter((service) => service.latest?.success).length)
const trendDevices = computed(() => (dashboard.value?.devices ?? []).filter((device) => device.latest || device.status === 'ONLINE'))
const selectedTrendDevices = computed(() => trendDevices.value.filter((device) => trendDeviceIds.value.includes(device.id)))
const trendDevice = computed(() => selectedTrendDevices.value[0] ?? null)
const trendDeviceId = computed(() => trendDeviceIds.value[0] ?? '')
const trendHistory = computed(() => trendDeviceId.value ? trendHistories.value[trendDeviceId.value] ?? [] : [])
const trendLatest = computed(() => trendHistory.value[trendHistory.value.length - 1] ?? trendDevice.value?.latest ?? null)
const trendLabels = computed(() => trendHistory.value.map((item) => new Intl.DateTimeFormat('zh-CN', {
  hour: '2-digit', minute: '2-digit', second: trendRangeHours.value === 1 ? '2-digit' : undefined,
}).format(new Date(item.collectedAt))))
const trendIoScale = computed(() => rateScale(selectedTrendDevices.value.flatMap((device) => trendHistories.value[device.id] ?? []).reduce((max, item) => Math.max(max, item.networkRecvBps, item.networkSentBps), 0)))
const trendPalette = ['#2867a6', '#17834d', '#986400', '#c73832']

function alignedValues(deviceId: string, read: (metric: Metric) => number) {
  const source = trendHistories.value[deviceId] ?? []
  if (deviceId === trendDeviceId.value) return source.map(read)
  return trendHistory.value.map((point) => {
    let nearest: Metric | undefined
    let distance = Number.POSITIVE_INFINITY
    for (const item of source) {
      const candidate = Math.abs(new Date(item.collectedAt).getTime() - new Date(point.collectedAt).getTime())
      if (candidate < distance) { nearest = item; distance = candidate }
    }
    return nearest && distance <= 5 * 60_000 ? read(nearest) : null
  })
}

const trendResourceSeries = computed(() => selectedTrendDevices.value.flatMap((device, index) => [
  { name: `${device.name} · CPU`, data: alignedValues(device.id, (item) => item.cpuUsage), color: trendPalette[index % trendPalette.length] },
  { name: `${device.name} · 内存`, data: alignedValues(device.id, (item) => item.memoryUsage), color: trendPalette[(index + 1) % trendPalette.length] },
]))
const trendIoSeries = computed(() => selectedTrendDevices.value.flatMap((device, index) => [
  { name: `${device.name} · 接收`, data: alignedValues(device.id, (item) => item.networkRecvBps / trendIoScale.value.divisor), color: trendPalette[index % trendPalette.length] },
  { name: `${device.name} · 发送`, data: alignedValues(device.id, (item) => item.networkSentBps / trendIoScale.value.divisor), color: trendPalette[(index + 1) % trendPalette.length] },
]))
const trendLoad = computed(() => trendLatest.value ? `${trendLatest.value.load1.toFixed(2)} / ${trendLatest.value.load5.toFixed(2)} / ${trendLatest.value.load15.toFixed(2)}` : '--')

function syncTrendDevice() {
  const available = new Set(trendDevices.value.map((device) => device.id))
  const current = trendDeviceIds.value.filter((id) => available.has(id)).slice(0, 4)
  trendDeviceIds.value = current.length ? current : (trendDevices.value[0] ? [trendDevices.value[0].id] : [])
}

async function loadTrend() {
  const ids = [...trendDeviceIds.value]
  if (!ids.length) {
    trendHistories.value = {}
    trendError.value = ''
    return
  }
  const requestId = ++trendRequestId
  trendLoading.value = true
  trendError.value = ''
  const { from, to } = trendWindow(trendRangeHours.value)
  try {
    const responses = await Promise.allSettled(ids.map((id) => api.get<Metric[]>(`/devices/${id}/metrics/history`, { params: { from: from.toISOString(), to: to.toISOString() } })))
    if (requestId !== trendRequestId) return
    const next: Record<string, Metric[]> = {}
    let failures = 0
    responses.forEach((response, index) => {
      if (response.status === 'fulfilled') next[ids[index]] = response.value.data
      else failures += 1
    })
    if (failures === ids.length) {
      const failed = responses.find((response): response is PromiseRejectedResult => response.status === 'rejected')
      throw failed?.reason ?? new Error('趋势数据加载失败')
    }
    trendHistories.value = next
    if (failures) trendError.value = `${failures} 台设备趋势暂时不可用`
  } catch (cause) {
    if (requestId === trendRequestId) trendError.value = errorMessage(cause)
  } finally {
    if (requestId === trendRequestId) trendLoading.value = false
  }
}

async function load(background = false) {
  if (background) refreshing.value = true
  else loading.value = true
  error.value = ''
  try {
    const [dashboardRequest, servicesRequest, notesRequest] = await Promise.allSettled([
      api.get<Dashboard>('/dashboard'),
      api.get<ServiceCheck[]>('/services'),
      api.get<DeviceNote[]>('/device-notes/recent', { params: { limit: 8 } }),
    ])
    if (dashboardRequest.status === 'rejected') throw dashboardRequest.reason
    dashboard.value = dashboardRequest.value.data
    if (servicesRequest.status === 'fulfilled') {
      serviceChecks.value = servicesRequest.value.data
      servicesError.value = ''
    } else {
      servicesError.value = errorMessage(servicesRequest.reason)
    }
    if (notesRequest.status === 'fulfilled') {
      recentNotes.value = notesRequest.value.data
      notesError.value = ''
    } else {
      notesError.value = errorMessage(notesRequest.reason)
    }
    syncTrendDevice()
    if (background && trendDeviceIds.value.length) void loadTrend()
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
    refreshing.value = false
  }
}

async function loadServices() {
  servicesRefreshing.value = true
  try {
    serviceChecks.value = (await api.get<ServiceCheck[]>('/services')).data
    servicesError.value = ''
  } catch (cause) {
    servicesError.value = errorMessage(cause)
  } finally {
    servicesRefreshing.value = false
  }
}

function metric(device: Device, key: 'cpuUsage' | 'memoryUsage' | 'diskUsage') {
  return device.latest?.[key] ?? 0
}

function pressure(device: Device) {
  const values = [
    { label: 'CPU', value: metric(device, 'cpuUsage') },
    { label: '内存', value: metric(device, 'memoryUsage') },
    { label: '磁盘', value: metric(device, 'diskUsage') },
  ]
  return values.reduce((highest, current) => current.value > highest.value ? current : highest, values[0])
}

function progressTone(value: number) {
  if (value >= 90) return 'critical'
  if (value >= 75) return 'warning'
  return 'normal'
}

function serviceLabel(service: ServiceCheck) {
  return service.type === 'HTTP_GET' ? 'HTTP' : service.type === 'TCPING' ? 'TCP' : service.type === 'REDIS_PING' ? 'Redis' : service.type === 'POSTGRESQL' ? 'PostgreSQL' : service.type === 'MYSQL' ? 'MySQL' : service.type === 'HEARTBEAT' ? 'HEARTBEAT' : 'PING'
}

function uptimeSeconds(device: Device) {
  const host = device.hardware?.host
  if (!host || typeof host !== 'object') return 0
  const value = (host as Record<string, unknown>).uptimeSeconds
  return typeof value === 'number' ? value : Number(value ?? 0)
}

function scheduleRefresh() {
  window.clearTimeout(refreshTimer)
  refreshTimer = window.setTimeout(() => load(true), 350)
}

onMounted(() => {
  load()
  window.addEventListener('guanlan:realtime', scheduleRefresh)
})
watch([trendDeviceIds, trendRangeHours], loadTrend)
useVisibilityPolling(() => load(true))
onBeforeUnmount(() => {
  window.clearTimeout(refreshTimer)
  window.removeEventListener('guanlan:realtime', scheduleRefresh)
})
</script>

<template>
  <section>
    <PageHeader eyebrow="MONITORING OVERVIEW" title="运行总览" description="查看全部节点的在线状态、实时吞吐与资源负载。">
      <template #actions>
        <el-button class="button-press" :loading="refreshing" @click="load(true)"><RefreshCw :size="16" />刷新</el-button>
      </template>
    </PageHeader>

    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel">
      <EmptyState title="总览加载失败" :description="error"><el-button @click="load()">重新加载</el-button></EmptyState>
    </div>
    <template v-else-if="dashboard">
      <div class="metrics-grid stagger-grid">
        <MetricCard label="设备总数" :value="dashboard.totalDevices" :hint="`${dashboard.pendingDevices} 台等待接入`" tone="info"><template #icon><Server :size="17" /></template></MetricCard>
        <MetricCard label="在线设备" :value="dashboard.onlineDevices" :hint="`${dashboard.offlineDevices} 台离线`" :tone="dashboard.offlineDevices ? 'warning' : 'success'"><template #icon><Activity :size="17" /></template></MetricCard>
        <MetricCard label="活动告警" :value="dashboard.activeAlerts" hint="待处理与已确认" :tone="dashboard.activeAlerts ? 'danger' : 'success'"><template #icon><BellRing :size="17" /></template></MetricCard>
        <MetricCard label="实时下行" :value="rate(dashboard.networkRecvBps)" :hint="`上行 ${rate(dashboard.networkSentBps)}`" tone="neutral"><template #icon><ArrowDown :size="17" /></template></MetricCard>
        <MetricCard label="SMART 异常" :value="dashboard.smartFailures" :hint="dashboard.smartFailures ? '磁盘健康需要关注' : '未发现失败磁盘'" :tone="dashboard.smartFailures ? 'danger' : 'success'"><template #icon><ShieldCheck :size="17" /></template></MetricCard>
        <MetricCard label="完整性变更" :value="dashboard.integrityChanges" :hint="dashboard.integrityChanges ? '最近采集发现文件变化' : '未发现基线文件变化'" :tone="dashboard.integrityChanges ? 'warning' : 'success'"><template #icon><FileWarning :size="17" /></template></MetricCard>
        <MetricCard label="防火墙未启用" :value="dashboard.firewallInactive" :hint="dashboard.firewallInactive ? '请检查主机安全策略' : '已启用或暂无数据'" :tone="dashboard.firewallInactive ? 'danger' : 'success'"><template #icon><ShieldAlert :size="17" /></template></MetricCard>
      </div>

      <div class="resource-overview fade-in-up">
        <div><span><Cpu :size="15" />平均 CPU</span><strong>{{ percent(dashboard.averageCpu) }}</strong><i><b :data-level="progressTone(dashboard.averageCpu)" :style="{ width: `${Math.min(100, dashboard.averageCpu)}%` }" /></i></div>
        <div><span><MemoryStick :size="15" />平均内存</span><strong>{{ percent(dashboard.averageMemory) }}</strong><i><b :data-level="progressTone(dashboard.averageMemory)" :style="{ width: `${Math.min(100, dashboard.averageMemory)}%` }" /></i></div>
        <div><span><HardDrive :size="15" />平均磁盘</span><strong>{{ percent(dashboard.averageDisk) }}</strong><i><b :data-level="progressTone(dashboard.averageDisk)" :style="{ width: `${Math.min(100, dashboard.averageDisk)}%` }" /></i></div>
      </div>

      <section class="section">
        <div class="section-heading">
          <div><h2>资源趋势</h2><p>按节点查看历史资源和网络吞吐，帮助定位短时尖峰</p></div>
          <span v-if="trendDevice" class="filter-count">最近采集 {{ relativeTime(trendDevice.lastSeenAt) }}</span>
        </div>
        <article class="panel trend-panel">
          <div class="trend-panel-toolbar">
            <label class="trend-device-picker">监控节点（可多选）<el-select v-model="trendDeviceIds" multiple collapse-tags collapse-tags-tooltip :multiple-limit="4" placeholder="选择节点" :disabled="!trendDevices.length" aria-label="选择趋势监控节点"><el-option v-for="device in trendDevices" :key="device.id" :label="device.name" :value="device.id"><span class="trend-device-option"><strong>{{ device.name }}</strong><small>{{ device.groupName || '未分组' }} · {{ device.status === 'ONLINE' ? '在线' : '最近有数据' }}</small></span></el-option></el-select></label>
            <div class="trend-range-control"><span>时间范围</span><el-segmented v-model="trendRangeHours" :options="[{ label: '1 小时', value: 1 }, { label: '6 小时', value: 6 }, { label: '24 小时', value: 24 }]" :disabled="!trendDeviceId" aria-label="趋势时间范围" /></div>
          </div>
          <div v-if="trendError" class="trend-state trend-state-error" role="alert"><span>{{ trendError }}</span><el-button text @click="loadTrend">重试</el-button></div>
          <LoadingState v-else-if="trendLoading && !trendHistory.length" />
          <EmptyState v-else-if="!trendDevices.length" title="暂无可用节点" description="接入 Agent 并完成首次上报后，即可查看资源趋势。"><Server :size="1" /></EmptyState>
          <EmptyState v-else-if="!trendHistory.length" title="暂无趋势数据" description="所选节点在该时间范围内没有采集记录。"><el-button text @click="loadTrend">重新加载</el-button></EmptyState>
          <template v-else>
            <div class="trend-summary" aria-live="polite">
              <div><span>当前 CPU</span><strong>{{ percent(trendLatest?.cpuUsage) }}</strong></div>
              <div><span>当前内存</span><strong>{{ percent(trendLatest?.memoryUsage) }}</strong></div>
              <div><span>当前磁盘</span><strong>{{ percent(trendLatest?.diskUsage) }}</strong></div>
              <div><span>负载 1 / 5 / 15 分钟</span><strong>{{ trendLoad }}</strong></div>
              <div><span>对比节点</span><strong>{{ selectedTrendDevices.length }}</strong></div>
            </div>
            <div class="chart-grid trend-chart-grid">
              <article><div class="panel-head"><div><h3>资源使用率</h3><p>CPU、内存与最高磁盘占用</p></div><Cpu :size="16" /></div><MetricChart :labels="trendLabels" :series="trendResourceSeries" unit="%" :aria-label="`${trendDevice?.name ?? '节点'}资源使用率趋势`" /></article>
              <article><div class="panel-head"><div><h3>网络吞吐</h3><p>单位按峰值自动换算为 {{ trendIoScale.unit }}</p></div><Activity :size="16" /></div><MetricChart :labels="trendLabels" :series="trendIoSeries" :unit="trendIoScale.unit" :aria-label="`${trendDevice?.name ?? '节点'}网络吞吐趋势`" /></article>
            </div>
            <div v-if="trendLoading" class="trend-refreshing" role="status"><RefreshCw :size="13" class="spinning" />正在更新趋势数据</div>
          </template>
        </article>
      </section>

      <section class="section">
        <div class="section-heading">
          <div><h2>值班记录</h2><p>最近的设备变更、巡检与交接信息</p></div>
          <span class="filter-count"><MessageSquare :size="14" />{{ recentNotes.length }} 条记录</span>
        </div>
        <article class="panel dashboard-notes-panel">
          <div v-if="notesError" class="inline-error" role="alert"><span>{{ notesError }}</span><el-button text @click="load(true)">重试</el-button></div>
          <div v-else-if="recentNotes.length" class="dashboard-note-list">
            <button v-for="note in recentNotes" :key="note.id" type="button" @click="router.push(`/devices/${note.deviceId}`)">
              <span class="dashboard-note-icon"><MessageSquare :size="15" /></span>
              <span class="dashboard-note-main"><strong>{{ note.deviceName }}</strong><span>{{ note.content }}</span></span>
              <span class="dashboard-note-meta"><b>{{ note.author }}</b><time :datetime="note.createdAt">{{ dateTime(note.createdAt) }}</time></span>
            </button>
          </div>
          <EmptyState v-else title="暂无值班记录" description="在设备详情的“资产与记录”中添加交接或变更信息，首页会自动汇总。" />
        </article>
      </section>

      <section class="section">
        <div class="section-heading">
          <div><h2>资源压力排行</h2><p>优先查看当前资源占用最高的在线节点</p></div>
          <span class="filter-count">{{ dashboard.topDevices.length }} 个重点节点</span>
        </div>
        <article class="panel pressure-panel">
          <div v-if="dashboard.topDevices.length" class="pressure-list">
            <button v-for="(device, index) in dashboard.topDevices" :key="device.id" type="button" @click="router.push(`/devices/${device.id}`)">
              <span class="pressure-rank">{{ String(index + 1).padStart(2, '0') }}</span>
              <span class="pressure-main"><strong>{{ device.name }}</strong><small>{{ device.primaryIp || device.hostname || '主机地址待识别' }}</small></span>
              <span class="pressure-indicator" :data-level="progressTone(pressure(device).value)"><Gauge :size="14" /><b>{{ pressure(device).label }}</b><strong>{{ percent(pressure(device).value) }}</strong></span>
              <i class="pressure-bar" aria-hidden="true"><b :data-level="progressTone(pressure(device).value)" :style="{ width: `${Math.min(100, pressure(device).value)}%` }" /></i>
            </button>
          </div>
          <EmptyState v-else title="暂无资源压力数据" description="在线节点完成首次上报后，这里会列出资源占用最高的节点。" />
        </article>
      </section>

      <section class="section">
        <div class="section-heading">
          <div><h2>服务可用性</h2><p>最近探测记录与近 7 天可用率</p></div>
          <div class="section-heading-actions">
            <span v-if="!servicesError" class="filter-count"><CheckCircle2 :size="14" />{{ onlineServices }} / {{ serviceChecks.length }} 正常</span>
            <el-button text @click="router.push('/services')">查看全部</el-button>
          </div>
        </div>
        <div v-if="servicesError && serviceChecks.length" class="service-availability-notice" role="alert">
          <span>服务可用性刷新失败：{{ servicesError }}</span><el-button text :loading="servicesRefreshing" @click="loadServices">重试</el-button>
        </div>
        <div v-else-if="servicesError" class="panel state-panel">
          <EmptyState title="服务可用性加载失败" :description="servicesError"><el-button :loading="servicesRefreshing" @click="loadServices">重新加载</el-button></EmptyState>
        </div>
        <div v-else-if="serviceChecks.length" class="service-availability-grid">
          <ServiceAvailabilityCard v-for="check in serviceChecks" :key="check.id" :name="check.name" :type-label="serviceLabel(check)" :subtitle="check.target" :latest="check.latest" :history="check.history" :availability-percent="check.availabilityPercent" :latency-threshold-ms="check.latencyThresholdMs" :refresh-interval-seconds="check.intervalSeconds" />
        </div>
          <div v-else class="panel"><EmptyState title="暂无服务监控" description="添加 HTTP、Ping、TCP 或外部心跳后，这里会显示服务可用性。"><el-button text @click="router.push('/services')">前往服务监控</el-button></EmptyState></div>
      </section>

      <section class="section">
        <div class="section-heading">
          <div><h2>全部服务器</h2><p>离线与待接入节点优先展示，点击卡片查看详细指标</p></div>
          <span class="filter-count">{{ filteredDevices.length }} / {{ dashboard.devices?.length ?? 0 }} 台设备</span>
        </div>
        <div class="dashboard-filter-bar">
          <el-input v-model="search" clearable class="search-input" placeholder="搜索设备、IP、系统或位置"><template #prefix><Search :size="15" /></template></el-input>
          <el-select v-model="status" clearable placeholder="全部状态" class="compact-select">
            <el-option label="在线" value="ONLINE" /><el-option label="离线" value="OFFLINE" /><el-option label="待接入" value="PENDING" />
          </el-select>
          <el-select v-model="group" clearable placeholder="全部分组" class="compact-select">
            <el-option v-for="item in groups" :key="item" :label="item" :value="item" />
          </el-select>
          <el-select v-model="tag" clearable placeholder="全部标签" class="compact-select">
            <el-option v-for="item in tags" :key="item" :label="item" :value="item" />
          </el-select>
          <el-select v-model="sort" class="sort-select" aria-label="设备排序">
            <el-option label="异常优先" value="attention" /><el-option label="CPU 从高到低" value="cpu" />
            <el-option label="内存从高到低" value="memory" /><el-option label="磁盘从高到低" value="disk" /><el-option label="按名称" value="name" />
          </el-select>
        </div>

        <div v-if="filteredDevices.length" class="server-grid stagger-grid">
          <article v-for="device in filteredDevices" :key="device.id" class="server-card" :data-status="device.status" tabindex="0" @click="router.push(`/devices/${device.id}`)" @keydown.enter="router.push(`/devices/${device.id}`)">
            <header>
              <span class="server-icon"><Server v-if="device.status !== 'OFFLINE'" :size="18" /><WifiOff v-else :size="18" /></span>
              <span class="server-identity"><strong>{{ device.name }}</strong><small>{{ device.primaryIp || device.hostname || '等待 Agent 接入' }}</small></span>
              <StatusBadge :status="device.status" />
            </header>
            <div class="server-meta">
              <span><MapPin :size="13" />{{ device.groupName || '未分组' }} · {{ device.location || '未设置位置' }}</span>
              <span v-if="device.tags?.length" class="server-tags"><i v-for="item in device.tags" :key="item">{{ item }}</i></span>
              <span><Clock3 :size="13" />{{ device.status === 'ONLINE' ? `运行 ${uptime(uptimeSeconds(device))}` : relativeTime(device.lastSeenAt) }}</span>
              <span v-if="device.health.state !== 'HEALTHY'" class="device-health-line" :data-state="device.health.state">{{ device.health.reason }}</span>
            </div>
            <div class="server-resources">
              <div v-for="item in [
                { label: 'CPU', value: metric(device, 'cpuUsage') },
                { label: '内存', value: metric(device, 'memoryUsage') },
                { label: '磁盘', value: metric(device, 'diskUsage') },
              ]" :key="item.label">
                <span>{{ item.label }}</span><strong>{{ device.latest ? percent(item.value) : '--' }}</strong>
                <i><b :data-level="progressTone(item.value)" :style="{ width: `${device.latest ? Math.min(100, item.value) : 0}%` }" /></i>
              </div>
            </div>
            <footer>
              <span><ArrowDown :size="13" />{{ device.latest ? rate(device.latest.networkRecvBps) : '--' }}</span>
              <span><ArrowUp :size="13" />{{ device.latest ? rate(device.latest.networkSentBps) : '--' }}</span>
              <span class="server-os">{{ device.os || device.architecture || '系统待识别' }}</span>
            </footer>
          </article>
        </div>
        <div v-else class="panel"><EmptyState title="没有匹配的服务器" description="调整搜索词或筛选条件后重试。" /></div>
      </section>

      <section class="section">
        <div class="section-heading"><div><h2>最近告警</h2><p>最近触发或恢复的事件</p></div><el-button text @click="router.push('/alerts')">查看全部</el-button></div>
        <article class="panel">
          <div v-if="dashboard.recentAlerts.length" class="alert-feed">
            <button v-for="alert in dashboard.recentAlerts" :key="alert.id" type="button" @click="router.push('/alerts')">
              <span class="alert-feed-icon" :data-severity="alert.severity"><BellRing :size="16" /></span>
              <span class="alert-feed-main"><strong>{{ alert.ruleName }}</strong><small>{{ alert.deviceName }} · {{ alert.message }}</small></span>
              <StatusBadge :status="alert.status" /><time :datetime="alert.startedAt">{{ dateTime(alert.startedAt) }}</time>
            </button>
          </div>
          <EmptyState v-else title="当前没有告警" description="设备和指标均处于已配置规则的正常范围内。" />
        </article>
      </section>
    </template>
  </section>
</template>
