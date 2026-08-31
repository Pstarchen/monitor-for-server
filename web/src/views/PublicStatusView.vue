<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { Activity, ArrowDown, ArrowUp, CheckCircle2, Clock3, Gauge, Github, LogIn, Moon, RefreshCw, Server, Sun, WifiOff } from 'lucide-vue-next'
import ServiceAvailabilityCard from '@/components/ServiceAvailabilityCard.vue'
import BrandMark from '@/components/BrandMark.vue'
import { api, errorMessage } from '@/lib/api'
import { bytes, percent, rate, relativeTime, uptime } from '@/lib/format'
import { loadBranding, siteName } from '@/lib/branding'
import type { PublicDevice, PublicOverview, PublicServiceCheck } from '@/types'

type SortKey = 'default' | 'name' | 'os' | 'uptime' | 'cpu' | 'memory' | 'disk' | 'up' | 'down' | 'totalUp' | 'totalDown'
const overview = ref<PublicOverview | null>(null)
const loading = ref(true)
const error = ref('')
const sort = ref<SortKey>('default')
const search = ref('')
const dark = ref(localStorage.getItem('guanlan-theme') === 'dark')
const githubUrl = 'https://github.com/Pstarchen/monitor-for-server'
let timer = 0
let pollTimer = 0

const sortedDevices = computed(() => {
  const needle = search.value.trim().toLowerCase()
  const devices = [...(overview.value?.devices ?? [])].filter((device) => !needle || [device.name, device.groupName, device.os].some((value) => value?.toLowerCase().includes(needle)))
  const statusRank = (value: PublicDevice['status']) => value === 'ONLINE' ? 0 : value === 'PENDING' ? 1 : 2
  return devices.sort((left, right) => {
    if (sort.value === 'name') return left.name.localeCompare(right.name, 'zh-CN')
    if (sort.value === 'os') return (left.os || '').localeCompare(right.os || '', 'zh-CN')
    if (sort.value === 'uptime') return right.uptimeSeconds - left.uptimeSeconds
    if (sort.value === 'cpu') return right.cpuUsage - left.cpuUsage
    if (sort.value === 'memory') return right.memoryUsage - left.memoryUsage
    if (sort.value === 'disk') return right.diskUsage - left.diskUsage
    if (sort.value === 'up') return right.networkSentBps - left.networkSentBps
    if (sort.value === 'down') return right.networkRecvBps - left.networkRecvBps
    if (sort.value === 'totalUp') return right.networkSentBytes - left.networkSentBytes
    if (sort.value === 'totalDown') return right.networkRecvBytes - left.networkRecvBytes
    return statusRank(left.status) - statusRank(right.status) || left.name.localeCompare(right.name, 'zh-CN')
  })
})

const onlineServices = computed(() => (overview.value?.services ?? []).filter((service) => service.latest?.success).length)

function applyTheme() {
  document.documentElement.classList.toggle('dark', dark.value)
  localStorage.setItem('guanlan-theme', dark.value ? 'dark' : 'light')
}

function toggleTheme() {
  dark.value = !dark.value
  applyTheme()
}

async function load() {
  error.value = ''
  try {
    overview.value = (await api.get<PublicOverview>('/public/overview')).data
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

function scheduleRefresh() {
  window.clearTimeout(timer)
  timer = window.setTimeout(load, 500)
}

function poll() {
  if (document.visibilityState === 'visible') void load()
}

function handleVisibilityChange() {
  if (document.visibilityState === 'visible') void load()
}

function serviceLabel(service: PublicServiceCheck) {
  return service.type === 'HTTP_GET' ? 'HTTP' : service.type === 'TCPING' ? 'TCP' : service.type === 'REDIS_PING' ? 'Redis' : service.type === 'POSTGRESQL' ? 'PostgreSQL' : service.type === 'MYSQL' ? 'MySQL' : service.type === 'HEARTBEAT' ? 'HEARTBEAT' : 'PING'
}

function metricValue(value: number | null | undefined) {
  const numeric = Number(value ?? 0)
  return Number.isFinite(numeric) ? Math.min(100, Math.max(0, numeric)) : 0
}

function metricLevel(value: number | null | undefined) {
  const numeric = metricValue(value)
  return numeric >= 90 ? 'critical' : numeric >= 75 ? 'warning' : 'normal'
}

onMounted(() => {
  loadBranding()
  applyTheme()
  load()
  window.addEventListener('guanlan:realtime', scheduleRefresh)
  document.addEventListener('visibilitychange', handleVisibilityChange)
  pollTimer = window.setInterval(poll, 30_000)
})
onBeforeUnmount(() => {
  window.clearTimeout(timer)
  window.clearInterval(pollTimer)
  window.removeEventListener('guanlan:realtime', scheduleRefresh)
  document.removeEventListener('visibilitychange', handleVisibilityChange)
})
</script>

<template>
  <main class="public-status-page">
    <header class="public-status-header"><RouterLink class="public-status-brand" to="/"><BrandMark /><span><strong>{{ overview?.siteName || siteName }}</strong><small>PUBLIC STATUS</small></span></RouterLink><div class="public-status-actions"><a class="icon-button" :href="githubUrl" target="_blank" rel="noopener noreferrer" aria-label="访问 GitHub 仓库" title="访问 GitHub 仓库"><Github :size="18" /></a><RouterLink class="public-status-login" to="/login"><LogIn :size="15" />登录控制台</RouterLink><button class="icon-button" type="button" :aria-label="dark ? '切换浅色模式' : '切换深色模式'" :title="dark ? '浅色模式' : '深色模式'" @click="toggleTheme"><Sun v-if="dark" :size="18" /><Moon v-else :size="18" /></button></div></header>

    <div class="public-status-content">
      <div v-if="loading" class="public-status-state"><RefreshCw :size="22" class="spinning" /><span>正在读取状态</span></div>
      <div v-else-if="error" class="public-status-state public-status-error"><WifiOff :size="22" /><strong>状态暂时不可用</strong><span>{{ error }}</span><button type="button" @click="load">重新加载</button></div>
      <template v-else-if="overview">
        <section class="public-status-intro"><div><p class="eyebrow">LIVE INFRASTRUCTURE STATUS</p><h1>{{ overview.siteName }}</h1><p>公开展示服务器在线状态、资源负载与服务可用性。</p></div><div class="public-status-updated"><span class="public-live-indicator"><i />实时</span><Clock3 :size="15" />更新于 {{ relativeTime(overview.generatedAt) }}</div></section>

        <section class="public-summary-grid"><article><span><Server :size="17" />服务器</span><strong>{{ overview.totalDevices }}</strong><small>{{ overview.onlineDevices }} 台在线</small></article><article><span><Activity :size="17" />在线率</span><strong>{{ overview.totalDevices ? `${Math.round(overview.onlineDevices / overview.totalDevices * 100)}%` : '--' }}</strong><small>{{ overview.offlineDevices }} 台离线</small></article><article><span><ArrowUp :size="17" />上行</span><strong>{{ rate(overview.networkSentBps) }}</strong><small>当前总速率</small></article><article><span><ArrowDown :size="17" />下行</span><strong>{{ rate(overview.networkRecvBps) }}</strong><small>当前总速率</small></article><article><span><ArrowUp :size="17" />累计上行</span><strong>{{ bytes(overview.totalNetworkSentBytes) }}</strong><small>最近上报总量</small></article><article><span><ArrowDown :size="17" />累计下行</span><strong>{{ bytes(overview.totalNetworkRecvBytes) }}</strong><small>最近上报总量</small></article></section>
        <div class="public-filter-strip"><label class="public-search"><span>搜索服务器</span><input v-model="search" type="search" placeholder="名称、系统或分组" /></label></div>
        <section class="public-status-section"><div class="public-section-head"><div><p class="eyebrow">SERVERS</p><h2>服务器状态</h2></div><label class="public-sort"><span>排序</span><select v-model="sort"><option value="default">默认</option><option value="name">名称</option><option value="os">系统</option><option value="uptime">运行时间</option><option value="cpu">CPU</option><option value="memory">内存</option><option value="disk">磁盘</option><option value="up">实时上行</option><option value="down">实时下行</option><option value="totalUp">累计上行</option><option value="totalDown">累计下行</option></select></label></div><div v-if="sortedDevices.length" class="public-server-grid"><article v-for="device in sortedDevices" :key="device.id" class="public-server-card" :data-status="device.status"><header><div><strong>{{ device.name }}</strong><small>{{ device.groupName || device.os || '未分组' }}</small></div><span class="public-dot" :data-status="device.status"><i />{{ device.status === 'ONLINE' ? '在线' : device.status === 'OFFLINE' ? '离线' : '待接入' }}</span></header><div class="public-server-metrics"><div><span>CPU</span><strong>{{ percent(device.cpuUsage) }}</strong><i role="progressbar" :aria-valuenow="metricValue(device.cpuUsage)" aria-valuemin="0" aria-valuemax="100"><b :data-level="metricLevel(device.cpuUsage)" :style="{ width: `${metricValue(device.cpuUsage)}%` }" /></i></div><div><span>内存</span><strong>{{ percent(device.memoryUsage) }}</strong><i role="progressbar" :aria-valuenow="metricValue(device.memoryUsage)" aria-valuemin="0" aria-valuemax="100"><b :data-level="metricLevel(device.memoryUsage)" :style="{ width: `${metricValue(device.memoryUsage)}%` }" /></i></div><div><span>磁盘</span><strong>{{ percent(device.diskUsage) }}</strong><i role="progressbar" :aria-valuenow="metricValue(device.diskUsage)" aria-valuemin="0" aria-valuemax="100"><b :data-level="metricLevel(device.diskUsage)" :style="{ width: `${metricValue(device.diskUsage)}%` }" /></i></div></div><footer><span><ArrowUp :size="13" />{{ rate(device.networkSentBps) }}</span><span><ArrowDown :size="13" />{{ rate(device.networkRecvBps) }}</span><small>{{ device.status === 'ONLINE' ? uptime(device.uptimeSeconds) : relativeTime(device.lastSeenAt) }}</small></footer></article></div><div v-else class="public-empty"><Server :size="20" /><span>暂无公开服务器</span></div></section>

        <section class="public-status-section"><div class="public-section-head"><div><p class="eyebrow">SERVICES</p><h2>服务可用性</h2></div><span class="public-section-count"><CheckCircle2 :size="15" />{{ onlineServices }} / {{ overview.services.length }} 正常</span></div><div v-if="overview.services.length" class="public-availability-grid"><ServiceAvailabilityCard v-for="service in overview.services" :key="service.id" :name="service.name" :type-label="serviceLabel(service)" :latest="service.latest" :history="service.history" :availability-percent="service.availabilityPercent" /></div><div v-else class="public-empty"><Gauge :size="20" /><span>暂无公开服务监控</span></div></section>
      </template>
    </div>
    <footer class="public-status-footer"><span>自托管监控状态页</span><span>·</span><span>{{ overview?.generatedAt ? new Date(overview.generatedAt).getFullYear() : new Date().getFullYear() }} {{ overview?.siteName || siteName }}</span></footer>
  </main>
</template>
