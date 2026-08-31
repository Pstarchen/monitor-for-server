<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { Archive, CheckCircle2, Clock3, Database, RefreshCw, RotateCcw, ShieldCheck } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import EmptyState from '@/components/EmptyState.vue'
import LoadingState from '@/components/LoadingState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { dateTime } from '@/lib/format'
import type { ControllerBackupFile, ControllerBackupStatus } from '@/types'

const status = ref<ControllerBackupStatus | null>(null)
const loading = ref(true)
const error = ref('')
const creating = ref(false)
const restoring = ref<string | null>(null)
const autoSaving = ref(false)
const retention = ref(7)
let pollTimer: ReturnType<typeof setTimeout> | undefined

function isBusy(value?: ControllerBackupStatus | null) {
  return value?.state === 'CREATING' || value?.state === 'RESTORING'
}

function formatBytes(value: number) {
  if (!Number.isFinite(value) || value < 1024) return `${Math.max(0, value)} B`
  const units = ['KB', 'MB', 'GB', 'TB']
  let amount = value
  let unit = 'B'
  for (const next of units) {
    amount /= 1024
    unit = next
    if (amount < 1024 || next === units[units.length - 1]) break
  }
  return `${amount.toFixed(amount >= 10 ? 0 : 1)} ${unit}`
}

function phaseLabel(value: ControllerBackupStatus['state']) {
  return ({ IDLE: '就绪', CREATING: '创建中', RESTORING: '恢复中', ERROR: '异常' } as Record<ControllerBackupStatus['state'], string>)[value]
}

function schedulePoll() {
  if (pollTimer) clearTimeout(pollTimer)
  if (!isBusy(status.value)) return
  pollTimer = setTimeout(() => { void load(true) }, 2000)
}

async function load(background = false) {
  if (!background) loading.value = true
  error.value = ''
  try {
    status.value = (await api.get<ControllerBackupStatus>('/admin/controller-backups')).data
    retention.value = status.value.retention || 7
    schedulePoll()
  } catch (cause) {
    if (!background) error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

async function createBackup() {
  creating.value = true
  try {
    status.value = (await api.post<ControllerBackupStatus>('/admin/controller-backups')).data
    ElMessage.success('备份任务已启动')
    schedulePoll()
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    creating.value = false
  }
}

async function restoreBackup(file: ControllerBackupFile) {
  try {
    await ElMessageBox.confirm(
      `恢复“${file.name}”会暂时停止总控服务，并覆盖当前监控数据库。恢复完成后服务会自动启动。`,
      '恢复数据库备份',
      { type: 'warning', confirmButtonText: '确认恢复', cancelButtonText: '取消' },
    )
  } catch {
    return
  }
  restoring.value = file.name
  try {
    status.value = (await api.post<ControllerBackupStatus>('/admin/controller-backups/restore', { name: file.name })).data
    ElMessage.success('恢复任务已启动，服务会在完成后自动重启')
    schedulePoll()
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    restoring.value = null
  }
}

async function savePolicy() {
  autoSaving.value = true
  try {
    status.value = (await api.put<ControllerBackupStatus>('/admin/controller-backups/auto', {
      enabled: Boolean(status.value?.autoBackup), retention: retention.value,
    })).data
    ElMessage.success(status.value.autoBackup ? '已启用每日自动备份' : '已关闭每日自动备份')
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    autoSaving.value = false
  }
}

onMounted(() => { void load() })
onBeforeUnmount(() => { if (pollTimer) clearTimeout(pollTimer) })
</script>

<template>
  <section>
    <PageHeader eyebrow="RECOVERY" title="备份与恢复" description="为总控数据库保留可验证的恢复点，降低升级和主机故障风险。">
      <template #actions>
        <el-button :disabled="loading || isBusy(status)" @click="load"><RefreshCw :size="16" />刷新</el-button>
        <el-button type="primary" :loading="creating" :disabled="isBusy(status)" @click="createBackup"><Archive :size="16" />立即备份</el-button>
      </template>
    </PageHeader>

    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel"><EmptyState title="备份状态加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState></div>
    <template v-else-if="status">
      <div class="backup-overview-grid">
        <article class="panel backup-status-panel">
          <div class="panel-heading"><div><p class="eyebrow">CURRENT STATE</p><h2>恢复点状态</h2></div><StatusBadge :status="status.state === 'IDLE' ? 'ONLINE' : status.state === 'ERROR' ? 'CRITICAL' : 'PENDING'" /></div>
          <div class="backup-state-value"><span><Database :size="18" />{{ phaseLabel(status.state) }}</span><strong>{{ status.message || '暂无任务记录' }}</strong><small v-if="status.finishedAt">完成于 {{ dateTime(status.finishedAt) }}</small></div>
          <div class="backup-facts"><div><span>备份数量</span><strong>{{ status.backups.length }}</strong></div><div><span>保留数量</span><strong>{{ status.retention }}</strong></div><div><span>最近备份</span><strong>{{ status.lastBackup || '暂无' }}</strong></div></div>
        </article>
        <article class="panel backup-policy-panel">
          <div class="panel-heading"><div><p class="eyebrow">POLICY</p><h2>自动备份策略</h2></div><ShieldCheck :size="18" /></div>
          <div class="backup-policy-row"><div><strong>每天 03:00 自动创建</strong><p>使用部署时区执行，失败不会删除已有备份。</p></div><el-switch v-model="status.autoBackup" :disabled="isBusy(status) || autoSaving" aria-label="启用每日自动备份" /></div>
          <div class="backup-policy-row"><div><strong>保留最近备份</strong><p>超出数量后自动删除最旧的 SQL 文件。</p></div><el-input-number v-model="retention" :min="1" :max="100" :disabled="isBusy(status) || autoSaving" /></div>
          <div class="backup-policy-actions"><span><CheckCircle2 :size="14" />备份文件仅保存于总控项目目录</span><el-button type="primary" :loading="autoSaving" :disabled="isBusy(status)" @click="savePolicy">保存策略</el-button></div>
        </article>
      </div>

      <article class="panel backup-list-panel">
        <div class="panel-heading"><div><p class="eyebrow">RECOVERY POINTS</p><h2>可用备份</h2></div><span class="panel-heading-meta"><Clock3 :size="14" />{{ status.backups.length }} 个恢复点</span></div>
        <div v-if="status.backups.length" class="table-wrap"><table class="data-table"><thead><tr><th>文件</th><th>大小</th><th>创建时间</th><th class="actions-column">操作</th></tr></thead><tbody><tr v-for="file in status.backups" :key="file.name"><td><strong class="mono-value">{{ file.name }}</strong><small>PostgreSQL SQL 格式</small></td><td>{{ formatBytes(file.size) }}</td><td>{{ dateTime(file.createdAt) }}</td><td class="row-actions"><el-button text type="warning" :loading="restoring === file.name" :disabled="isBusy(status)" @click="restoreBackup(file)"><RotateCcw :size="15" />恢复</el-button></td></tr></tbody></table></div>
        <EmptyState v-else title="暂无数据库备份" description="创建第一个恢复点后，它会出现在这里并按策略自动保留。"><el-button type="primary" :loading="creating" @click="createBackup"><Archive :size="16" />立即备份</el-button></EmptyState>
      </article>
    </template>
  </section>
</template>
