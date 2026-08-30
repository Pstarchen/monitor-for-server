<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import { ArrowDown, ArrowLeft, ArrowUp, BatteryCharging, Box, Copy, Cpu, Fan, FileWarning, Gauge, HardDrive, KeyRound, ListChecks, MemoryStick, Network, RefreshCw, ServerCog, ShieldAlert, ShieldCheck, Thermometer, TriangleAlert, Waypoints, Zap } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import MetricCard from '@/components/MetricCard.vue'
import MetricChart from '@/components/MetricChart.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { copyText } from '@/lib/clipboard'
import { counterRate } from '@/lib/device-analytics'
import { bytes, dateTime, percent, rate, rateScale, relativeTime } from '@/lib/format'
import { useVisibilityPolling } from '@/lib/visibility-polling'
import { useAuthStore } from '@/stores/auth'
import type { ContainerMetric, Device, DeviceCredential, Metric, ProcessMetric } from '@/types'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()
const device = ref<Device | null>(null)
const history = ref<Metric[]>([])
const loading = ref(true)
const refreshing = ref(false)
const error = ref('')
const rangeHours = ref(1)
const activeTab = ref('overview')
const credential = ref<DeviceCredential | null>(null)
const containerSelectionId = ref('')
const processSelectionKey = ref('')
let refreshTimer = 0

const deviceId = computed(() => String(route.params.id))
const latest = computed(() => device.value?.latest ?? null)
const canOperate = computed(() => auth.user?.role === 'ADMIN' || auth.user?.role === 'OPERATOR')
const labels = computed(() => history.value.map((item) => new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit', second: rangeHours.value === 1 ? '2-digit' : undefined }).format(new Date(item.collectedAt))))
const resourceSeries = computed(() => [
  { name: 'CPU', data: history.value.map((item) => item.cpuUsage), color: '#2867a6' },
  { name: '内存', data: history.value.map((item) => item.memoryUsage), color: '#17834d' },
  { name: '磁盘', data: history.value.map((item) => item.diskUsage), color: '#986400' },
])
const ioScale = computed(() => rateScale(history.value.reduce((max, item) => Math.max(max, item.networkRecvBps, item.networkSentBps, item.diskReadBps, item.diskWriteBps), 0)))
const ioSeries = computed(() => [
  { name: '网络接收', data: history.value.map((item) => item.networkRecvBps / ioScale.value.divisor), color: '#2867a6' },
  { name: '网络发送', data: history.value.map((item) => item.networkSentBps / ioScale.value.divisor), color: '#17834d' },
  { name: '磁盘读取', data: history.value.map((item) => item.diskReadBps / ioScale.value.divisor), color: '#986400' },
  { name: '磁盘写入', data: history.value.map((item) => item.diskWriteBps / ioScale.value.divisor), color: '#c73832' },
])
const temperatures = computed(() => {
  const values = section('host').temperatures
  if (!Array.isArray(values)) return []
  return values.map((value) => {
    const item = value && typeof value === 'object' ? value as Record<string, unknown> : {}
    return { sensor: text(item.sensor, '温度传感器'), value: Number(item.value ?? 0) }
  }).filter((item) => Number.isFinite(item.value))
})
const perCoreUsage = computed(() => {
  const values = section('cpu').perCorePercent
  if (!Array.isArray(values)) return []
  return values.map((value) => Number(value)).filter((value) => Number.isFinite(value))
})
const maxTemperature = computed(() => temperatures.value.reduce((max, item) => Math.max(max, item.value), 0))
const networkInterfaces = computed(() => latest.value?.networkInterfaces ?? [])
const ports = computed(() => latest.value?.ports ?? [])
const containers = computed(() => latest.value?.containers ?? [])
const containerOptions = computed(() => {
  const options = new Map<string, Pick<ContainerMetric, 'id' | 'name' | 'image'>>()
  for (const metric of history.value) {
    for (const container of metric.containers) {
      if (!options.has(container.id)) options.set(container.id, { id: container.id, name: container.name, image: container.image })
    }
  }
  return Array.from(options.values()).sort((left, right) => (left.name || left.id).localeCompare(right.name || right.id, 'zh-CN'))
})
const selectedContainerId = computed({
  get: () => containerOptions.value.some((item) => item.id === containerSelectionId.value) ? containerSelectionId.value : containerOptions.value[0]?.id ?? '',
  set: (value: string) => { containerSelectionId.value = value },
})
const selectedContainer = computed(() => containers.value.find((item) => item.id === selectedContainerId.value) ?? null)
const containerTrendPoints = computed(() => history.value.flatMap((metric) => {
  const container = metric.containers.find((item) => item.id === selectedContainerId.value)
  return container ? [{ collectedAt: metric.collectedAt, container }] : []
}))
const containerTrendLabels = computed(() => containerTrendPoints.value.map((item) => trendLabel(item.collectedAt)))
const containerResourceSeries = computed(() => [
  { name: 'CPU', data: containerTrendPoints.value.map((item) => item.container.cpuPercent), color: '#2867a6' },
  { name: '内存', data: containerTrendPoints.value.map((item) => item.container.memoryPercent), color: '#17834d' },
])
const containerNetworkRates = computed(() => containerTrendPoints.value.map((point, index) => {
  if (index === 0) return { rx: 0, tx: 0 }
  const previous = containerTrendPoints.value[index - 1]
  const seconds = (new Date(point.collectedAt).getTime() - new Date(previous.collectedAt).getTime()) / 1000
  return {
    rx: counterRate(point.container.networkRxBytes, previous.container.networkRxBytes, seconds),
    tx: counterRate(point.container.networkTxBytes, previous.container.networkTxBytes, seconds),
  }
}))
const containerNetworkScale = computed(() => rateScale(containerNetworkRates.value.reduce((max, item) => Math.max(max, item.rx, item.tx), 0)))
const containerNetworkSeries = computed(() => [
  { name: '网络接收', data: containerNetworkRates.value.map((item) => item.rx / containerNetworkScale.value.divisor), color: '#2867a6' },
  { name: '网络发送', data: containerNetworkRates.value.map((item) => item.tx / containerNetworkScale.value.divisor), color: '#17834d' },
])
const processOptions = computed(() => {
  const options = new Map<string, ProcessMetric>()
  for (const metric of history.value) {
    for (const process of metric.processes) {
      const key = processKey(process)
      if (!options.has(key)) options.set(key, process)
    }
  }
  return Array.from(options.values()).sort((left, right) => (left.name || '').localeCompare(right.name || '', 'zh-CN') || left.pid - right.pid)
})
const selectedProcessKey = computed({
  get: () => processOptions.value.some((item) => processKey(item) === processSelectionKey.value) ? processSelectionKey.value : processOptions.value[0] ? processKey(processOptions.value[0]) : '',
  set: (value: string) => { processSelectionKey.value = value },
})
const selectedProcess = computed(() => processOptions.value.find((item) => processKey(item) === selectedProcessKey.value) ?? null)
const processTrendPoints = computed(() => history.value.flatMap((metric) => {
  const process = metric.processes.find((item) => processKey(item) === selectedProcessKey.value)
  return process ? [{ collectedAt: metric.collectedAt, process }] : []
}))
const processTrendLabels = computed(() => processTrendPoints.value.map((item) => trendLabel(item.collectedAt)))
const processSeries = computed(() => [
  { name: 'CPU', data: processTrendPoints.value.map((item) => item.process.cpuPercent), color: '#986400' },
  { name: '内存', data: processTrendPoints.value.map((item) => item.process.memoryPercent), color: '#c73832' },
])
const fans = computed(() => latest.value?.fans ?? [])
const batteries = computed(() => latest.value?.batteries ?? [])
const gpus = computed(() => latest.value?.gpus ?? [])
const firewall = computed(() => latest.value?.firewall ?? null)
const cronJobs = computed(() => latest.value?.cronJobs ?? [])
const logs = computed(() => latest.value?.logs ?? [])
const integrity = computed(() => latest.value?.integrity ?? [])
const smartSummary = computed(() => ({
  passed: latest.value?.smartPassed ?? 0,
  failed: latest.value?.smartFailed ?? 0,
  unknown: latest.value?.smartUnknown ?? 0,
}))

function smartTone(status: string | undefined) {
  return status === 'FAILED' ? 'critical' : status === 'PASSED' ? 'normal' : 'warning'
}

function smartLabel(status: string | undefined) {
  return status === 'FAILED' ? '异常' : status === 'PASSED' ? '通过' : '未知'
}

function firewallTone(state: string | undefined) {
  return state === 'ACTIVE' ? 'normal' : state === 'INACTIVE' ? 'critical' : 'warning'
}

function firewallLabel(state: string | undefined) {
  return state === 'ACTIVE' ? '已启用' : state === 'INACTIVE' ? '未启用' : '未知'
}

function section(name: string): Record<string, unknown> {
  const value = device.value?.hardware?.[name]
  return value && typeof value === 'object' ? value as Record<string, unknown> : {}
}

function text(value: unknown, fallback = '--') {
  return value === null || value === undefined || value === '' ? fallback : String(value)
}

function trendLabel(value: string) {
  return new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit', second: rangeHours.value === 1 ? '2-digit' : undefined }).format(new Date(value))
}

function processKey(process: Pick<ProcessMetric, 'pid' | 'name'>) {
  return `${process.pid}:${process.name}`
}

function uptime(value: unknown) {
  const seconds = Number(value ?? 0)
  if (!seconds) return '--'
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor(seconds % 86400 / 3600)
  return days ? `${days} 天 ${hours} 小时` : `${hours} 小时`
}

function temperatureTone(value: number) {
  if (value >= 85) return 'critical'
  if (value >= 70) return 'warning'
  return 'normal'
}

async function load(background = false) {
  if (background) refreshing.value = true
  else loading.value = true
  error.value = ''
  const to = new Date()
  const from = new Date(to.getTime() - rangeHours.value * 3600_000)
  try {
    const [deviceResponse, historyResponse] = await Promise.all([
      api.get<Device>(`/devices/${deviceId.value}`),
      api.get<Metric[]>(`/devices/${deviceId.value}/metrics/history`, { params: { from: from.toISOString(), to: to.toISOString() } }),
    ])
    device.value = deviceResponse.data
    history.value = historyResponse.data
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
    refreshing.value = false
  }
}

async function rotateKey() {
  if (!device.value) return
  try {
    await ElMessageBox.confirm('轮换后当前 Agent 密钥会立即失效，请准备同步更新目标服务器配置。', '轮换 Agent 密钥', { type: 'warning', confirmButtonText: '确认轮换', cancelButtonText: '取消' })
    credential.value = (await api.post<DeviceCredential>(`/devices/${deviceId.value}/rotate-key`)).data
    await load(true)
  } catch (cause) {
    if (cause !== 'cancel' && cause !== 'close') ElMessage.error(errorMessage(cause))
  }
}

async function copyKey() {
  if (!credential.value) return
  try {
    await copyText(credential.value.agentKey)
    ElMessage.success('密钥已复制')
  } catch {
    ElMessage.error('复制失败，请手动选择密钥')
  }
}

function onRealtime(event: Event) {
  const detail = (event as CustomEvent<{ payload?: { deviceId?: string } }>).detail
  if (detail?.payload?.deviceId !== deviceId.value) return
  window.clearTimeout(refreshTimer)
  refreshTimer = window.setTimeout(() => load(true), 350)
}

onMounted(() => {
  load()
  window.addEventListener('guanlan:realtime', onRealtime)
})
useVisibilityPolling(() => load(true))
onBeforeUnmount(() => {
  window.clearTimeout(refreshTimer)
  window.removeEventListener('guanlan:realtime', onRealtime)
})
</script>

<template>
  <section>
    <button class="back-link" type="button" @click="router.push('/devices')"><ArrowLeft :size="16" />返回设备列表</button>
    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel"><EmptyState title="设备详情加载失败" :description="error"><el-button @click="load()">重新加载</el-button></EmptyState></div>
    <template v-else-if="device">
      <PageHeader eyebrow="DEVICE INSPECTION" :title="device.name" :description="`${device.hostname || '等待主机信息'} · ${device.primaryIp || '未设置主 IP'} · ${relativeTime(device.lastSeenAt)}`">
        <template #actions>
          <StatusBadge :status="device.status" />
          <el-button :loading="refreshing" @click="load(true)"><RefreshCw :size="16" />刷新</el-button>
          <el-button v-if="auth.user?.role === 'ADMIN'" @click="rotateKey"><KeyRound :size="16" />轮换密钥</el-button>
        </template>
      </PageHeader>

      <div class="metrics-grid stagger-grid">
        <MetricCard label="CPU 使用率" :value="latest ? percent(latest.cpuUsage) : '--'" :hint="latest ? `负载 ${latest.load1.toFixed(2)} / ${latest.load5.toFixed(2)} / ${latest.load15.toFixed(2)}` : '暂无数据'" :tone="(latest?.cpuUsage ?? 0) >= 80 ? 'danger' : 'info'"><template #icon><Cpu :size="17" /></template></MetricCard>
        <MetricCard label="内存使用率" :value="latest ? percent(latest.memoryUsage) : '--'" :hint="latest ? `交换分区 ${percent(latest.swapUsage)}` : '暂无数据'" :tone="(latest?.memoryUsage ?? 0) >= 80 ? 'danger' : 'success'"><template #icon><MemoryStick :size="17" /></template></MetricCard>
        <MetricCard label="最高磁盘占用" :value="latest ? percent(latest.diskUsage) : '--'" :hint="latest ? `${latest.disks.length} 个挂载点` : '暂无数据'" :tone="(latest?.diskUsage ?? 0) >= 85 ? 'danger' : 'warning'"><template #icon><HardDrive :size="17" /></template></MetricCard>
        <MetricCard label="TCP 连接" :value="latest?.tcpConnections ?? '--'" :hint="latest ? `收 ${rate(latest.networkRecvBps)} · 发 ${rate(latest.networkSentBps)}` : '暂无数据'" tone="neutral"><template #icon><Waypoints :size="17" /></template></MetricCard>
      </div>

      <el-tabs v-model="activeTab" class="detail-tabs">
        <el-tab-pane label="趋势与主机" name="overview">
          <div class="trend-toolbar"><span>趋势时间范围</span><el-segmented v-model="rangeHours" :options="[{ label: '1 小时', value: 1 }, { label: '6 小时', value: 6 }, { label: '24 小时', value: 24 }]" @change="load(true)" /></div>
          <div v-if="history.length" class="chart-grid">
            <article class="panel"><div class="panel-head"><div><h2>资源使用率</h2><p>CPU、内存与最高磁盘占用</p></div></div><MetricChart :labels="labels" :series="resourceSeries" unit="%" /></article>
            <article class="panel"><div class="panel-head"><div><h2>磁盘与网络吞吐</h2><p>单位按峰值自动换算为 {{ ioScale.unit }}</p></div></div><MetricChart :labels="labels" :series="ioSeries" :unit="ioScale.unit" /></article>
          </div>
          <article v-else class="panel"><EmptyState title="暂无趋势数据" description="Agent 首次上报后即可查看所选时间范围内的指标曲线。" /></article>

          <article class="panel host-health-panel">
            <div class="panel-head"><div><h2>主机健康</h2><p>温度、SMART、每核负载与交换分区状态</p></div><Gauge :size="17" /></div>
            <div class="host-health-grid">
              <div><span><Thermometer :size="14" />最高温度</span><strong :data-level="temperatureTone(maxTemperature)">{{ temperatures.length ? `${maxTemperature.toFixed(1)} °C` : '--' }}</strong><small>{{ temperatures.length ? `${temperatures.length} 个传感器` : 'Agent 未返回温度传感器' }}</small></div>
              <div><span><Cpu :size="14" />每核 CPU 峰值</span><strong>{{ perCoreUsage.length ? percent(Math.max(...perCoreUsage)) : '--' }}</strong><small>{{ perCoreUsage.length ? `${perCoreUsage.length} 个逻辑核心` : '暂无每核数据' }}</small></div>
              <div><span><MemoryStick :size="14" />交换分区</span><strong>{{ latest ? percent(latest.swapUsage) : '--' }}</strong><small>{{ latest?.swapUsage && latest.swapUsage >= 80 ? '使用率偏高' : '当前使用情况' }}</small></div>
              <div><span><Waypoints :size="14" />TCP 连接</span><strong>{{ latest?.tcpConnections ?? '--' }}</strong><small>最近一次采集</small></div>
              <div><span><Fan :size="14" />风扇转速</span><strong>{{ fans.length ? `${Math.round(Math.max(...fans.map((fan) => fan.rpm)))} RPM` : '--' }}</strong><small>{{ fans.length ? `${fans.length} 个风扇` : '未检测到风扇传感器' }}</small></div>
              <div><span><BatteryCharging :size="14" />电池电量</span><strong>{{ latest?.batteryPercent == null ? '--' : percent(latest.batteryPercent) }}</strong><small>{{ batteries.length ? batteries.map((battery) => battery.status || '未知').join(' · ') : '未检测到电池' }}</small></div>
              <div><span><Zap :size="14" />GPU 使用率</span><strong>{{ latest?.gpuUsage == null ? '--' : percent(latest.gpuUsage) }}</strong><small>{{ gpus.length ? `${gpus.length} 个 GPU` : '未检测到 NVIDIA GPU' }}</small></div>
              <div><span><ShieldCheck :size="14" />磁盘 SMART</span><strong :data-level="smartSummary.failed ? 'critical' : smartSummary.unknown ? 'warning' : 'normal'">{{ smartSummary.failed ? `${smartSummary.failed} 个异常` : smartSummary.passed ? `${smartSummary.passed} 个通过` : '--' }}</strong><small>{{ smartSummary.unknown ? `${smartSummary.unknown} 个未知` : '健康自检状态' }}</small></div>
            </div>
            <div v-if="temperatures.length" class="temperature-list"><span v-for="item in temperatures" :key="item.sensor" :data-level="temperatureTone(item.value)"><Thermometer :size="12" />{{ item.sensor }} {{ item.value.toFixed(1) }} °C</span></div>
            <div v-if="perCoreUsage.length" class="core-usage-list" aria-label="每核 CPU 使用率"><span v-for="(value, index) in perCoreUsage" :key="index" :title="`核心 ${index + 1}: ${percent(value)}`"><i><b :data-level="temperatureTone(value)" :style="{ height: `${Math.min(100, value)}%` }" /></i><small>{{ index + 1 }}</small></span></div>
            <div v-if="fans.length || batteries.length || gpus.length" class="hardware-health-list">
              <span v-for="fan in fans" :key="`fan-${fan.name}`"><Fan :size="12" />{{ fan.name }} {{ Math.round(fan.rpm) }} RPM</span>
              <span v-for="battery in batteries" :key="`battery-${battery.name}`"><BatteryCharging :size="12" />{{ battery.name }} {{ percent(battery.percent) }}</span>
              <span v-for="gpu in gpus" :key="`gpu-${gpu.index}`"><Zap :size="12" />{{ gpu.name || `GPU ${gpu.index}` }} {{ percent(gpu.usagePercent) }}<small v-if="gpu.temperature">{{ gpu.temperature.toFixed(0) }} °C</small></span>
            </div>
          </article>

          <div class="section two-column detail-summary-grid">
            <article class="panel detail-list">
              <div class="panel-head"><div><h2>主机信息</h2><p>最近一次 Agent 上报</p></div><ServerCog :size="17" /></div>
              <dl>
                <div><dt>操作系统</dt><dd>{{ device.os || '--' }}</dd></div>
                <div><dt>架构</dt><dd>{{ device.architecture || '--' }}</dd></div>
                <div><dt>内核版本</dt><dd>{{ text(section('host').kernelVersion) }}</dd></div>
                <div><dt>运行时长</dt><dd>{{ uptime(section('host').uptimeSeconds) }}</dd></div>
                <div><dt>CPU 型号</dt><dd>{{ text(section('cpu').model) }}</dd></div>
                <div><dt>CPU 核心</dt><dd>{{ text(section('cpu').physicalCores) }} 物理 / {{ text(section('cpu').logicalCores) }} 逻辑</dd></div>
                <div><dt>总内存</dt><dd>{{ bytes(Number(section('memory').totalBytes ?? 0)) }}</dd></div>
                <div><dt>采集时间</dt><dd>{{ dateTime(latest?.collectedAt) }}</dd></div>
              </dl>
            </article>
            <article class="panel detail-list">
              <div class="panel-head"><div><h2>接入信息</h2><p>管理数据归属与凭据标识</p></div><KeyRound :size="17" /></div>
              <dl>
                <div><dt>设备 ID</dt><dd class="mono-value">{{ device.id }}</dd></div>
                <div><dt>密钥前缀</dt><dd class="mono-value">{{ device.agentKeyPrefix }}…</dd></div>
                <div><dt>设备分组</dt><dd>{{ device.groupName || '未分组' }}</dd></div>
                <div><dt>物理位置</dt><dd>{{ device.location || '未设置' }}</dd></div>
                <div><dt>登记时间</dt><dd>{{ dateTime(device.createdAt) }}</dd></div>
                <div><dt>操作权限</dt><dd>{{ canOperate ? '可管理设备' : '仅查看' }}</dd></div>
              </dl>
            </article>
          </div>
        </el-tab-pane>

        <el-tab-pane :label="`磁盘 (${latest?.disks.length ?? 0})`" name="disks">
          <article class="panel"><div v-if="latest?.disks.length" class="table-wrap"><table class="data-table"><thead><tr><th>挂载点</th><th>设备</th><th>文件系统</th><th>使用率</th><th>已用 / 总量</th><th>读取</th><th>写入</th><th>SMART</th></tr></thead><tbody><tr v-for="disk in latest.disks" :key="`${disk.device}-${disk.mountpoint}`"><td><strong>{{ disk.mountpoint }}</strong></td><td>{{ disk.device }}</td><td>{{ disk.fileSystem || '--' }}</td><td>{{ percent(disk.usagePercent) }}</td><td>{{ bytes(disk.usedBytes) }} / {{ bytes(disk.totalBytes) }}</td><td>{{ rate(disk.readBytesPerSec) }}</td><td>{{ rate(disk.writeBytesPerSec) }}</td><td><span v-if="disk.smart" class="smart-status" :data-level="smartTone(disk.smart.status)" :title="disk.smart.message"><TriangleAlert v-if="disk.smart.status === 'FAILED'" :size="13" /><ShieldCheck v-else :size="13" />{{ smartLabel(disk.smart.status) }}<small v-if="disk.smart.temperature">{{ disk.smart.temperature }} °C</small></span><span v-else class="muted-value">未采集</span></td></tr></tbody></table></div><EmptyState v-else title="暂无磁盘数据" /></article>
        </el-tab-pane>

        <el-tab-pane :label="`进程 (${latest?.processes.length ?? 0})`" name="processes">
          <div v-if="processOptions.length" class="analytics-toolbar">
            <label><span>历史进程</span><el-select v-model="selectedProcessKey" filterable aria-label="选择历史进程"><el-option v-for="process in processOptions" :key="processKey(process)" :label="`${process.name || '未命名'} · PID ${process.pid}`" :value="processKey(process)"><span class="analytics-option"><strong>{{ process.name || '未命名进程' }}</strong><small>PID {{ process.pid }}{{ process.username ? ` · ${process.username}` : '' }}</small></span></el-option></el-select></label>
            <span v-if="selectedProcess" class="analytics-selection">最近 CPU {{ percent(selectedProcess.cpuPercent) }} · 内存 {{ percent(selectedProcess.memoryPercent) }}</span>
          </div>
          <div v-if="processTrendPoints.length > 1" class="chart-grid analytics-chart-grid">
            <article class="panel"><div class="panel-head"><div><h2>进程资源趋势</h2><p>{{ selectedProcess?.name || '所选进程' }} · PID {{ selectedProcess?.pid ?? '--' }}</p></div><Cpu :size="17" /></div><MetricChart :labels="processTrendLabels" :series="processSeries" unit="%" :aria-label="`${selectedProcess?.name || '进程'}资源趋势`" /></article>
          </div>
          <div v-else-if="processOptions.length" class="panel analytics-empty"><EmptyState title="暂无进程历史数据" description="该进程在当前时间范围内只有一个采集点，继续采集后会显示趋势。" /></div>
          <article class="panel"><div v-if="latest?.processes.length" class="table-wrap"><table class="data-table"><thead><tr><th>PID</th><th>进程</th><th>命令行</th><th>用户</th><th>CPU</th><th>内存</th><th>状态</th></tr></thead><tbody><tr v-for="process in latest.processes" :key="process.pid"><td class="mono-value">{{ process.pid }}</td><td><strong>{{ process.name }}</strong></td><td class="mono-value process-command" :title="process.commandLine || undefined">{{ process.commandLine || '--' }}</td><td>{{ process.username || '--' }}</td><td>{{ percent(process.cpuPercent) }}</td><td>{{ percent(process.memoryPercent) }}</td><td>{{ process.status }}</td></tr></tbody></table></div><EmptyState v-else title="暂无进程数据" description="默认保留 CPU 排名前 12 的进程；需要完整清单时，在 Agent 配置启用 collect_all_processes。" /></article>
        </el-tab-pane>

        <el-tab-pane :label="`服务 (${latest?.services.length ?? 0})`" name="services">
          <article class="panel"><div v-if="latest?.services.length" class="service-grid"><div v-for="service in latest.services" :key="service.name"><span><ServerCog :size="16" /><strong>{{ service.name }}</strong></span><StatusBadge :status="service.status" /></div></div><EmptyState v-else title="未配置服务检查" description="在 Agent 配置的 services 数组中声明需要检查的系统服务。" /></article>
        </el-tab-pane>

        <el-tab-pane :label="`端口 (${ports.length})`" name="ports">
          <article class="panel"><div v-if="ports.length" class="table-wrap"><table class="data-table"><thead><tr><th>协议</th><th>监听地址</th><th>端口</th><th>进程 PID</th></tr></thead><tbody><tr v-for="port in ports" :key="`${port.protocol}-${port.address}-${port.port}-${port.pid}`"><td><StatusBadge :status="port.protocol === 'TCP' ? 'ONLINE' : 'INFO'" /></td><td class="mono-value">{{ port.address }}</td><td><strong class="mono-value">{{ port.port }}</strong></td><td class="mono-value">{{ port.pid || '--' }}</td></tr></tbody></table></div><EmptyState v-else title="暂无监听端口" description="Agent 未返回监听端口，或已在轻量采集配置中跳过连接枚举。" /></article>
        </el-tab-pane>

        <el-tab-pane :label="`容器 (${containers.length})`" name="containers">
          <div v-if="containerOptions.length" class="analytics-toolbar">
            <label><span>历史容器</span><el-select v-model="selectedContainerId" filterable aria-label="选择历史容器"><el-option v-for="container in containerOptions" :key="container.id" :label="container.name || container.id.slice(0, 12)" :value="container.id"><span class="analytics-option"><strong>{{ container.name || '未命名容器' }}</strong><small>{{ container.image || container.id.slice(0, 12) }}</small></span></el-option></el-select></label>
            <span v-if="selectedContainer" class="analytics-selection">当前 CPU {{ percent(selectedContainer.cpuPercent) }} · 内存 {{ percent(selectedContainer.memoryPercent) }}</span>
          </div>
          <div v-if="containerTrendPoints.length > 1" class="chart-grid analytics-chart-grid">
            <article class="panel"><div class="panel-head"><div><h2>容器资源趋势</h2><p>{{ selectedContainer?.name || '所选容器' }} · CPU 与内存使用率</p></div><Box :size="17" /></div><MetricChart :labels="containerTrendLabels" :series="containerResourceSeries" unit="%" :aria-label="`${selectedContainer?.name || '容器'}资源趋势`" /></article>
            <article class="panel"><div class="panel-head"><div><h2>容器网络吞吐</h2><p>按相邻采集点计算，计数器重置会自动归零 · {{ containerNetworkScale.unit }}</p></div><Network :size="17" /></div><MetricChart :labels="containerTrendLabels" :series="containerNetworkSeries" :unit="containerNetworkScale.unit" :aria-label="`${selectedContainer?.name || '容器'}网络吞吐趋势`" /></article>
          </div>
          <div v-else-if="containerOptions.length" class="panel analytics-empty"><EmptyState title="暂无容器历史数据" description="该容器在当前时间范围内只有一个采集点，继续采集后会显示趋势。" /></div>
          <article class="panel"><div class="panel-head"><div><h2>Docker 容器</h2><p>运行状态、资源占用与累计网络流量</p></div><Box :size="17" /></div><div v-if="containers.length" class="table-wrap"><table class="data-table"><thead><tr><th>容器</th><th>镜像</th><th>状态</th><th>CPU</th><th>内存</th><th>网络</th><th>重启</th></tr></thead><tbody><tr v-for="container in containers" :key="container.id"><td><strong>{{ container.name }}</strong><small class="mono-value">{{ container.id.slice(0, 12) }}</small></td><td class="mono-value container-image">{{ container.image || '--' }}</td><td><StatusBadge :status="container.state === 'running' ? 'ONLINE' : 'OFFLINE'" /><small>{{ container.status || '--' }}</small></td><td>{{ percent(container.cpuPercent) }}</td><td>{{ percent(container.memoryPercent) }}<small>{{ bytes(container.memoryUsageBytes) }} / {{ bytes(container.memoryLimitBytes) }}</small></td><td><span class="container-network"><ArrowUp :size="12" />{{ bytes(container.networkTxBytes) }}</span><span class="container-network"><ArrowDown :size="12" />{{ bytes(container.networkRxBytes) }}</span></td><td>{{ container.restartCount }}</td></tr></tbody></table></div><EmptyState v-else title="暂无 Docker 容器" description="Agent 未检测到可访问的 Docker socket；主机监控、服务检查与其他指标不受影响。" /></article>
        </el-tab-pane>

        <el-tab-pane :label="`网卡 (${networkInterfaces.length})`" name="network">
          <article class="panel"><div class="panel-head"><div><h2>网络接口</h2><p>接口地址、链路状态与 MTU</p></div><Network :size="17" /></div><div v-if="networkInterfaces.length" class="table-wrap"><table class="data-table"><thead><tr><th>接口</th><th>地址</th><th>MAC</th><th>MTU</th><th>状态</th></tr></thead><tbody><tr v-for="item in networkInterfaces" :key="item.name"><td><strong>{{ item.name }}</strong></td><td><span v-if="item.addresses.length" class="interface-addresses">{{ item.addresses.join('、') }}</span><span v-else>--</span></td><td class="mono-value">{{ item.hardwareAddr || '--' }}</td><td>{{ item.mtu || '--' }}</td><td><StatusBadge :status="item.flags.includes('up') ? 'ONLINE' : 'OFFLINE'" /></td></tr></tbody></table></div><EmptyState v-else title="暂无网卡数据" description="Agent 首次上报后会展示接口地址、MAC 和链路状态。" /></article>
        </el-tab-pane>

        <el-tab-pane :label="`安全巡检 (${cronJobs.length + logs.length + integrity.length})`" name="security">
          <div class="security-inspection-grid">
            <article class="panel security-status-panel">
              <div class="panel-head"><div><h2>防火墙状态</h2><p>Agent 自动识别主机上的防火墙服务</p></div><ShieldAlert :size="17" /></div>
              <div v-if="firewall" class="security-status-value" :data-level="firewallTone(firewall.state)"><span><ShieldCheck :size="18" />{{ firewallLabel(firewall.state) }}</span><strong>{{ firewall.provider || '未知提供方' }}</strong><small>{{ firewall.message || '最近一次采集结果' }}</small></div>
              <EmptyState v-else title="暂无防火墙数据" description="Agent 尚未完成安全巡检。" />
            </article>
            <article class="panel security-status-panel">
              <div class="panel-head"><div><h2>完整性基线</h2><p>仅统计已配置路径中发生变化的文件</p></div><FileWarning :size="17" /></div>
              <div class="security-status-value" :data-level="(latest?.integrityChanges ?? 0) ? 'critical' : 'normal'"><span><FileWarning :size="18" />{{ latest?.integrityChanges ?? 0 }} 个变更</span><strong>{{ integrity.length ? `${integrity.length} 个文件` : '未配置路径' }}</strong><small>{{ integrity.length ? '当前快照已建立' : '通过 --integrity-path 开启' }}</small></div>
            </article>
          </div>
          <article class="panel security-list-panel">
            <div class="panel-head"><div><h2>计划任务</h2><p>Linux Crontab 或 Windows Task Scheduler 摘要</p></div><ListChecks :size="17" /></div>
            <div v-if="cronJobs.length" class="table-wrap"><table class="data-table"><thead><tr><th>来源</th><th>用户</th><th>计划</th><th>命令</th></tr></thead><tbody><tr v-for="job in cronJobs" :key="`${job.source}-${job.user}-${job.schedule}-${job.command}`"><td class="mono-value">{{ job.source }}</td><td>{{ job.user || '--' }}</td><td>{{ job.schedule }}</td><td class="mono-value security-command">{{ job.command }}</td></tr></tbody></table></div><EmptyState v-else title="暂无计划任务" description="未发现可读取的系统计划任务，或 Agent 没有足够权限。" />
          </article>
          <article class="panel security-list-panel">
            <div class="panel-head"><div><h2>日志尾部</h2><p>仅显示配置白名单文件的最后 20 行</p></div><FileWarning :size="17" /></div>
            <div v-if="logs.length" class="security-log-list"><div v-for="log in logs" :key="log.path" class="security-log-item"><header><strong class="mono-value">{{ log.path }}</strong><span>{{ bytes(log.sizeBytes) }} · {{ dateTime(log.modifiedAt) }}</span></header><pre><code v-for="(line, index) in log.lines" :key="index">{{ line }}{{ index < log.lines.length - 1 ? '\n' : '' }}</code></pre></div></div><EmptyState v-else title="未配置日志采集" description="出于隐私和性能考虑，日志默认不读取。通过 --log-path 指定需要巡检的文件。" />
          </article>
          <article class="panel security-list-panel">
            <div class="panel-head"><div><h2>完整性文件</h2><p>SHA-256、大小和修改时间</p></div><ShieldCheck :size="17" /></div>
            <div v-if="integrity.length" class="table-wrap"><table class="data-table"><thead><tr><th>路径</th><th>SHA-256</th><th>大小</th><th>修改时间</th></tr></thead><tbody><tr v-for="item in integrity" :key="item.path"><td class="mono-value">{{ item.path }}</td><td class="mono-value security-hash">{{ item.sha256 }}</td><td>{{ bytes(item.sizeBytes) }}</td><td>{{ dateTime(item.modifiedAt) }}</td></tr></tbody></table></div><EmptyState v-else title="未配置完整性路径" description="通过 --integrity-path 指定文件或目录后，Agent 会建立基线并检测后续变更。" />
          </article>
        </el-tab-pane>
      </el-tabs>

      <el-dialog :model-value="Boolean(credential)" title="保存新的 Agent 密钥" width="min(580px, calc(100vw - 28px))" :close-on-click-modal="false" @update:model-value="(value: boolean) => { if (!value) credential = null }">
        <div v-if="credential" class="credential-panel"><div class="credential-warning"><KeyRound :size="18" /><p><strong>旧密钥已失效</strong><span>请立即更新目标服务器的 Agent 配置并重启服务。</span></p></div><dl><div><dt>设备 ID</dt><dd>{{ credential.device.id }}</dd></div><div><dt>Agent 密钥</dt><dd>{{ credential.agentKey }}</dd></div></dl></div>
        <template #footer><el-button @click="credential = null">我已保存</el-button><el-button type="primary" @click="copyKey"><Copy :size="16" />复制密钥</el-button></template>
      </el-dialog>
    </template>
  </section>
</template>
