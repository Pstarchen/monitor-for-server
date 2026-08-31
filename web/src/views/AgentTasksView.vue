<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { ClipboardList, Plus, RefreshCw, Terminal, XCircle } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import EmptyState from '@/components/EmptyState.vue'
import LoadingState from '@/components/LoadingState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { dateTime } from '@/lib/format'
import { useVisibilityPolling } from '@/lib/visibility-polling'
import { useAuthStore } from '@/stores/auth'
import type { AgentTask, AgentTaskOperation, AgentTaskStatus, Device } from '@/types'

const auth = useAuthStore()
const tasks = ref<AgentTask[]>([])
const devices = ref<Device[]>([])
const loading = ref(true)
const error = ref('')
const dialog = ref(false)
const saving = ref(false)
const selected = ref<AgentTask | null>(null)
const deviceFilter = ref('')
const statusFilter = ref<AgentTaskStatus | ''>('')
const form = reactive({ deviceId: '', command: '', args: '', timeoutSeconds: 30, maxOutputBytes: 65536 })

const operableDevices = computed(() => devices.value.filter((device) => auth.canRunTasks(device.id)))
const canOperate = computed(() => (auth.user?.role === 'ADMIN' || auth.user?.role === 'OPERATOR') && operableDevices.value.length > 0)
const canOperateTask = (task: AgentTask) => canOperate.value && auth.canRunTasks(task.deviceId)
const filtered = computed(() => tasks.value.filter((task) => (!deviceFilter.value || task.deviceId === deviceFilter.value) && (!statusFilter.value || task.status === statusFilter.value)))
const statusLabels: Record<AgentTaskStatus, string> = { QUEUED: '排队中', RUNNING: '执行中', SUCCEEDED: '成功', FAILED: '失败', TIMED_OUT: '超时', CANCELED: '已取消' }
const operationLabels: Record<AgentTaskOperation, string> = { COMMAND: '命令', FILE_LIST: '列目录', FILE_READ: '读文件', FILE_WRITE: '写文件', FILE_DELETE: '删文件' }

async function load() {
  error.value = ''
  try {
    const [taskResponse, deviceResponse] = await Promise.all([api.get<AgentTask[]>('/tasks', { params: { limit: 200 } }), api.get<Device[]>('/devices')])
    tasks.value = taskResponse.data
    devices.value = deviceResponse.data
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

function openCreate() {
  const selectedDevice = operableDevices.value.some((device) => device.id === deviceFilter.value)
    ? deviceFilter.value : operableDevices.value[0]?.id || ''
  Object.assign(form, { deviceId: selectedDevice, command: '', args: '', timeoutSeconds: 30, maxOutputBytes: 65536 })
  dialog.value = true
}

async function createTask() {
  if (!form.deviceId || !form.command.trim()) {
    ElMessage.warning('请选择设备并填写命令')
    return
  }
  saving.value = true
  try {
    await api.post('/tasks', { deviceId: form.deviceId, command: form.command.trim(), args: form.args.split(/\r?\n/).map((value) => value.trim()).filter(Boolean), timeoutSeconds: form.timeoutSeconds, maxOutputBytes: form.maxOutputBytes })
    dialog.value = false
    ElMessage.success('任务已加入队列')
    await load()
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    saving.value = false
  }
}

async function cancelTask(task: AgentTask) {
  try {
    await ElMessageBox.confirm(`确定取消“${task.command}”任务吗？`, '取消任务', { type: 'warning', confirmButtonText: '确认取消', cancelButtonText: '返回' })
    await api.post(`/tasks/${task.id}/cancel`)
    ElMessage.success('任务已取消')
    await load()
  } catch (cause) {
    if (cause !== 'cancel' && cause !== 'close') ElMessage.error(errorMessage(cause))
  }
}

function showTask(task: AgentTask) { selected.value = task }
onMounted(() => { load() })
useVisibilityPolling(() => load())
</script>

<template>
  <section>
    <PageHeader eyebrow="REMOTE OPERATIONS" title="任务执行" description="查看命令和受控文件任务。Agent 必须显式开启对应能力。">
      <template #actions><el-button @click="load"><RefreshCw :size="16" />刷新</el-button><el-button v-if="canOperate" type="primary" @click="openCreate"><Plus :size="16" />创建任务</el-button></template>
    </PageHeader>

    <div class="filter-bar"><el-select v-model="deviceFilter" clearable placeholder="全部设备" class="compact-select"><el-option v-for="device in devices" :key="device.id" :label="device.name" :value="device.id" /></el-select><el-select v-model="statusFilter" clearable placeholder="全部状态" class="compact-select"><el-option v-for="(label, value) in statusLabels" :key="value" :label="label" :value="value" /></el-select><span class="filter-count">{{ filtered.length }} / {{ tasks.length }} 个任务</span></div>

    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel"><EmptyState title="任务列表加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState></div>
    <article v-else class="panel"><div v-if="filtered.length" class="table-wrap"><table class="data-table"><thead><tr><th>任务</th><th>设备</th><th>状态</th><th>创建者</th><th>创建时间</th><th class="actions-column">操作</th></tr></thead><tbody><tr v-for="task in filtered" :key="task.id"><td><button class="device-link" type="button" @click="showTask(task)"><span><Terminal :size="17" /></span><span><strong>{{ operationLabels[task.operation] }} · {{ task.command }} {{ task.args.join(' ') }}</strong><small>#{{ task.id }} · 超时 {{ task.timeoutSeconds }} 秒</small></span></button></td><td>{{ task.deviceName }}</td><td><StatusBadge :status="task.status" /></td><td>{{ task.createdBy }}</td><td>{{ dateTime(task.createdAt) }}</td><td class="row-actions"><button v-if="canOperateTask(task) && ['QUEUED','RUNNING'].includes(task.status)" class="table-icon-button danger-command" type="button" title="取消任务" aria-label="取消任务" @click="cancelTask(task)"><XCircle :size="16" /></button></td></tr></tbody></table></div><EmptyState v-else title="暂无任务" description="创建任务后，Agent 会在下一次轮询时领取。"><el-button v-if="canOperate" type="primary" @click="openCreate"><Plus :size="16" />创建任务</el-button></EmptyState></article>

    <el-dialog :model-value="Boolean(selected)" title="任务详情" width="min(720px, calc(100vw - 28px))" @update:model-value="(value: boolean) => { if (!value) selected = null }"><div v-if="selected" class="detail-list"><dl><div><dt>命令</dt><dd class="mono-value">{{ selected.command }} {{ selected.args.join(' ') }}</dd></div><div><dt>状态</dt><dd>{{ statusLabels[selected.status] }}</dd></div><div><dt>退出码</dt><dd>{{ selected.exitCode ?? '--' }}</dd></div><div><dt>错误</dt><dd>{{ selected.error || '--' }}</dd></div></dl><div class="task-output"><h3>标准输出</h3><pre>{{ selected.stdout || '（无输出）' }}</pre><h3>标准错误</h3><pre>{{ selected.stderr || '（无输出）' }}</pre></div></div></el-dialog>

    <el-dialog v-model="dialog" title="创建命令任务" width="min(620px, calc(100vw - 28px))" destroy-on-close><el-form label-position="top" @submit.prevent="createTask"><el-form-item label="目标设备" required><el-select v-model="form.deviceId" filterable placeholder="选择设备"><el-option v-for="device in operableDevices" :key="device.id" :label="device.name" :value="device.id" /></el-select></el-form-item><el-form-item label="命令" required><el-input v-model="form.command" maxlength="128" placeholder="例如 uname 或 systemctl" /></el-form-item><el-form-item label="参数"><el-input v-model="form.args" type="textarea" :rows="4" placeholder="每行一个参数，不使用 shell 语法" /></el-form-item><div class="form-grid two-fields"><el-form-item label="超时（秒）"><el-input-number v-model="form.timeoutSeconds" :min="1" :max="300" /></el-form-item><el-form-item label="单路输出上限（字节）"><el-input-number v-model="form.maxOutputBytes" :min="1024" :max="1048576" :step="1024" /></el-form-item></div><div class="settings-notice" role="note"><ClipboardList :size="16" /><span>命令不会经过 Shell 解析；请只对可信设备启用 Agent 命令执行。</span></div><template #footer><el-button @click="dialog = false">取消</el-button><el-button type="primary" :loading="saving" @click="createTask">创建任务</el-button></template></el-form></el-dialog>
  </section>
</template>
