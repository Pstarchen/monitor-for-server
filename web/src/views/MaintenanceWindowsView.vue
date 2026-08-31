<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { CalendarClock, Pencil, Plus, RefreshCw, Trash2 } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { dateTime } from '@/lib/format'
import { useAuthStore } from '@/stores/auth'
import type { AlertRule, Device, MaintenanceRecurrence, MaintenanceWindow } from '@/types'

const auth = useAuthStore()
const windows = ref<MaintenanceWindow[]>([])
const devices = ref<Device[]>([])
const rules = ref<AlertRule[]>([])
const loading = ref(true)
const error = ref('')
const dialog = ref(false)
const saving = ref(false)
const editingId = ref<number | null>(null)
const localTimezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'Asia/Shanghai'
const form = reactive<{
  name: string
  deviceId: string
  ruleId: number | null
  range: [Date, Date] | []
  timezone: string
  recurrence: MaintenanceRecurrence
  repeatUntil: Date | null
  reason: string
  enabled: boolean
}>({ name: '', deviceId: '', ruleId: null, range: [], timezone: localTimezone, recurrence: 'NONE', repeatUntil: null, reason: '', enabled: true })

const canEdit = computed(() => auth.user?.role === 'ADMIN' || auth.user?.role === 'OPERATOR')
const recurrenceLabels: Record<MaintenanceRecurrence, string> = { NONE: '单次', DAILY: '每天', WEEKLY: '每周' }

async function load() {
  loading.value = true
  error.value = ''
  try {
    const [windowResponse, deviceResponse, ruleResponse] = await Promise.all([
      api.get<MaintenanceWindow[]>('/maintenance-windows'),
      api.get<Device[]>('/devices'),
      api.get<AlertRule[]>('/alert-rules'),
    ])
    windows.value = windowResponse.data
    devices.value = deviceResponse.data
    rules.value = ruleResponse.data
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

function openCreate() {
  const start = new Date()
  start.setMinutes(Math.ceil(start.getMinutes() / 15) * 15, 0, 0)
  const end = new Date(start.getTime() + 60 * 60 * 1000)
  editingId.value = null
  Object.assign(form, { name: '', deviceId: '', ruleId: null, range: [start, end], timezone: localTimezone, recurrence: 'NONE', repeatUntil: null, reason: '', enabled: true })
  dialog.value = true
}

function openEdit(window: MaintenanceWindow) {
  editingId.value = window.id
  Object.assign(form, {
    name: window.name,
    deviceId: window.deviceId ?? '',
    ruleId: window.ruleId,
    range: [new Date(window.startsAt), new Date(window.endsAt)],
    timezone: window.timezone,
    recurrence: window.recurrence,
    repeatUntil: window.repeatUntil ? new Date(window.repeatUntil) : null,
    reason: window.reason ?? '',
    enabled: window.enabled,
  })
  dialog.value = true
}

function state(window: MaintenanceWindow) {
  if (!window.enabled) return 'DISABLED'
  if (window.active) return 'ACTIVE'
  if (window.recurrence === 'NONE' && new Date(window.endsAt).getTime() <= Date.now()) return 'ENDED'
  return 'SCHEDULED'
}

function scopeText(window: MaintenanceWindow) {
  if (window.ruleName && window.deviceName) return `${window.deviceName} / ${window.ruleName}`
  return window.ruleName || window.deviceName || '全部设备与规则'
}

function repeatText(window: MaintenanceWindow) {
  if (window.recurrence === 'NONE') return '仅执行一次'
  const until = window.repeatUntil ? `，至 ${dateTime(window.repeatUntil)}` : '，长期重复'
  return `${recurrenceLabels[window.recurrence]}${until}`
}

async function save() {
  if (!form.name.trim()) {
    ElMessage.warning('请输入维护窗口名称')
    return
  }
  if (form.range.length !== 2 || form.range[1].getTime() <= form.range[0].getTime()) {
    ElMessage.warning('请选择有效的开始和结束时间')
    return
  }
  saving.value = true
  const payload = {
    name: form.name.trim(),
    deviceId: form.deviceId || null,
    ruleId: form.ruleId,
    startsAt: form.range[0].toISOString(),
    endsAt: form.range[1].toISOString(),
    timezone: form.timezone.trim() || localTimezone,
    recurrence: form.recurrence,
    repeatUntil: form.recurrence === 'NONE' || !form.repeatUntil ? null : form.repeatUntil.toISOString(),
    reason: form.reason.trim() || null,
    enabled: form.enabled,
  }
  try {
    if (editingId.value) await api.put(`/maintenance-windows/${editingId.value}`, payload)
    else await api.post('/maintenance-windows', payload)
    dialog.value = false
    ElMessage.success(editingId.value ? '维护窗口已更新' : '维护窗口已创建')
    await load()
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    saving.value = false
  }
}

async function remove(window: MaintenanceWindow) {
  try {
    await ElMessageBox.confirm(`确认删除维护窗口“${window.name}”？`, '删除维护窗口', { type: 'warning', confirmButtonText: '确认删除', cancelButtonText: '取消' })
    await api.delete(`/maintenance-windows/${window.id}`)
    ElMessage.success('维护窗口已删除')
    await load()
  } catch (cause) {
    if (cause !== 'cancel' && cause !== 'close') ElMessage.error(errorMessage(cause))
  }
}

onMounted(load)
</script>

<template>
  <section>
    <PageHeader eyebrow="MAINTENANCE" title="维护静默" description="在发布、迁移或检修期间保留告警事件，同时暂停通知；窗口结束后仍未恢复的故障会自动补发通知。">
      <template #actions><el-button @click="load"><RefreshCw :size="16" />刷新</el-button><el-button v-if="canEdit" type="primary" class="button-press" @click="openCreate"><Plus :size="16" />新建窗口</el-button></template>
    </PageHeader>
    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel"><EmptyState title="维护窗口加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState></div>
    <article v-else class="panel">
      <div v-if="windows.length" class="table-wrap"><table class="data-table maintenance-table"><thead><tr><th>维护窗口</th><th>静默范围</th><th>时间范围</th><th>重复策略</th><th>状态</th><th>原因</th><th class="actions-column">操作</th></tr></thead><tbody><tr v-for="window in windows" :key="window.id"><td><strong>{{ window.name }}</strong><small>{{ window.timezone }}</small></td><td>{{ scopeText(window) }}</td><td><strong>{{ dateTime(window.startsAt) }}</strong><small>至 {{ dateTime(window.endsAt) }}</small></td><td>{{ repeatText(window) }}</td><td><StatusBadge :status="state(window)" /></td><td><span class="maintenance-reason">{{ window.reason || '--' }}</span></td><td class="row-actions"><button v-if="canEdit" class="table-icon-button" type="button" title="编辑维护窗口" aria-label="编辑维护窗口" @click="openEdit(window)"><Pencil :size="16" /></button><button v-if="canEdit" class="table-icon-button danger-command" type="button" title="删除维护窗口" aria-label="删除维护窗口" @click="remove(window)"><Trash2 :size="16" /></button></td></tr></tbody></table></div>
      <EmptyState v-else title="暂无维护窗口" description="计划检修前创建静默窗口，可以避免通知风暴，同时保留完整事件轨迹。"><el-button v-if="canEdit" type="primary" @click="openCreate"><CalendarClock :size="16" />新建窗口</el-button></EmptyState>
    </article>

    <el-dialog v-model="dialog" :title="editingId ? '编辑维护窗口' : '新建维护窗口'" width="min(620px, calc(100vw - 28px))" destroy-on-close>
      <el-form label-position="top">
        <el-form-item label="窗口名称" required><el-input v-model="form.name" maxlength="100" placeholder="例如：生产环境例行发布" /></el-form-item>
        <div class="form-grid two-fields">
          <el-form-item label="设备范围"><el-select v-model="form.deviceId" clearable placeholder="全部设备"><el-option label="全部设备" value="" /><el-option v-for="device in devices" :key="device.id" :label="device.name" :value="device.id" /></el-select></el-form-item>
          <el-form-item label="规则范围"><el-select v-model="form.ruleId" clearable placeholder="全部规则"><el-option v-for="rule in rules" :key="rule.id" :label="rule.name" :value="rule.id" /></el-select></el-form-item>
        </div>
        <el-form-item label="开始与结束时间" required><el-date-picker v-model="form.range" type="datetimerange" range-separator="至" start-placeholder="开始时间" end-placeholder="结束时间" value-format="x" class="maintenance-range" /></el-form-item>
        <div class="form-grid two-fields">
          <el-form-item label="重复策略"><el-select v-model="form.recurrence"><el-option label="仅一次" value="NONE" /><el-option label="每天" value="DAILY" /><el-option label="每周" value="WEEKLY" /></el-select></el-form-item>
          <el-form-item label="时区"><el-input v-model="form.timezone" maxlength="64" placeholder="Asia/Shanghai" /></el-form-item>
        </div>
        <el-form-item v-if="form.recurrence !== 'NONE'" label="重复结束时间"><el-date-picker v-model="form.repeatUntil" type="datetime" placeholder="留空表示长期重复" class="maintenance-range" /></el-form-item>
        <el-form-item label="维护原因"><el-input v-model="form.reason" type="textarea" :rows="3" maxlength="300" show-word-limit placeholder="可选，例如：数据库主从切换" /></el-form-item>
        <el-form-item label="启用窗口"><el-switch v-model="form.enabled" /></el-form-item>
      </el-form>
      <template #footer><el-button @click="dialog = false">取消</el-button><el-button type="primary" :loading="saving" @click="save">保存窗口</el-button></template>
    </el-dialog>
  </section>
</template>
