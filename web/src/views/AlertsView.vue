<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { BellRing, CheckCheck, RefreshCw, Search, Server, SquareCheck, Square } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { dateTime } from '@/lib/format'
import { useVisibilityPolling } from '@/lib/visibility-polling'
import { useAuthStore } from '@/stores/auth'
import type { AlertEvent, AlertSeverity, AlertStatus, Device } from '@/types'

const auth = useAuthStore()
const alerts = ref<AlertEvent[]>([])
const devices = ref<Device[]>([])
const loading = ref(true)
const error = ref('')
const search = ref('')
const status = ref<AlertStatus | ''>('')
const severity = ref<AlertSeverity | ''>('')
const acknowledging = ref<number | null>(null)
const acknowledgingMany = ref(false)
const selectedIds = ref<number[]>([])
const deviceId = ref('')
const canAcknowledge = computed(() => auth.user?.role === 'ADMIN' || auth.user?.role === 'OPERATOR')
const filtered = computed(() => {
  const needle = search.value.trim().toLowerCase()
  return alerts.value.filter((alert) => (!status.value || alert.status === status.value)
    && (!severity.value || alert.severity === severity.value)
    && (!deviceId.value || alert.deviceId === deviceId.value)
    && (!needle || [alert.deviceName, alert.ruleName, alert.message].some((value) => value.toLowerCase().includes(needle))))
})
const openCount = computed(() => alerts.value.filter((alert) => alert.status === 'OPEN').length)
const acknowledgedCount = computed(() => alerts.value.filter((alert) => alert.status === 'ACKNOWLEDGED').length)
const selectableIds = computed(() => filtered.value.filter((alert) => alert.status === 'OPEN').map((alert) => alert.id))
const selectedOpenIds = computed(() => selectedIds.value.filter((id) => selectableIds.value.includes(id)))
const allSelected = computed(() => selectableIds.value.length > 0 && selectableIds.value.every((id) => selectedIds.value.includes(id)))

async function load(background = false) {
  if (!background) loading.value = true
  error.value = ''
  try {
    const [alertResponse, deviceResponse] = await Promise.all([
      api.get<AlertEvent[]>('/alerts', { params: { limit: 500, status: status.value || undefined, severity: severity.value || undefined, deviceId: deviceId.value || undefined } }),
      api.get<Device[]>('/devices'),
    ])
    alerts.value = alertResponse.data
    devices.value = deviceResponse.data
    selectedIds.value = selectedIds.value.filter((id) => alerts.value.some((alert) => alert.id === id && alert.status === 'OPEN'))
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

function toggleSelected(id: number, checked: boolean) {
  if (!checked) selectedIds.value = selectedIds.value.filter((value) => value !== id)
  else if (!selectedIds.value.includes(id)) selectedIds.value = [...selectedIds.value, id]
}

function toggleAll(checked: boolean) {
  selectedIds.value = checked
    ? Array.from(new Set([...selectedIds.value, ...selectableIds.value]))
    : selectedIds.value.filter((id) => !selectableIds.value.includes(id))
}

async function acknowledge(alert: AlertEvent) {
  acknowledging.value = alert.id
  try {
    const updated = (await api.post<AlertEvent>(`/alerts/${alert.id}/acknowledge`)).data
    alerts.value = alerts.value.map((item) => item.id === updated.id ? updated : item)
    ElMessage.success('告警已确认')
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    acknowledging.value = null
  }
}

async function acknowledgeSelected() {
  const ids = selectedOpenIds.value
  if (!ids.length) return
  acknowledgingMany.value = true
  try {
    const updated = (await api.post<AlertEvent[]>('/alerts/acknowledge', { ids })).data
    const byId = new Map(updated.map((item) => [item.id, item]))
    alerts.value = alerts.value.map((item) => byId.get(item.id) ?? item)
    selectedIds.value = selectedIds.value.filter((id) => !ids.includes(id))
    ElMessage.success(`已确认 ${updated.length} 条告警`)
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    acknowledgingMany.value = false
  }
}

onMounted(load)
watch([status, severity, deviceId], () => load(true))
useVisibilityPolling(() => load(true))
</script>

<template>
  <section>
    <PageHeader eyebrow="INCIDENTS" title="告警事件" description="集中处理指标越限、设备离线以及恢复事件。">
      <template #actions><el-button :loading="loading" @click="load"><RefreshCw :size="16" />刷新</el-button></template>
    </PageHeader>
    <div class="alert-summary-strip" aria-label="告警摘要">
      <div><span class="alert-summary-icon alert-summary-danger"><BellRing :size="15" /></span><strong>{{ openCount }}</strong><small>待处理</small></div>
      <div><span class="alert-summary-icon alert-summary-warning"><CheckCheck :size="15" /></span><strong>{{ acknowledgedCount }}</strong><small>已确认</small></div>
      <div><span class="alert-summary-icon"><Server :size="15" /></span><strong>{{ devices.length }}</strong><small>监控设备</small></div>
    </div>
    <div class="filter-bar">
      <el-input v-model="search" clearable class="search-input" placeholder="搜索设备、规则或消息"><template #prefix><Search :size="15" /></template></el-input>
      <el-select v-model="status" clearable class="compact-select" placeholder="全部状态"><el-option label="待处理" value="OPEN" /><el-option label="已确认" value="ACKNOWLEDGED" /><el-option label="已恢复" value="RESOLVED" /></el-select>
      <el-select v-model="severity" clearable class="compact-select" placeholder="全部级别"><el-option label="严重" value="CRITICAL" /><el-option label="警告" value="WARNING" /><el-option label="提示" value="INFO" /></el-select>
      <el-select v-model="deviceId" clearable filterable class="device-filter-select" placeholder="全部设备"><el-option v-for="device in devices" :key="device.id" :label="device.name" :value="device.id" /></el-select>
      <span class="filter-count">{{ filtered.length }} 条事件</span>
    </div>
    <div v-if="canAcknowledge && selectedOpenIds.length" class="bulk-action-bar" role="status">
      <span><CheckCheck :size="15" />已选择 {{ selectedOpenIds.length }} 条待处理告警</span>
      <el-button type="primary" size="small" :loading="acknowledgingMany" @click="acknowledgeSelected"><CheckCheck :size="15" />批量确认</el-button>
    </div>
    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel"><EmptyState title="告警加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState></div>
    <article v-else class="panel">
      <div v-if="filtered.length" class="table-wrap"><table class="data-table alert-table"><thead><tr><th v-if="canAcknowledge" class="select-column"><button class="table-select-all" type="button" :aria-label="allSelected ? '取消全选待处理告警' : '全选待处理告警'" :title="allSelected ? '取消全选' : '全选'" @click="toggleAll(!allSelected)"><SquareCheck v-if="allSelected" :size="17" /><Square v-else :size="17" /></button></th><th>级别</th><th>设备 / 规则</th><th>告警内容</th><th>状态</th><th>通知</th><th>触发时间</th><th>处理信息</th><th class="actions-column">操作</th></tr></thead><tbody><tr v-for="alert in filtered" :key="alert.id"><td v-if="canAcknowledge" class="select-column"><input v-if="alert.status === 'OPEN'" type="checkbox" :checked="selectedIds.includes(alert.id)" :aria-label="`选择 ${alert.deviceName} 的告警`" @change="toggleSelected(alert.id, ($event.target as HTMLInputElement).checked)" /></td><td><StatusBadge :status="alert.severity" /></td><td><strong>{{ alert.deviceName }}</strong><small>{{ alert.ruleName }}</small></td><td><span class="alert-message">{{ alert.message }}</span><small>触发值 {{ alert.value.toFixed(1) }}</small></td><td><StatusBadge :status="alert.status" /></td><td><StatusBadge v-if="alert.notificationSuppressed" status="SCHEDULED" /><span v-else-if="alert.notifiedAt">已发送<small>{{ dateTime(alert.notifiedAt) }}</small></span><span v-else>--</span></td><td>{{ dateTime(alert.startedAt) }}</td><td><span v-if="alert.acknowledgedBy">{{ alert.acknowledgedBy }}</span><small v-if="alert.acknowledgedAt">{{ dateTime(alert.acknowledgedAt) }}</small><span v-if="alert.resolvedAt" class="resolved-copy">恢复于 {{ dateTime(alert.resolvedAt) }}</span><span v-if="!alert.acknowledgedAt && !alert.resolvedAt">--</span></td><td class="row-actions"><el-button v-if="canAcknowledge && alert.status === 'OPEN'" size="small" :loading="acknowledging === alert.id" @click="acknowledge(alert)"><CheckCheck :size="15" />确认</el-button></td></tr></tbody></table></div>
      <EmptyState v-else title="没有匹配的告警" description="当前筛选范围内没有需要展示的事件。"><BellRing :size="1" /></EmptyState>
    </article>
  </section>
</template>
