<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { Activity, CheckCircle2, Clock3, Copy, Pencil, Plus, RefreshCw, Trash2, Wifi, XCircle } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import EmptyState from '@/components/EmptyState.vue'
import LoadingState from '@/components/LoadingState.vue'
import ServiceAvailabilityCard from '@/components/ServiceAvailabilityCard.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import MetricChart from '@/components/MetricChart.vue'
import { api, errorMessage } from '@/lib/api'
import { dateTime } from '@/lib/format'
import { copyText } from '@/lib/clipboard'
import { useVisibilityPolling } from '@/lib/visibility-polling'
import { useAuthStore } from '@/stores/auth'
import type { ServiceCheck, ServiceCheckResult, ServiceCheckType } from '@/types'

const auth = useAuthStore()
const browserOrigin = window.location.origin
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
const heartbeatDialog = ref(false)
const heartbeatCredential = ref<ServiceCheck | null>(null)
const form = reactive({ name: '', target: '', type: 'HTTP_GET' as ServiceCheckType, intervalSeconds: 60, timeoutMs: 5000, publicVisible: true, sortOrder: 0, enabled: true, failureThreshold: 1, latencyThresholdMs: 0, certificateThresholdDays: 14, expectedStatus: null as number | null, bodyContains: '' })
const labels: Record<ServiceCheckType, string> = { HTTP_GET: 'HTTP GET', ICMP_PING: 'ICMP Ping', TCPING: 'TCPing', HEARTBEAT: '外部心跳' }
const canEdit = computed(() => auth.user?.role === 'ADMIN' || auth.user?.role === 'OPERATOR')
const historyLabels = computed(() => history.value.map((item) => new Intl.DateTimeFormat('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }).format(new Date(item.checkedAt))))
const historyLatencySeries = computed(() => [{ name: '响应延迟', data: history.value.map((item) => Math.max(0, Number(item.latencyMs) || 0)), color: '#2867a6' }])

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
  Object.assign(form, { name: '', target: '', type: 'HTTP_GET', intervalSeconds: 60, timeoutMs: 5000, publicVisible: true, sortOrder: 0, enabled: true, failureThreshold: 1, latencyThresholdMs: 0, certificateThresholdDays: 14, expectedStatus: null, bodyContains: '' })
  dialog.value = true
}

function openEdit(check: ServiceCheck) {
  editingId.value = check.id
  Object.assign(form, { name: check.name, target: check.target, type: check.type, intervalSeconds: check.intervalSeconds, timeoutMs: check.timeoutMs, publicVisible: check.publicVisible, sortOrder: check.sortOrder, enabled: check.enabled, failureThreshold: check.failureThreshold, latencyThresholdMs: check.latencyThresholdMs, certificateThresholdDays: check.certificateThresholdDays, expectedStatus: check.expectedStatus, bodyContains: check.bodyContains ?? '' })
  dialog.value = true
}

function targetPlaceholder() {
  if (form.type === 'ICMP_PING') return '例如：1.1.1.1 或 example.com'
  if (form.type === 'TCPING') return '例如：example.com:443'
  if (form.type === 'HEARTBEAT') return '创建后自动生成接入地址'
  return '例如：https://example.com/health'
}

async function save() {
  if (!form.name.trim() || (form.type !== 'HEARTBEAT' && !form.target.trim())) {
    ElMessage.warning(form.type === 'HEARTBEAT' ? '请输入监控名称' : '请输入名称和目标')
    return
  }
  saving.value = true
  try {
    const payload = { ...form, name: form.name.trim(), target: form.type === 'HEARTBEAT' ? '' : form.target.trim() }
    let saved: ServiceCheck
    if (editingId.value) saved = (await api.put<ServiceCheck>(`/services/${editingId.value}`, payload)).data
    else saved = (await api.post<ServiceCheck>('/services', payload)).data
    const wasEditing = editingId.value !== null
    dialog.value = false
    if (saved.type === 'HEARTBEAT' && saved.heartbeatToken) {
      heartbeatCredential.value = saved
      heartbeatDialog.value = true
    }
    ElMessage.success(wasEditing ? '服务监控已更新' : '服务监控已创建')
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

function heartbeatCommand(check: ServiceCheck) {
  if (!check.heartbeatPath || !check.heartbeatToken) return ''
  return `curl -fsS -X POST -H 'X-Heartbeat-Token: ${check.heartbeatToken}' '${browserOrigin}${check.heartbeatPath}'`
}

async function copyHeartbeatCommand() {
  const check = heartbeatCredential.value
  if (!check) return
  try {
    await copyText(heartbeatCommand(check))
    ElMessage.success('心跳命令已复制')
  } catch {
    ElMessage.warning('浏览器禁止自动复制，请手动复制命令')
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
    <PageHeader eyebrow="SERVICE MONITORING" title="服务监控" description="探测网站、端口与网络目标；达到失败、延迟或证书阈值时，会通过已启用的通知通道发送告警。">
      <template #actions><el-button @click="load"><RefreshCw :size="16" />刷新</el-button><el-button v-if="canEdit" type="primary" class="button-press" @click="openCreate"><Plus :size="16" />新建监控</el-button></template>
    </PageHeader>

    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel"><EmptyState title="服务监控加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState></div>
    <div v-else-if="checks.length" class="service-availability-grid">
      <ServiceAvailabilityCard v-for="check in checks" :key="check.id" :name="check.name" :type-label="labels[check.type]" :subtitle="check.type === 'HEARTBEAT' ? `外部任务 · 令牌 ${check.heartbeatTokenPrefix ?? '已配置'}...` : check.target" :latest="check.latest" :history="check.history" :availability-percent="check.availabilityPercent" :latency-threshold-ms="check.latencyThresholdMs" :refresh-interval-seconds="check.intervalSeconds">
        <template #actions>
          <span class="availability-actions">
            <button class="table-icon-button" type="button" title="查看历史" aria-label="查看历史" @click="openHistory(check)"><Clock3 :size="15" /></button>
            <button v-if="canEdit && check.type !== 'HEARTBEAT'" class="table-icon-button" type="button" title="立即探测" aria-label="立即探测" :disabled="runningId === check.id" @click="runNow(check)"><Activity :size="15" :class="{ spinning: runningId === check.id }" /></button>
            <button v-if="canEdit" class="table-icon-button" type="button" title="编辑监控" aria-label="编辑监控" @click="openEdit(check)"><Pencil :size="15" /></button>
            <button v-if="canEdit" class="table-icon-button danger-command" type="button" title="删除监控" aria-label="删除监控" @click="remove(check)"><Trash2 :size="15" /></button>
          </span>
        </template>
        <template #details>
          <span class="availability-detail"><Clock3 :size="12" />每 {{ check.intervalSeconds }} 秒</span>
          <span class="availability-detail" :data-state="check.publicVisible ? 'success' : 'empty'"><CheckCircle2 v-if="check.publicVisible" :size="12" /><XCircle v-else :size="12" />{{ check.publicVisible ? '公开展示' : '仅控制台' }}</span>
          <span class="availability-detail" :data-state="check.enabled ? 'success' : 'warning'"><CheckCircle2 v-if="check.enabled" :size="12" /><XCircle v-else :size="12" />{{ check.enabled ? '自动探测中' : '已暂停' }}</span>
          <span class="availability-detail">失败 {{ check.failureThreshold }} 次</span>
          <span v-if="check.latencyThresholdMs" class="availability-detail">延迟 ≥ {{ check.latencyThresholdMs }} ms</span>
          <span v-if="check.expectedStatus" class="availability-detail">状态码 = {{ check.expectedStatus }}</span>
          <span v-if="check.bodyContains" class="availability-detail">包含 “{{ check.bodyContains }}”</span>
          <span v-if="check.type === 'HEARTBEAT'" class="availability-detail">超时判定为 {{ Math.max(30, check.intervalSeconds * 2) }} 秒</span>
        </template>
      </ServiceAvailabilityCard>
    </div>
    <article v-else class="panel"><EmptyState title="暂无服务监控" description="添加一个 HTTP、Ping 或 TCP 目标，开始记录可用性和延迟。"><el-button v-if="canEdit" type="primary" @click="openCreate"><Plus :size="16" />新建监控</el-button></EmptyState></article>

    <el-dialog v-model="dialog" :title="editingId ? '编辑服务监控' : '新建服务监控'" width="min(560px, calc(100vw - 28px))" destroy-on-close>
      <el-form label-position="top">
        <el-form-item label="监控名称" required><el-input v-model="form.name" maxlength="100" placeholder="例如：官网健康检查" /></el-form-item>
        <div class="form-grid two-fields">
          <el-form-item label="探测类型" required><el-select v-model="form.type"><el-option v-for="(label, value) in labels" :key="value" :label="label" :value="value" /></el-select></el-form-item>
          <el-form-item v-if="form.type !== 'HEARTBEAT'" label="探测目标" required><el-input v-model="form.target" :placeholder="targetPlaceholder()" /></el-form-item>
          <el-form-item v-else label="心跳接入"><div class="form-help"><Activity :size="14" />保存后生成一次性令牌，将命令配置到 cron、CI 或定时任务中。</div></el-form-item>
          <el-form-item label="探测间隔"><el-input-number v-model="form.intervalSeconds" :min="15" :max="86400" /><span class="field-suffix">秒</span></el-form-item>
          <el-form-item label="超时时间"><el-input-number v-model="form.timeoutMs" :min="500" :max="30000" :step="500" /><span class="field-suffix">毫秒</span></el-form-item>
          <el-form-item label="排序权重"><el-input-number v-model="form.sortOrder" :min="-100000" :max="100000" /></el-form-item>
          <el-form-item label="连续失败告警"><el-input-number v-model="form.failureThreshold" :min="1" :max="20" /><span class="field-suffix">次</span></el-form-item>
          <el-form-item label="延迟告警阈值"><el-input-number v-model="form.latencyThresholdMs" :min="0" :max="30000" :step="100" /><span class="field-suffix">毫秒，0 为关闭</span></el-form-item>
          <el-form-item label="证书到期告警"><el-input-number v-model="form.certificateThresholdDays" :min="0" :max="3650" /><span class="field-suffix">天，0 为关闭</span></el-form-item>
          <template v-if="form.type === 'HTTP_GET'">
            <el-form-item label="期望状态码"><el-input-number v-model="form.expectedStatus" :min="100" :max="599" :step="1" controls-position="right" /><span class="field-suffix">留空表示接受 2xx/3xx</span></el-form-item>
            <el-form-item label="响应体包含"><el-input v-model="form.bodyContains" maxlength="200" placeholder="例如：status:ok" /><span class="field-suffix">可选，区分大小写</span></el-form-item>
          </template>
        </div>
        <div class="form-inline-options"><el-checkbox v-model="form.publicVisible">在公开状态页展示</el-checkbox><el-checkbox v-model="form.enabled">启用自动探测</el-checkbox></div>
        <p class="form-help"><Wifi :size="14" />HTTPS 会记录证书到期时间；HTTP 会记录响应状态码；Ping 与 TCPing 会记录连接延迟；外部心跳用于 cron、CI 等任务的存活监控。告警会在首次达到阈值时发送，恢复后再发送一条恢复通知。</p>
      </el-form>
      <template #footer><el-button @click="dialog = false">取消</el-button><el-button type="primary" :loading="saving" @click="save">保存监控</el-button></template>
    </el-dialog>
    <el-dialog v-model="heartbeatDialog" title="外部心跳接入" width="min(680px, calc(100vw - 28px))" :close-on-click-modal="false" destroy-on-close>
      <div v-if="heartbeatCredential" class="credential-panel">
        <div class="credential-warning"><Activity :size="18" /><p><strong>令牌仅显示这一次</strong><span>请将命令加入 cron、CI 或其他定时任务，建议每 {{ heartbeatCredential.intervalSeconds }} 秒执行一次。</span></p></div>
        <dl><div><dt>心跳地址</dt><dd>{{ browserOrigin }}{{ heartbeatCredential.heartbeatPath }}</dd></div><div><dt>令牌</dt><dd>{{ heartbeatCredential.heartbeatToken }}</dd></div></dl>
        <div class="install-command"><Activity :size="16" /><code>{{ heartbeatCommand(heartbeatCredential) }}</code><button type="button" title="复制心跳命令" aria-label="复制心跳命令" @click="copyHeartbeatCommand"><Copy :size="15" /></button></div>
      </div>
      <template #footer><el-button @click="heartbeatDialog = false">完成</el-button><el-button type="primary" @click="copyHeartbeatCommand"><Copy :size="16" />复制命令</el-button></template>
    </el-dialog>
    <el-dialog v-model="historyDialog" :title="historyCheck ? `${historyCheck.name} · 最近 31 天历史` : '服务历史'" width="min(900px, calc(100vw - 28px))"><LoadingState v-if="historyLoading" /><template v-else-if="history.length"><div class="history-chart-panel"><div class="panel-head"><div><h2>响应延迟趋势</h2><p>按探测时间展示最近 {{ history.length }} 条记录</p></div><Clock3 :size="17" /></div><MetricChart :labels="historyLabels" :series="historyLatencySeries" unit="ms" :aria-label="`${historyCheck?.name ?? '服务'}响应延迟趋势`" /></div><div class="table-wrap"><table class="data-table"><thead><tr><th>时间</th><th>结果</th><th>延迟</th><th>状态码</th><th>证书到期</th><th>错误</th></tr></thead><tbody><tr v-for="item in [...history].reverse()" :key="item.checkedAt"><td>{{ dateTime(item.checkedAt) }}</td><td><StatusBadge :status="item.success ? 'ONLINE' : 'OFFLINE'" /></td><td>{{ item.latencyMs }} ms</td><td>{{ item.statusCode ?? '--' }}</td><td>{{ item.certificateExpiresAt ? dateTime(item.certificateExpiresAt) : '--' }}</td><td>{{ item.error || '--' }}</td></tr></tbody></table></div></template><EmptyState v-else title="暂无历史结果" description="服务执行探测后，结果会出现在这里。" /></el-dialog>
  </section>
</template>
