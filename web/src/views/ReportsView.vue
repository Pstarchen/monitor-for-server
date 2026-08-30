<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { AlertTriangle, BarChart3, CheckCircle2, Download, RefreshCw, Server, Timer } from 'lucide-vue-next'
import { ElMessage } from 'element-plus'
import PageHeader from '@/components/PageHeader.vue'
import EmptyState from '@/components/EmptyState.vue'
import LoadingState from '@/components/LoadingState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { dateTime } from '@/lib/format'
import type { MonitorReport } from '@/types'

const rangeDays = ref(7)
const report = ref<MonitorReport | null>(null)
const loading = ref(true)
const downloading = ref(false)
const error = ref('')
const ranges = [{ label: '24 小时', value: 1 }, { label: '7 天', value: 7 }, { label: '30 天', value: 30 }]

const from = computed(() => new Date(Date.now() - rangeDays.value * 24 * 3600_000).toISOString())
const to = computed(() => new Date().toISOString())
const healthyServices = computed(() => report.value?.services.filter((service) => service.samples > 0 && service.availabilityPercent >= 99).length ?? 0)
const averageAvailability = computed(() => {
  const services = report.value?.services.filter((service) => service.samples > 0) ?? []
  return services.length ? services.reduce((sum, item) => sum + item.availabilityPercent, 0) / services.length : 0
})
const sortedDevices = computed(() => [...(report.value?.devices ?? [])].sort((a, b) => b.peakPressure - a.peakPressure))
const serviceLabels: Record<string, string> = { HTTP_GET: 'HTTP GET', ICMP_PING: 'ICMP Ping', TCPING: 'TCPing', REDIS_PING: 'Redis PING', POSTGRESQL: 'PostgreSQL', MYSQL: 'MySQL', HEARTBEAT: '外部心跳' }

async function load() {
  loading.value = true
  error.value = ''
  try {
    report.value = (await api.get<MonitorReport>('/reports/summary', { params: { from: from.value, to: to.value } })).data
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

async function download() {
  downloading.value = true
  try {
    const response = await api.get('/reports/summary.csv', { params: { from: from.value, to: to.value }, responseType: 'blob' })
    const url = URL.createObjectURL(response.data)
    const link = document.createElement('a')
    link.href = url
    link.download = `guanlan-report-${rangeDays.value}d.csv`
    link.click()
    URL.revokeObjectURL(url)
    ElMessage.success('报告已下载')
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    downloading.value = false
  }
}

function percent(value: number) { return `${Number(value || 0).toFixed(1)}%` }
function latency(value: number) { return `${Math.round(value || 0)} ms` }
function serviceLabel(value: string) { return serviceLabels[value] || value }

onMounted(load)
</script>

<template>
  <section>
    <PageHeader eyebrow="REPORTS" title="运行报告" description="以统一时间窗口汇总节点资源、服务可用率和告警活动，支持导出给值班与复盘使用。">
      <template #actions>
        <el-segmented v-model="rangeDays" :options="ranges" aria-label="报告时间范围" @change="load" />
        <el-button @click="load"><RefreshCw :size="16" />刷新</el-button>
        <el-button type="primary" :loading="downloading" :disabled="!report" @click="download"><Download :size="16" />导出 CSV</el-button>
      </template>
    </PageHeader>

    <LoadingState v-if="loading && !report" />
    <div v-else-if="error && !report" class="panel state-panel"><EmptyState title="报告加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState></div>
    <template v-else-if="report">
      <div class="report-period"><span><BarChart3 :size="14" />{{ dateTime(report.from) }} 至 {{ dateTime(report.to) }}</span><small>生成于 {{ dateTime(report.generatedAt) }}</small><span v-if="loading" class="report-refreshing"><RefreshCw :size="13" class="spinning" />更新中</span></div>
      <div class="metrics-grid report-metrics">
        <article class="metric-card"><div class="metric-card-head"><span class="metric-icon"><Server :size="17" /></span><StatusBadge status="ONLINE" /></div><strong class="metric-value">{{ report.onlineDevices }} / {{ report.totalDevices }}</strong><span class="metric-label">在线节点</span></article>
        <article class="metric-card"><div class="metric-card-head"><span class="metric-icon"><CheckCircle2 :size="17" /></span><StatusBadge :status="averageAvailability >= 99 ? 'ONLINE' : 'PENDING'" /></div><strong class="metric-value">{{ percent(averageAvailability) }}</strong><span class="metric-label">服务平均可用率</span></article>
        <article class="metric-card"><div class="metric-card-head"><span class="metric-icon"><AlertTriangle :size="17" /></span><StatusBadge :status="report.activeAlertCount ? 'CRITICAL' : 'ONLINE'" /></div><strong class="metric-value">{{ report.alertCount }}</strong><span class="metric-label">窗口内告警</span></article>
        <article class="metric-card"><div class="metric-card-head"><span class="metric-icon"><Timer :size="17" /></span><StatusBadge status="ONLINE" /></div><strong class="metric-value">{{ healthyServices }} / {{ report.services.length }}</strong><span class="metric-label">健康服务</span></article>
      </div>

      <section class="section report-section">
        <div class="section-heading"><div><h2>节点资源摘要</h2><p>按窗口内峰值压力排序，便于优先处理容量风险。</p></div><span class="filter-count">{{ report.devices.length }} 台节点 · {{ report.devices.reduce((sum, item) => sum + item.samples, 0) }} 个采集点</span></div>
        <article class="panel"><div v-if="sortedDevices.length" class="table-wrap"><table class="data-table report-table"><thead><tr><th>节点</th><th>状态</th><th>采集点</th><th>平均 CPU</th><th>平均内存</th><th>平均磁盘</th><th>峰值压力</th></tr></thead><tbody><tr v-for="device in sortedDevices" :key="device.id"><td><strong>{{ device.name }}</strong><small class="mono-value">{{ device.id }}</small></td><td><StatusBadge :status="device.status" /></td><td>{{ device.samples }}</td><td>{{ percent(device.averageCpu) }}</td><td>{{ percent(device.averageMemory) }}</td><td>{{ percent(device.averageDisk) }}</td><td><strong :class="device.peakPressure >= 90 ? 'report-danger' : device.peakPressure >= 75 ? 'report-warning' : ''">{{ percent(device.peakPressure) }}</strong></td></tr></tbody></table></div><EmptyState v-else title="窗口内暂无节点数据" description="Agent 完成采集后，报告会自动累积统计。" /></article>
      </section>

      <section class="section report-section">
        <div class="section-heading"><div><h2>服务可用率</h2><p>包含状态码、响应体条件和延迟结果的综合探测表现。</p></div><span class="filter-count">{{ report.services.length }} 项服务</span></div>
        <article class="panel"><div v-if="report.services.length" class="table-wrap"><table class="data-table report-table"><thead><tr><th>服务</th><th>类型</th><th>探测次数</th><th>可用率</th><th>平均延迟</th><th>异常次数</th></tr></thead><tbody><tr v-for="service in report.services" :key="service.id"><td><strong>{{ service.name }}</strong></td><td>{{ serviceLabel(service.type) }}</td><td>{{ service.samples }}</td><td><strong :class="service.availabilityPercent < 99 ? 'report-warning' : 'report-success'">{{ service.samples ? percent(service.availabilityPercent) : '--' }}</strong></td><td>{{ service.samples ? latency(service.averageLatencyMs) : '--' }}</td><td><strong :class="service.incidents ? 'report-danger' : ''">{{ service.incidents }}</strong></td></tr></tbody></table></div><EmptyState v-else title="暂无服务监控" description="创建 HTTP、Ping、TCP、数据库协议或心跳监控后，报告会展示服务表现。" /></article>
      </section>
    </template>
  </section>
</template>
