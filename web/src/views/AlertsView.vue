<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { BellRing, CheckCheck, RefreshCw, Search } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { dateTime } from '@/lib/format'
import { useVisibilityPolling } from '@/lib/visibility-polling'
import { useAuthStore } from '@/stores/auth'
import type { AlertEvent, AlertSeverity, AlertStatus } from '@/types'

const auth = useAuthStore()
const alerts = ref<AlertEvent[]>([])
const loading = ref(true)
const error = ref('')
const search = ref('')
const status = ref<AlertStatus | ''>('')
const severity = ref<AlertSeverity | ''>('')
const acknowledging = ref<number | null>(null)
const canAcknowledge = computed(() => auth.user?.role === 'ADMIN' || auth.user?.role === 'OPERATOR')
const filtered = computed(() => {
  const needle = search.value.trim().toLowerCase()
  return alerts.value.filter((alert) => (!status.value || alert.status === status.value)
    && (!severity.value || alert.severity === severity.value)
    && (!needle || [alert.deviceName, alert.ruleName, alert.message].some((value) => value.toLowerCase().includes(needle))))
})

async function load(background = false) {
  if (!background) loading.value = true
  error.value = ''
  try {
    alerts.value = (await api.get<AlertEvent[]>('/alerts', { params: { limit: 200 } })).data
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
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

onMounted(load)
useVisibilityPolling(() => load(true))
</script>

<template>
  <section>
    <PageHeader eyebrow="INCIDENTS" title="告警事件" description="集中处理指标越限、设备离线以及恢复事件。">
      <template #actions><el-button @click="load"><RefreshCw :size="16" />刷新</el-button></template>
    </PageHeader>
    <div class="filter-bar">
      <el-input v-model="search" clearable class="search-input" placeholder="搜索设备、规则或消息"><template #prefix><Search :size="15" /></template></el-input>
      <el-select v-model="status" clearable class="compact-select" placeholder="全部状态"><el-option label="待处理" value="OPEN" /><el-option label="已确认" value="ACKNOWLEDGED" /><el-option label="已恢复" value="RESOLVED" /></el-select>
      <el-select v-model="severity" clearable class="compact-select" placeholder="全部级别"><el-option label="严重" value="CRITICAL" /><el-option label="警告" value="WARNING" /><el-option label="提示" value="INFO" /></el-select>
      <span class="filter-count">{{ filtered.length }} 条事件</span>
    </div>
    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel"><EmptyState title="告警加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState></div>
    <article v-else class="panel">
      <div v-if="filtered.length" class="table-wrap"><table class="data-table alert-table"><thead><tr><th>级别</th><th>设备 / 规则</th><th>告警内容</th><th>状态</th><th>触发时间</th><th>处理信息</th><th class="actions-column">操作</th></tr></thead><tbody><tr v-for="alert in filtered" :key="alert.id"><td><StatusBadge :status="alert.severity" /></td><td><strong>{{ alert.deviceName }}</strong><small>{{ alert.ruleName }}</small></td><td><span class="alert-message">{{ alert.message }}</span><small>触发值 {{ alert.value.toFixed(1) }}</small></td><td><StatusBadge :status="alert.status" /></td><td>{{ dateTime(alert.startedAt) }}</td><td><span v-if="alert.acknowledgedBy">{{ alert.acknowledgedBy }}</span><small v-if="alert.acknowledgedAt">{{ dateTime(alert.acknowledgedAt) }}</small><span v-if="alert.resolvedAt" class="resolved-copy">恢复于 {{ dateTime(alert.resolvedAt) }}</span><span v-if="!alert.acknowledgedAt && !alert.resolvedAt">--</span></td><td class="row-actions"><el-button v-if="canAcknowledge && alert.status === 'OPEN'" size="small" :loading="acknowledging === alert.id" @click="acknowledge(alert)"><CheckCheck :size="15" />确认</el-button></td></tr></tbody></table></div>
      <EmptyState v-else title="没有匹配的告警" description="当前筛选范围内没有需要展示的事件。"><BellRing :size="1" /></EmptyState>
    </article>
  </section>
</template>
