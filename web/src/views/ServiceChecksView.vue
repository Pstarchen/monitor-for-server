<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { Activity, Clock3, Globe2, Pencil, Plus, RefreshCw, Trash2, Wifi } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import EmptyState from '@/components/EmptyState.vue'
import LoadingState from '@/components/LoadingState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { dateTime } from '@/lib/format'
import { useVisibilityPolling } from '@/lib/visibility-polling'
import { useAuthStore } from '@/stores/auth'
import type { ServiceCheck, ServiceCheckResult, ServiceCheckType } from '@/types'

const auth = useAuthStore()
const checks = ref<ServiceCheck[]>([])
const loading = ref(true)
const error = ref('')
const dialog = ref(false)
const saving = ref(false)
const runningId = ref<number | null>(null)
const editingId = ref<number | null>(null)
const historyDialog = ref(false)
const historyLoading = ref(false)
const historyCheck = ref<ServiceCheck | null>(null)
const history = ref<ServiceCheckResult[]>([])
const form = reactive({ name: '', target: '', type: 'HTTP_GET' as ServiceCheckType, intervalSeconds: 60, timeoutMs: 5000, publicVisible: true, sortOrder: 0, enabled: true, failureThreshold: 1, latencyThresholdMs: 0, certificateThresholdDays: 14 })
const labels: Record<ServiceCheckType, string> = { HTTP_GET: 'HTTP GET', ICMP_PING: 'ICMP Ping', TCPING: 'TCPing' }
const canEdit = computed(() => auth.user?.role === 'ADMIN' || auth.user?.role === 'OPERATOR')

async function load(background = false) {
  if (!background) loading.value = true
  error.value = ''
  try {
    checks.value = (await api.get<ServiceCheck[]>('/services')).data
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

function openCreate() {
  editingId.value = null
  Object.assign(form, { name: '', target: '', type: 'HTTP_GET', intervalSeconds: 60, timeoutMs: 5000, publicVisible: true, sortOrder: 0, enabled: true, failureThreshold: 1, latencyThresholdMs: 0, certificateThresholdDays: 14 })
  dialog.value = true
}

function openEdit(check: ServiceCheck) {
  editingId.value = check.id
  Object.assign(form, { name: check.name, target: check.target, type: check.type, intervalSeconds: check.intervalSeconds, timeoutMs: check.timeoutMs, publicVisible: check.publicVisible, sortOrder: check.sortOrder, enabled: check.enabled, failureThreshold: check.failureThreshold, latencyThresholdMs: check.latencyThresholdMs, certificateThresholdDays: check.certificateThresholdDays })
  dialog.value = true
}

function targetPlaceholder() {
  if (form.type === 'ICMP_PING') return '例如：1.1.1.1 或 example.com'
  if (form.type === 'TCPING') return '例如：example.com:443'
  return '例如：https://example.com/health'
}

async function save() {
  if (!form.name.trim() || !form.target.trim()) {
    ElMessage.warning('请输入名称和目标')
    return
  }
  saving.value = true
  try {
    const payload = { ...form, name: form.name.trim(), target: form.target.trim() }
    if (editingId.value) await api.put(`/services/${editingId.value}`, payload)
    else await api.post('/services', payload)
    dialog.value = false
    ElMessage.success(editingId.value ? '服务监控已更新' : '服务监控已创建')
    await load()
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    saving.value = false
  }
}

async function runNow(check: ServiceCheck) {
  runningId.value = check.id
  try {
    const updated = (await api.post<ServiceCheck>(`/services/${check.id}/check`)).data
    const index = checks.value.findIndex((item) => item.id === check.id)
    if (index >= 0) checks.value[index] = updated
    ElMessage.success(updated.latest?.success ? `探测成功，延迟 ${updated.latest.latencyMs} ms` : '探测失败，已记录结果')
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    runningId.value = null
  }
}

async function remove(check: ServiceCheck) {
  try {
    await ElMessageBox.confirm(`删除“${check.name}”会同时删除该服务的探测结果。`, '删除服务监控', { type: 'warning', confirmButtonText: '确认删除', cancelButtonText: '取消' })
    await api.delete(`/services/${check.id}`)
    ElMessage.success('服务监控已删除')
    await load()
  } catch (cause) {
    if (cause !== 'cancel' && cause !== 'close') ElMessage.error(errorMessage(cause))
  }
}

async function openHistory(check: ServiceCheck) {
  historyCheck.value = check
  history.value = []
  historyDialog.value = true
  historyLoading.value = true
  try {
    const to = new Date()
    const from = new Date(to.getTime() - 31 * 24 * 3600_000)
    history.value = (await api.get<ServiceCheckResult[]>(`/services/${check.id}/history`, { params: { from: from.toISOString(), to: to.toISOString() } })).data
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    historyLoading.value = false
  }
}

onMounted(load)
useVisibilityPolling(() => load(true))
</script>

<template>
  <section>
    <PageHeader eyebrow="SERVICE MONITORING" title="服务监控" description="探测网站、端口与网络目标，并把最近一次可用性结果公开到状态页。">
      <template #actions><el-button @click="load"><RefreshCw :size="16" />刷新</el-button><el-button v-if="canEdit" type="primary" class="button-press" @click="openCreate"><Plus :size="16" />新建监控</el-button></template>
    </PageHeader>

    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel"><EmptyState title="服务监控加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState></div>
    <article v-else class="panel">
      <div v-if="checks.length" class="table-wrap"><table class="data-table"><thead><tr><th>监控</th><th>类型 / 目标</th><th>最近结果</th><th>间隔</th><th>公开</th><th>状态</th><th>更新时间</th><th class="actions-column">操作</th></tr></thead><tbody>
        <tr v-for="check in checks" :key="check.id">
          <td><div class="service-name-cell"><span><Globe2 :size="16" /></span><strong>{{ check.name }}</strong></div></td>
          <td><strong>{{ labels[check.type] }}</strong><small class="cell-subtext mono-value">{{ check.target }}</small></td>
          <td><template v-if="check.latest"><StatusBadge :status="check.latest.success ? 'ONLINE' : 'OFFLINE'" /><small class="cell-subtext">{{ check.latest.latencyMs }} ms{{ check.latest.statusCode ? ` · ${check.latest.statusCode}` : '' }}</small><small v-if="check.latest.certificateExpiresAt" class="cell-subtext">证书到期 {{ dateTime(check.latest.certificateExpiresAt) }}</small></template><span v-else class="muted-cell">尚未探测</span></td>
          <td>{{ check.intervalSeconds }} 秒<small class="cell-subtext">失败 {{ check.failureThreshold }} 次 / 延迟 {{ check.latencyThresholdMs ? `${check.latencyThresholdMs} ms` : '关闭' }} / 证书 {{ check.certificateThresholdDays ? `${check.certificateThresholdDays} 天` : '关闭' }}</small></td>
          <td><StatusBadge :status="check.publicVisible ? 'ONLINE' : 'OFFLINE'" /></td>
          <td><StatusBadge :status="check.enabled ? 'ONLINE' : 'OFFLINE'" /></td>
          <td>{{ dateTime(check.latest?.checkedAt || check.updatedAt) }}</td>
          <td class="row-actions"><button class="table-icon-button" type="button" title="查看历史" aria-label="查看历史" @click="openHistory(check)"><Clock3 :size="16" /></button><button v-if="canEdit" class="table-icon-button" type="button" title="立即探测" aria-label="立即探测" :disabled="runningId === check.id" @click="runNow(check)"><Activity :size="16" :class="{ spinning: runningId === check.id }" /></button><button v-if="canEdit" class="table-icon-button" type="button" title="编辑监控" aria-label="编辑监控" @click="openEdit(check)"><Pencil :size="16" /></button><button v-if="canEdit" class="table-icon-button danger-command" type="button" title="删除监控" aria-label="删除监控" @click="remove(check)"><Trash2 :size="16" /></button></td>
        </tr>
      </tbody></table></div>
      <EmptyState v-else title="暂无服务监控" description="添加一个 HTTP、Ping 或 TCP 目标，开始记录可用性和延迟。"><el-button v-if="canEdit" type="primary" @click="openCreate"><Plus :size="16" />新建监控</el-button></EmptyState>
    </article>

    <el-dialog v-model="dialog" :title="editingId ? '编辑服务监控' : '新建服务监控'" width="min(560px, calc(100vw - 28px))" destroy-on-close>
      <el-form label-position="top">
        <el-form-item label="监控名称" required><el-input v-model="form.name" maxlength="100" placeholder="例如：官网健康检查" /></el-form-item>
        <div class="form-grid two-fields">
          <el-form-item label="探测类型" required><el-select v-model="form.type"><el-option v-for="(label, value) in labels" :key="value" :label="label" :value="value" /></el-select></el-form-item>
          <el-form-item label="探测目标" required><el-input v-model="form.target" :placeholder="targetPlaceholder()" /></el-form-item>
          <el-form-item label="探测间隔"><el-input-number v-model="form.intervalSeconds" :min="15" :max="86400" /><span class="field-suffix">秒</span></el-form-item>
          <el-form-item label="超时时间"><el-input-number v-model="form.timeoutMs" :min="500" :max="30000" :step="500" /><span class="field-suffix">毫秒</span></el-form-item>
          <el-form-item label="排序权重"><el-input-number v-model="form.sortOrder" :min="-100000" :max="100000" /></el-form-item>
          <el-form-item label="连续失败告警"><el-input-number v-model="form.failureThreshold" :min="1" :max="20" /><span class="field-suffix">次</span></el-form-item>
          <el-form-item label="延迟告警阈值"><el-input-number v-model="form.latencyThresholdMs" :min="0" :max="30000" :step="100" /><span class="field-suffix">毫秒，0 为关闭</span></el-form-item>
          <el-form-item label="证书到期告警"><el-input-number v-model="form.certificateThresholdDays" :min="0" :max="3650" /><span class="field-suffix">天，0 为关闭</span></el-form-item>
        </div>
        <div class="form-inline-options"><el-checkbox v-model="form.publicVisible">在公开状态页展示</el-checkbox><el-checkbox v-model="form.enabled">启用自动探测</el-checkbox></div>
        <p class="form-help"><Wifi :size="14" />HTTPS 会记录证书到期时间；HTTP 会记录响应状态码；Ping 与 TCPing 会记录连接延迟。</p>
      </el-form>
      <template #footer><el-button @click="dialog = false">取消</el-button><el-button type="primary" :loading="saving" @click="save">保存监控</el-button></template>
    </el-dialog>
    <el-dialog v-model="historyDialog" :title="historyCheck ? `${historyCheck.name} · 最近 31 天历史` : '服务历史'" width="min(900px, calc(100vw - 28px))"><LoadingState v-if="historyLoading" /><div v-else-if="history.length" class="table-wrap"><table class="data-table"><thead><tr><th>时间</th><th>结果</th><th>延迟</th><th>状态码</th><th>证书到期</th><th>错误</th></tr></thead><tbody><tr v-for="item in [...history].reverse()" :key="item.checkedAt"><td>{{ dateTime(item.checkedAt) }}</td><td><StatusBadge :status="item.success ? 'ONLINE' : 'OFFLINE'" /></td><td>{{ item.latencyMs }} ms</td><td>{{ item.statusCode ?? '--' }}</td><td>{{ item.certificateExpiresAt ? dateTime(item.certificateExpiresAt) : '--' }}</td><td>{{ item.error || '--' }}</td></tr></tbody></table></div><EmptyState v-else title="暂无历史结果" description="服务执行探测后，结果会出现在这里。" /></el-dialog>
  </section>
</template>
