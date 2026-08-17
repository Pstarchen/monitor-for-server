<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import { ArrowLeft, Copy, Cpu, HardDrive, KeyRound, MemoryStick, RefreshCw, ServerCog, Waypoints } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import MetricCard from '@/components/MetricCard.vue'
import MetricChart from '@/components/MetricChart.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { bytes, dateTime, percent, rate, relativeTime } from '@/lib/format'
import { useAuthStore } from '@/stores/auth'
import type { Device, DeviceCredential, Metric } from '@/types'

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
const ioSeries = computed(() => [
  { name: '网络接收', data: history.value.map((item) => item.networkRecvBps / 1024), color: '#2867a6' },
  { name: '网络发送', data: history.value.map((item) => item.networkSentBps / 1024), color: '#17834d' },
  { name: '磁盘读取', data: history.value.map((item) => item.diskReadBps / 1024), color: '#986400' },
  { name: '磁盘写入', data: history.value.map((item) => item.diskWriteBps / 1024), color: '#c73832' },
])

function section(name: string): Record<string, unknown> {
  const value = device.value?.hardware?.[name]
  return value && typeof value === 'object' ? value as Record<string, unknown> : {}
}

function text(value: unknown, fallback = '--') {
  return value === null || value === undefined || value === '' ? fallback : String(value)
}

function uptime(value: unknown) {
  const seconds = Number(value ?? 0)
  if (!seconds) return '--'
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor(seconds % 86400 / 3600)
  return days ? `${days} 天 ${hours} 小时` : `${hours} 小时`
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
    await navigator.clipboard.writeText(credential.value.agentKey)
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
            <article class="panel"><div class="panel-head"><div><h2>磁盘与网络吞吐</h2><p>单位自动换算为 KB/s</p></div></div><MetricChart :labels="labels" :series="ioSeries" unit=" KB/s" /></article>
          </div>
          <article v-else class="panel"><EmptyState title="暂无趋势数据" description="Agent 首次上报后即可查看所选时间范围内的指标曲线。" /></article>

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
          <article class="panel"><div v-if="latest?.disks.length" class="table-wrap"><table class="data-table"><thead><tr><th>挂载点</th><th>设备</th><th>文件系统</th><th>使用率</th><th>已用 / 总量</th><th>读取</th><th>写入</th></tr></thead><tbody><tr v-for="disk in latest.disks" :key="`${disk.device}-${disk.mountpoint}`"><td><strong>{{ disk.mountpoint }}</strong></td><td>{{ disk.device }}</td><td>{{ disk.fileSystem || '--' }}</td><td>{{ percent(disk.usagePercent) }}</td><td>{{ bytes(disk.usedBytes) }} / {{ bytes(disk.totalBytes) }}</td><td>{{ rate(disk.readBytesPerSec) }}</td><td>{{ rate(disk.writeBytesPerSec) }}</td></tr></tbody></table></div><EmptyState v-else title="暂无磁盘数据" /></article>
        </el-tab-pane>

        <el-tab-pane :label="`进程 (${latest?.processes.length ?? 0})`" name="processes">
          <article class="panel"><div v-if="latest?.processes.length" class="table-wrap"><table class="data-table"><thead><tr><th>PID</th><th>进程</th><th>用户</th><th>CPU</th><th>内存</th><th>状态</th></tr></thead><tbody><tr v-for="process in latest.processes" :key="process.pid"><td class="mono-value">{{ process.pid }}</td><td><strong>{{ process.name }}</strong></td><td>{{ process.username || '--' }}</td><td>{{ percent(process.cpuPercent) }}</td><td>{{ percent(process.memoryPercent) }}</td><td>{{ process.status }}</td></tr></tbody></table></div><EmptyState v-else title="暂无进程数据" /></article>
        </el-tab-pane>

        <el-tab-pane :label="`服务 (${latest?.services.length ?? 0})`" name="services">
          <article class="panel"><div v-if="latest?.services.length" class="service-grid"><div v-for="service in latest.services" :key="service.name"><span><ServerCog :size="16" /><strong>{{ service.name }}</strong></span><StatusBadge :status="service.status" /></div></div><EmptyState v-else title="未配置服务检查" description="在 Agent 配置的 services 数组中声明需要检查的系统服务。" /></article>
        </el-tab-pane>
      </el-tabs>

      <el-dialog :model-value="Boolean(credential)" title="保存新的 Agent 密钥" width="min(580px, calc(100vw - 28px))" :close-on-click-modal="false" @update:model-value="(value: boolean) => { if (!value) credential = null }">
        <div v-if="credential" class="credential-panel"><div class="credential-warning"><KeyRound :size="18" /><p><strong>旧密钥已失效</strong><span>请立即更新目标服务器的 Agent 配置并重启服务。</span></p></div><dl><div><dt>设备 ID</dt><dd>{{ credential.device.id }}</dd></div><div><dt>Agent 密钥</dt><dd>{{ credential.agentKey }}</dd></div></dl></div>
        <template #footer><el-button @click="credential = null">我已保存</el-button><el-button type="primary" @click="copyKey"><Copy :size="16" />复制密钥</el-button></template>
      </el-dialog>
    </template>
  </section>
</template>
