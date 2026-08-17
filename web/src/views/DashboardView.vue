<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { Activity, BellRing, Cpu, HardDrive, MemoryStick, RefreshCw, Server } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import MetricCard from '@/components/MetricCard.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { dateTime, percent, relativeTime } from '@/lib/format'
import type { Dashboard } from '@/types'

const router = useRouter()
const dashboard = ref<Dashboard | null>(null)
const loading = ref(true)
const refreshing = ref(false)
const error = ref('')
let refreshTimer = 0

async function load(background = false) {
  if (background) refreshing.value = true
  else loading.value = true
  error.value = ''
  try {
    dashboard.value = (await api.get<Dashboard>('/dashboard')).data
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
    refreshing.value = false
  }
}

function scheduleRefresh() {
  window.clearTimeout(refreshTimer)
  refreshTimer = window.setTimeout(() => load(true), 350)
}

onMounted(() => {
  load()
  window.addEventListener('guanlan:realtime', scheduleRefresh)
})
onBeforeUnmount(() => {
  window.clearTimeout(refreshTimer)
  window.removeEventListener('guanlan:realtime', scheduleRefresh)
})
</script>

<template>
  <section>
    <PageHeader eyebrow="MONITORING OVERVIEW" title="运行总览" description="汇总当前设备可用性、资源水位与需要处理的告警。">
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
        <MetricCard label="设备总数" :value="dashboard.totalDevices" hint="已登记的监控节点" tone="info"><template #icon><Server :size="17" /></template></MetricCard>
        <MetricCard label="在线设备" :value="dashboard.onlineDevices" :hint="`${dashboard.offlineDevices} 台离线`" :tone="dashboard.offlineDevices ? 'warning' : 'success'"><template #icon><Activity :size="17" /></template></MetricCard>
        <MetricCard label="活动告警" :value="dashboard.activeAlerts" hint="待处理与已确认" :tone="dashboard.activeAlerts ? 'danger' : 'success'"><template #icon><BellRing :size="17" /></template></MetricCard>
        <MetricCard label="平均 CPU" :value="percent(dashboard.averageCpu)" :hint="`内存 ${percent(dashboard.averageMemory)}`" :tone="dashboard.averageCpu >= 80 ? 'danger' : 'neutral'"><template #icon><Cpu :size="17" /></template></MetricCard>
      </div>

      <div class="section two-column">
        <article class="panel">
          <div class="panel-head"><div><h2>高负载设备</h2><p>按最新 CPU 使用率排序</p></div><Cpu :size="17" /></div>
          <div v-if="dashboard.topDevices.length" class="table-wrap">
            <table class="data-table">
              <thead><tr><th>设备</th><th>状态</th><th>CPU</th><th>内存</th><th>磁盘</th><th>最近上报</th></tr></thead>
              <tbody>
                <tr v-for="device in dashboard.topDevices" :key="device.id" class="clickable-row" tabindex="0" @click="router.push(`/devices/${device.id}`)" @keydown.enter="router.push(`/devices/${device.id}`)">
                  <td><strong>{{ device.name }}</strong><small>{{ device.primaryIp || device.hostname || '--' }}</small></td>
                  <td><StatusBadge :status="device.status" /></td>
                  <td><span class="usage-value" :data-level="(device.latest?.cpuUsage ?? 0) >= 80 ? 'high' : 'normal'">{{ percent(device.latest?.cpuUsage) }}</span></td>
                  <td>{{ percent(device.latest?.memoryUsage) }}</td>
                  <td>{{ percent(device.latest?.diskUsage) }}</td>
                  <td>{{ relativeTime(device.lastSeenAt) }}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <EmptyState v-else title="暂无监控样本" description="Agent 上报首个指标后，这里会显示资源负载排行。" />
        </article>

        <article class="panel">
          <div class="panel-head"><div><h2>资源水位</h2><p>全部在线设备的最新均值</p></div><MemoryStick :size="17" /></div>
          <div class="watermark-list">
            <div><span><Cpu :size="15" />CPU</span><strong>{{ percent(dashboard.averageCpu) }}</strong><el-progress :percentage="Math.round(dashboard.averageCpu)" :show-text="false" :stroke-width="7" /></div>
            <div><span><MemoryStick :size="15" />内存</span><strong>{{ percent(dashboard.averageMemory) }}</strong><el-progress :percentage="Math.round(dashboard.averageMemory)" :show-text="false" :stroke-width="7" /></div>
            <div><span><HardDrive :size="15" />磁盘</span><strong>{{ percent(dashboard.averageDisk) }}</strong><el-progress :percentage="Math.round(dashboard.averageDisk)" :show-text="false" :stroke-width="7" /></div>
          </div>
        </article>
      </div>

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
