<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { ClipboardList, RefreshCw, Search } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import { api, errorMessage } from '@/lib/api'
import { dateTime } from '@/lib/format'
import type { AuditLog } from '@/types'

const logs = ref<AuditLog[]>([])
const loading = ref(true)
const error = ref('')
const search = ref('')
const actionLabels: Record<string, string> = {
  DEVICE_CREATE: '创建设备', DEVICE_UPDATE: '更新设备', DEVICE_DELETE: '删除设备', DEVICE_KEY_ROTATE: '轮换密钥',
  ALERT_ACKNOWLEDGE: '确认告警', ALERT_RULE_CREATE: '创建规则', ALERT_RULE_UPDATE: '更新规则', ALERT_RULE_DELETE: '删除规则',
  USER_CREATE: '创建账号', USER_UPDATE: '更新账号', SETTINGS_UPDATE: '更新设置',
}
const filtered = computed(() => {
  const needle = search.value.trim().toLowerCase()
  return needle ? logs.value.filter((log) => [log.actor, log.action, log.target, log.summary].some((value) => value.toLowerCase().includes(needle))) : logs.value
})

async function load() {
  loading.value = true
  error.value = ''
  try {
    logs.value = (await api.get<AuditLog[]>('/admin/audit-logs', { params: { limit: 300 } })).data
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

onMounted(load)
</script>

<template>
  <section>
    <PageHeader eyebrow="AUDIT TRAIL" title="审计日志" description="追踪设备、规则、账号和系统设置的关键变更。">
      <template #actions><el-button @click="load"><RefreshCw :size="16" />刷新</el-button></template>
    </PageHeader>
    <div class="filter-bar"><el-input v-model="search" clearable class="search-input" placeholder="搜索操作者、动作或目标"><template #prefix><Search :size="15" /></template></el-input><span class="filter-count">{{ filtered.length }} 条记录</span></div>
    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel"><EmptyState title="审计日志加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState></div>
    <article v-else class="panel">
      <div v-if="filtered.length" class="audit-timeline">
        <div v-for="log in filtered" :key="log.id" class="audit-entry">
          <span class="audit-icon"><ClipboardList :size="16" /></span>
          <div class="audit-main"><div><strong>{{ actionLabels[log.action] || log.action }}</strong><span class="mono-value">{{ log.target }}</span></div><p>{{ log.summary || '无补充说明' }}</p><small>{{ log.actor }} · {{ dateTime(log.createdAt) }}</small></div>
        </div>
      </div>
      <EmptyState v-else title="没有匹配的审计记录" description="关键管理操作产生后会按时间倒序显示在这里。" />
    </article>
  </section>
</template>
