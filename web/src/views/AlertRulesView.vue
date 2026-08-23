<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { Pencil, Plus, RefreshCw, SlidersHorizontal, Trash2 } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { dateTime } from '@/lib/format'
import { useAuthStore } from '@/stores/auth'
import type { AlertMetric, AlertRule, AlertSeverity, Device } from '@/types'

const auth = useAuthStore()
const rules = ref<AlertRule[]>([])
const devices = ref<Device[]>([])
const loading = ref(true)
const error = ref('')
const dialog = ref(false)
const saving = ref(false)
const editingId = ref<number | null>(null)
const form = reactive<{ name: string; deviceId: string; metric: AlertMetric; threshold: number; severity: AlertSeverity; enabled: boolean }>({ name: '', deviceId: '', metric: 'CPU_USAGE', threshold: 80, severity: 'WARNING', enabled: true })
const canEdit = computed(() => auth.user?.role === 'ADMIN' || auth.user?.role === 'OPERATOR')
const metricLabels: Record<AlertMetric, string> = { CPU_USAGE: 'CPU 使用率', MEMORY_USAGE: '内存使用率', DISK_USAGE: '磁盘使用率', TCP_CONNECTIONS: 'TCP 连接数', DEVICE_OFFLINE: '设备离线' }

async function load() {
  loading.value = true
  error.value = ''
  try {
    const [ruleResponse, deviceResponse] = await Promise.all([api.get<AlertRule[]>('/alert-rules'), api.get<Device[]>('/devices')])
    rules.value = ruleResponse.data
    devices.value = deviceResponse.data
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

function defaultThreshold(metric: AlertMetric) {
  return metric === 'DEVICE_OFFLINE' ? 30 : metric === 'DISK_USAGE' ? 85 : metric === 'TCP_CONNECTIONS' ? 100 : 80
}

function openCreate() {
  editingId.value = null
  Object.assign(form, { name: '', deviceId: '', metric: 'CPU_USAGE', threshold: 80, severity: 'WARNING', enabled: true })
  dialog.value = true
}

function openEdit(rule: AlertRule) {
  editingId.value = rule.id
  Object.assign(form, { name: rule.name, deviceId: rule.deviceId ?? '', metric: rule.metric, threshold: rule.threshold, severity: rule.severity, enabled: rule.enabled })
  dialog.value = true
}

function metricChanged(value: AlertMetric) {
  form.threshold = defaultThreshold(value)
}

async function save() {
  if (!form.name.trim()) {
    ElMessage.warning('请输入规则名称')
    return
  }
  saving.value = true
  const payload = { ...form, name: form.name.trim(), deviceId: form.deviceId || null }
  try {
    if (editingId.value) await api.put(`/alert-rules/${editingId.value}`, payload)
    else await api.post('/alert-rules', payload)
    dialog.value = false
    ElMessage.success(editingId.value ? '规则已更新' : '规则已创建')
    await load()
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    saving.value = false
  }
}

async function remove(rule: AlertRule) {
  try {
    await ElMessageBox.confirm(`删除规则“${rule.name}”不会删除已产生的告警事件。`, '删除告警规则', { type: 'warning', confirmButtonText: '确认删除', cancelButtonText: '取消' })
    await api.delete(`/alert-rules/${rule.id}`)
    ElMessage.success('规则已删除')
    await load()
  } catch (cause) {
    if (cause !== 'cancel' && cause !== 'close') ElMessage.error(errorMessage(cause))
  }
}

onMounted(load)
</script>

<template>
  <section>
    <PageHeader eyebrow="POLICIES" title="告警规则" description="为全局或指定设备设置资源阈值与离线检测规则。">
      <template #actions><el-button @click="load"><RefreshCw :size="16" />刷新</el-button><el-button v-if="canEdit" type="primary" class="button-press" @click="openCreate"><Plus :size="16" />新建规则</el-button></template>
    </PageHeader>
    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel"><EmptyState title="规则加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState></div>
    <article v-else class="panel">
      <div v-if="rules.length" class="table-wrap"><table class="data-table"><thead><tr><th>规则</th><th>监控范围</th><th>指标</th><th>触发阈值</th><th>级别</th><th>状态</th><th>更新时间</th><th class="actions-column">操作</th></tr></thead><tbody><tr v-for="rule in rules" :key="rule.id"><td><strong>{{ rule.name }}</strong></td><td>{{ rule.deviceName || '全部设备' }}</td><td>{{ metricLabels[rule.metric] }}</td><td>{{ rule.metric === 'DEVICE_OFFLINE' ? `${rule.threshold.toFixed(0)} 秒` : rule.metric === 'TCP_CONNECTIONS' ? `${rule.threshold.toFixed(0)} 个` : `${rule.threshold.toFixed(1)}%` }}</td><td><StatusBadge :status="rule.severity" /></td><td><StatusBadge :status="rule.enabled ? 'ONLINE' : 'OFFLINE'" /></td><td>{{ dateTime(rule.updatedAt) }}</td><td class="row-actions"><button v-if="canEdit" class="table-icon-button" type="button" title="编辑规则" aria-label="编辑规则" @click="openEdit(rule)"><Pencil :size="16" /></button><button v-if="canEdit" class="table-icon-button danger-command" type="button" title="删除规则" aria-label="删除规则" @click="remove(rule)"><Trash2 :size="16" /></button></td></tr></tbody></table></div>
      <EmptyState v-else title="暂无告警规则" description="创建规则后，服务端会在每次 Agent 上报时自动评估指标。"><el-button v-if="canEdit" type="primary" @click="openCreate"><SlidersHorizontal :size="16" />新建规则</el-button></EmptyState>
    </article>

    <el-dialog v-model="dialog" :title="editingId ? '编辑告警规则' : '新建告警规则'" width="min(540px, calc(100vw - 28px))" destroy-on-close>
      <el-form label-position="top">
        <el-form-item label="规则名称" required><el-input v-model="form.name" maxlength="100" placeholder="例如：生产节点 CPU 过高" /></el-form-item>
        <div class="form-grid two-fields">
          <el-form-item label="监控范围"><el-select v-model="form.deviceId" placeholder="全部设备" clearable><el-option label="全部设备" value="" /><el-option v-for="device in devices" :key="device.id" :label="device.name" :value="device.id" /></el-select></el-form-item>
          <el-form-item label="监控指标" required><el-select v-model="form.metric" @change="metricChanged"><el-option v-for="(label, value) in metricLabels" :key="value" :label="label" :value="value" /></el-select></el-form-item>
          <el-form-item label="告警级别" required><el-select v-model="form.severity"><el-option label="提示" value="INFO" /><el-option label="警告" value="WARNING" /><el-option label="严重" value="CRITICAL" /></el-select></el-form-item>
          <el-form-item label="触发阈值"><el-input-number v-model="form.threshold" :min="0" :max="form.metric === 'DEVICE_OFFLINE' ? 86400 : ['CPU_USAGE', 'MEMORY_USAGE', 'DISK_USAGE'].includes(form.metric) ? 100 : 1000000" :precision="form.metric === 'DEVICE_OFFLINE' || form.metric === 'TCP_CONNECTIONS' ? 0 : 1" /><span class="field-suffix">{{ form.metric === 'DEVICE_OFFLINE' ? '秒' : form.metric === 'TCP_CONNECTIONS' ? '个' : '%' }}</span></el-form-item>
        </div>
        <el-form-item label="启用规则"><el-switch v-model="form.enabled" /></el-form-item>
      </el-form>
      <template #footer><el-button @click="dialog = false">取消</el-button><el-button type="primary" :loading="saving" @click="save">保存规则</el-button></template>
    </el-dialog>
  </section>
</template>
