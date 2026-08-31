<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { Pencil, Plus, RefreshCw, SlidersHorizontal, Trash2 } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { dateTime, rate } from '@/lib/format'
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
const form = reactive<{ name: string; deviceId: string; metric: AlertMetric; targetName: string; threshold: number; severity: AlertSeverity; enabled: boolean }>({ name: '', deviceId: '', metric: 'CPU_USAGE', targetName: '', threshold: 80, severity: 'WARNING', enabled: true })
const canEdit = computed(() => auth.user?.role === 'ADMIN' || auth.user?.role === 'OPERATOR')
const metricLabels: Record<AlertMetric, string> = { CPU_USAGE: 'CPU 使用率', MEMORY_USAGE: '内存使用率', DISK_USAGE: '磁盘使用率', LOAD_1: '1 分钟负载', DISK_READ_BPS: '磁盘读取速率', DISK_WRITE_BPS: '磁盘写入速率', CONTAINER_CPU_USAGE: '容器 CPU 使用率', CONTAINER_MEMORY_USAGE: '容器内存使用率', GPU_USAGE: 'GPU 使用率', BATTERY_PERCENT: '电池电量', SMART_FAILURES: 'SMART 失败磁盘数', INTEGRITY_CHANGES: '完整性变更文件数', FIREWALL_INACTIVE: '防火墙未启用', TCP_CONNECTIONS: 'TCP 连接数', NETWORK_RECV_BPS: '网络接收速率', NETWORK_SENT_BPS: '网络发送速率', TEMPERATURE: '最高温度', FAN_RPM: '最高风扇转速', DEVICE_OFFLINE: '设备离线', PROCESS_MISSING: '关键进程缺失', SERVICE_NOT_RUNNING: '系统服务未运行', CUSTOM_METRIC: '自定义监控项' }
const targetMetrics: AlertMetric[] = ['PROCESS_MISSING', 'SERVICE_NOT_RUNNING', 'CUSTOM_METRIC']
const presenceTargetMetrics: AlertMetric[] = ['PROCESS_MISSING', 'SERVICE_NOT_RUNNING']

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
  if (metric === 'DEVICE_OFFLINE') return 30
  if (metric === 'DISK_USAGE') return 85
  if (metric === 'TCP_CONNECTIONS') return 100
  if (metric === 'TEMPERATURE') return 75
  if (metric === 'FAN_RPM') return 2500
  if (metric === 'LOAD_1') return 4
  if (metric === 'DISK_READ_BPS' || metric === 'DISK_WRITE_BPS') return 10 * 1024 * 1024
  if (metric === 'CONTAINER_CPU_USAGE') return 90
  if (metric === 'GPU_USAGE') return 90
  if (metric === 'BATTERY_PERCENT') return 20
  if (metric === 'SMART_FAILURES') return 1
  if (metric === 'INTEGRITY_CHANGES') return 1
  if (metric === 'FIREWALL_INACTIVE') return 1
  if (presenceTargetMetrics.includes(metric)) return 1
  if (metric === 'NETWORK_RECV_BPS' || metric === 'NETWORK_SENT_BPS') return 10 * 1024 * 1024
  return 80
}

function thresholdText(rule: AlertRule) {
  if (rule.metric === 'DEVICE_OFFLINE') return `${rule.threshold.toFixed(0)} 秒`
  if (rule.metric === 'TCP_CONNECTIONS') return `${rule.threshold.toFixed(0)} 个`
  if (rule.metric === 'SMART_FAILURES') return `${rule.threshold.toFixed(0)} 个`
  if (rule.metric === 'INTEGRITY_CHANGES') return `${rule.threshold.toFixed(0)} 个`
  if (rule.metric === 'FIREWALL_INACTIVE') return rule.threshold >= 1 ? '未启用' : '已启用'
  if (rule.metric === 'CUSTOM_METRIC') return `${rule.targetName || '未设置目标'} ≥ ${rule.threshold}`
  if (presenceTargetMetrics.includes(rule.metric)) return `${rule.targetName || '未设置目标'} 不存在或未运行`
  if (rule.metric === 'TEMPERATURE') return `${rule.threshold.toFixed(1)} °C`
  if (rule.metric === 'FAN_RPM') return `${rule.threshold.toFixed(0)} RPM`
  if (rule.metric === 'LOAD_1') return rule.threshold.toFixed(2)
  if (rule.metric === 'DISK_READ_BPS' || rule.metric === 'DISK_WRITE_BPS') return rate(rule.threshold)
  if (rule.metric === 'NETWORK_RECV_BPS' || rule.metric === 'NETWORK_SENT_BPS') return rate(rule.threshold)
  return `${rule.threshold.toFixed(1)}%`
}

function metricMax(metric: AlertMetric) {
  if (metric === 'DEVICE_OFFLINE') return 86400
  if (metric === 'TEMPERATURE') return 200
  if (metric === 'FAN_RPM') return 100_000
  if (metric === 'LOAD_1') return 1024
  if (metric === 'SMART_FAILURES') return 100
  if (metric === 'INTEGRITY_CHANGES') return 512
  if (metric === 'FIREWALL_INACTIVE') return 1
  if (presenceTargetMetrics.includes(metric)) return 1
  if (metric === 'CPU_USAGE' || metric === 'MEMORY_USAGE' || metric === 'DISK_USAGE' || metric === 'CONTAINER_CPU_USAGE' || metric === 'CONTAINER_MEMORY_USAGE' || metric === 'GPU_USAGE' || metric === 'BATTERY_PERCENT') return 100
  return 1_000_000_000_000
}

function metricMin(metric: AlertMetric) {
  return metric === 'FIREWALL_INACTIVE' ? 1 : 0
}

function metricPrecision(metric: AlertMetric) {
  return metric === 'DEVICE_OFFLINE' || metric === 'TCP_CONNECTIONS' || metric === 'SMART_FAILURES' || metric === 'INTEGRITY_CHANGES' || metric === 'FIREWALL_INACTIVE' || metric === 'NETWORK_RECV_BPS' || metric === 'NETWORK_SENT_BPS' || metric === 'DISK_READ_BPS' || metric === 'DISK_WRITE_BPS' || metric === 'FAN_RPM' ? 0 : metric === 'LOAD_1' ? 2 : 1
}

function metricUnit(metric: AlertMetric) {
  if (metric === 'DEVICE_OFFLINE') return '秒'
  if (metric === 'TCP_CONNECTIONS') return '个'
  if (metric === 'SMART_FAILURES') return '个'
  if (metric === 'INTEGRITY_CHANGES') return '个'
  if (metric === 'FIREWALL_INACTIVE') return ''
  if (presenceTargetMetrics.includes(metric)) return ''
  if (metric === 'TEMPERATURE') return '°C'
  if (metric === 'FAN_RPM') return 'RPM'
  if (metric === 'LOAD_1') return ''
  if (metric === 'DISK_READ_BPS' || metric === 'DISK_WRITE_BPS') return 'B/s'
  if (metric === 'NETWORK_RECV_BPS' || metric === 'NETWORK_SENT_BPS') return 'B/s'
  return '%'
}

function openCreate() {
  editingId.value = null
  Object.assign(form, { name: '', deviceId: '', metric: 'CPU_USAGE', targetName: '', threshold: 80, severity: 'WARNING', enabled: true })
  dialog.value = true
}

function openEdit(rule: AlertRule) {
  editingId.value = rule.id
  Object.assign(form, { name: rule.name, deviceId: rule.deviceId ?? '', metric: rule.metric, targetName: rule.targetName ?? '', threshold: rule.threshold, severity: rule.severity, enabled: rule.enabled })
  dialog.value = true
}

function metricChanged(value: AlertMetric) {
  form.threshold = defaultThreshold(value)
  if (!targetMetrics.includes(value)) form.targetName = ''
}

async function save() {
  if (!form.name.trim()) {
    ElMessage.warning('请输入规则名称')
    return
  }
  if (targetMetrics.includes(form.metric) && !form.targetName.trim()) {
    ElMessage.warning('请输入进程或服务名称')
    return
  }
  saving.value = true
  const payload = { ...form, name: form.name.trim(), deviceId: form.deviceId || null, targetName: targetMetrics.includes(form.metric) ? form.targetName.trim() : null, threshold: presenceTargetMetrics.includes(form.metric) ? 1 : form.threshold }
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
      <div v-if="rules.length" class="table-wrap"><table class="data-table"><thead><tr><th>规则</th><th>监控范围</th><th>指标 / 目标</th><th>触发阈值</th><th>级别</th><th>状态</th><th>更新时间</th><th class="actions-column">操作</th></tr></thead><tbody><tr v-for="rule in rules" :key="rule.id"><td><strong>{{ rule.name }}</strong></td><td>{{ rule.deviceName || '全部设备' }}</td><td><strong>{{ metricLabels[rule.metric] }}</strong><small v-if="rule.targetName" class="cell-subtext mono-value">{{ rule.targetName }}</small></td><td>{{ thresholdText(rule) }}</td><td><StatusBadge :status="rule.severity" /></td><td><StatusBadge :status="rule.enabled ? 'ONLINE' : 'OFFLINE'" /></td><td>{{ dateTime(rule.updatedAt) }}</td><td class="row-actions"><button v-if="canEdit" class="table-icon-button" type="button" title="编辑规则" aria-label="编辑规则" @click="openEdit(rule)"><Pencil :size="16" /></button><button v-if="canEdit" class="table-icon-button danger-command" type="button" title="删除规则" aria-label="删除规则" @click="remove(rule)"><Trash2 :size="16" /></button></td></tr></tbody></table></div>
      <EmptyState v-else title="暂无告警规则" description="创建规则后，服务端会在每次 Agent 上报时自动评估指标。"><el-button v-if="canEdit" type="primary" @click="openCreate"><SlidersHorizontal :size="16" />新建规则</el-button></EmptyState>
    </article>

    <el-dialog v-model="dialog" :title="editingId ? '编辑告警规则' : '新建告警规则'" width="min(540px, calc(100vw - 28px))" destroy-on-close>
      <el-form label-position="top">
        <el-form-item label="规则名称" required><el-input v-model="form.name" maxlength="100" placeholder="例如：生产节点 CPU 过高" /></el-form-item>
        <div class="form-grid two-fields">
          <el-form-item label="监控范围"><el-select v-model="form.deviceId" placeholder="全部设备" clearable><el-option label="全部设备" value="" /><el-option v-for="device in devices" :key="device.id" :label="device.name" :value="device.id" /></el-select></el-form-item>
          <el-form-item label="监控指标" required><el-select v-model="form.metric" @change="metricChanged"><el-option v-for="(label, value) in metricLabels" :key="value" :label="label" :value="value" /></el-select></el-form-item>
          <el-form-item label="告警级别" required><el-select v-model="form.severity"><el-option label="提示" value="INFO" /><el-option label="警告" value="WARNING" /><el-option label="严重" value="CRITICAL" /></el-select></el-form-item>
        <el-form-item v-if="!presenceTargetMetrics.includes(form.metric)" label="触发阈值"><el-input-number v-model="form.threshold" :min="metricMin(form.metric)" :max="metricMax(form.metric)" :precision="metricPrecision(form.metric)" /><span class="field-suffix">{{ metricUnit(form.metric) }}</span></el-form-item>
        </div>
        <el-form-item v-if="targetMetrics.includes(form.metric)" label="目标名称" required><el-input v-model="form.targetName" maxlength="255" :placeholder="form.metric === 'PROCESS_MISSING' ? '例如：java 或 nginx' : form.metric === 'CUSTOM_METRIC' ? '例如：queue_depth' : '例如：nginx.service'" /><p class="field-help">进程或服务需要在 Agent 清单中采集；自定义监控项需要在 Agent 的 custom_metrics 中配置同名项目。</p></el-form-item>
        <el-form-item label="启用规则"><el-switch v-model="form.enabled" /></el-form-item>
      </el-form>
      <template #footer><el-button @click="dialog = false">取消</el-button><el-button type="primary" :loading="saving" @click="save">保存规则</el-button></template>
    </el-dialog>
  </section>
</template>
