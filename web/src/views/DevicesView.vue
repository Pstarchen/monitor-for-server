<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import { Copy, KeyRound, Pencil, Plus, RefreshCw, Search, Server, Trash2 } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { percent, relativeTime } from '@/lib/format'
import { useAuthStore } from '@/stores/auth'
import type { Device, DeviceCredential, DeviceStatus } from '@/types'

const router = useRouter()
const auth = useAuthStore()
const devices = ref<Device[]>([])
const loading = ref(true)
const error = ref('')
const search = ref('')
const status = ref<DeviceStatus | ''>('')
const dialog = ref(false)
const saving = ref(false)
const editingId = ref<string | null>(null)
const credential = ref<DeviceCredential | null>(null)
const form = reactive({ name: '', location: '', groupName: '', primaryIp: '' })
let refreshTimer = 0

const canEdit = computed(() => auth.user?.role === 'ADMIN' || auth.user?.role === 'OPERATOR')
const filtered = computed(() => {
  const needle = search.value.trim().toLowerCase()
  return devices.value.filter((device) => (!status.value || device.status === status.value)
    && (!needle || [device.name, device.hostname, device.primaryIp, device.location, device.groupName].some((value) => value?.toLowerCase().includes(needle))))
})

async function load(background = false) {
  if (!background) loading.value = true
  error.value = ''
  try {
    devices.value = (await api.get<Device[]>('/devices')).data
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

function openCreate() {
  editingId.value = null
  Object.assign(form, { name: '', location: '', groupName: '', primaryIp: '' })
  dialog.value = true
}

function openEdit(device: Device) {
  editingId.value = device.id
  Object.assign(form, { name: device.name, location: device.location ?? '', groupName: device.groupName ?? '', primaryIp: device.primaryIp ?? '' })
  dialog.value = true
}

async function save() {
  if (!form.name.trim()) {
    ElMessage.warning('请输入设备名称')
    return
  }
  saving.value = true
  try {
    const payload = { name: form.name.trim(), location: form.location.trim() || null, groupName: form.groupName.trim() || null, primaryIp: form.primaryIp.trim() || null }
    if (editingId.value) {
      await api.put(`/devices/${editingId.value}`, payload)
      ElMessage.success('设备信息已更新')
    } else {
      credential.value = (await api.post<DeviceCredential>('/devices', payload)).data
    }
    dialog.value = false
    await load(true)
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    saving.value = false
  }
}

async function rotateKey(device: Device) {
  try {
    await ElMessageBox.confirm(`轮换后，设备“${device.name}”使用的旧密钥会立即失效。`, '轮换 Agent 密钥', { type: 'warning', confirmButtonText: '确认轮换', cancelButtonText: '取消' })
    credential.value = (await api.post<DeviceCredential>(`/devices/${device.id}/rotate-key`)).data
    await load(true)
  } catch (cause) {
    if (cause !== 'cancel' && cause !== 'close') ElMessage.error(errorMessage(cause))
  }
}

async function remove(device: Device) {
  try {
    await ElMessageBox.confirm(`删除“${device.name}”会同时移除关联监控数据和告警。`, '删除设备', { type: 'warning', confirmButtonText: '确认删除', cancelButtonText: '取消' })
    await api.delete(`/devices/${device.id}`)
    ElMessage.success('设备已删除')
    await load(true)
  } catch (cause) {
    if (cause !== 'cancel' && cause !== 'close') ElMessage.error(errorMessage(cause))
  }
}

async function copyKey() {
  if (!credential.value) return
  try {
    await navigator.clipboard.writeText(credential.value.agentKey)
    ElMessage.success('密钥已复制')
  } catch {
    ElMessage.error('复制失败，请手动选择密钥')
  }
}

function scheduleRefresh() {
  window.clearTimeout(refreshTimer)
  refreshTimer = window.setTimeout(() => load(true), 400)
}

onMounted(() => {
  load()
  window.addEventListener('guanlan:realtime', scheduleRefresh)
})
onBeforeUnmount(() => {
  window.clearTimeout(refreshTimer)
  window.removeEventListener('guanlan:realtime', scheduleRefresh)
})
</script>

<template>
  <section>
    <PageHeader eyebrow="INFRASTRUCTURE" title="设备管理" description="登记监控节点、配置归属信息并管理 Agent 接入凭据。">
      <template #actions>
        <el-button @click="load(true)"><RefreshCw :size="16" />刷新</el-button>
        <el-button v-if="canEdit" class="button-press" type="primary" @click="openCreate"><Plus :size="16" />添加设备</el-button>
      </template>
    </PageHeader>

    <div class="filter-bar">
      <el-input v-model="search" clearable class="search-input" placeholder="搜索名称、地址或分组"><template #prefix><Search :size="15" /></template></el-input>
      <el-select v-model="status" clearable placeholder="全部状态" class="compact-select">
        <el-option label="在线" value="ONLINE" /><el-option label="离线" value="OFFLINE" /><el-option label="待接入" value="PENDING" />
      </el-select>
      <span class="filter-count">{{ filtered.length }} / {{ devices.length }} 台设备</span>
    </div>

    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel"><EmptyState title="设备列表加载失败" :description="error"><el-button @click="load()">重新加载</el-button></EmptyState></div>
    <article v-else class="panel">
      <div v-if="filtered.length" class="table-wrap">
        <table class="data-table device-table">
          <thead><tr><th>设备</th><th>状态</th><th>分组 / 位置</th><th>CPU</th><th>内存</th><th>最近上报</th><th class="actions-column">操作</th></tr></thead>
          <tbody>
            <tr v-for="device in filtered" :key="device.id">
              <td><button class="device-link" type="button" @click="router.push(`/devices/${device.id}`)"><span><Server :size="17" /></span><span><strong>{{ device.name }}</strong><small>{{ device.primaryIp || device.hostname || '等待 Agent 上报地址' }}</small></span></button></td>
              <td><StatusBadge :status="device.status" /></td>
              <td><strong class="plain-cell">{{ device.groupName || '未分组' }}</strong><small class="cell-subtext">{{ device.location || '未设置位置' }}</small></td>
              <td>{{ device.latest ? percent(device.latest.cpuUsage) : '--' }}</td>
              <td>{{ device.latest ? percent(device.latest.memoryUsage) : '--' }}</td>
              <td>{{ relativeTime(device.lastSeenAt) }}</td>
              <td class="row-actions">
                <button v-if="canEdit" class="table-icon-button" type="button" title="编辑设备" aria-label="编辑设备" @click="openEdit(device)"><Pencil :size="16" /></button>
                <button v-if="auth.user?.role === 'ADMIN'" class="table-icon-button" type="button" title="轮换密钥" aria-label="轮换密钥" @click="rotateKey(device)"><KeyRound :size="16" /></button>
                <button v-if="auth.user?.role === 'ADMIN'" class="table-icon-button danger-command" type="button" title="删除设备" aria-label="删除设备" @click="remove(device)"><Trash2 :size="16" /></button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <EmptyState v-else title="没有匹配的设备" description="调整筛选条件，或添加第一台需要监控的服务器。">
        <el-button v-if="canEdit && !devices.length" type="primary" @click="openCreate"><Plus :size="16" />添加设备</el-button>
      </EmptyState>
    </article>

    <el-dialog v-model="dialog" :title="editingId ? '编辑设备' : '添加设备'" width="min(520px, calc(100vw - 28px))" destroy-on-close>
      <el-form label-position="top" @submit.prevent="save">
        <div class="form-grid two-fields">
          <el-form-item label="设备名称" required><el-input v-model="form.name" maxlength="100" placeholder="例如：生产环境 API-01" /></el-form-item>
          <el-form-item label="主 IP"><el-input v-model="form.primaryIp" maxlength="64" placeholder="可由 Agent 上报后补充" /></el-form-item>
          <el-form-item label="设备分组"><el-input v-model="form.groupName" maxlength="80" placeholder="例如：生产环境" /></el-form-item>
          <el-form-item label="物理位置"><el-input v-model="form.location" maxlength="120" placeholder="例如：上海机房 A3" /></el-form-item>
        </div>
      </el-form>
      <template #footer><el-button @click="dialog = false">取消</el-button><el-button type="primary" :loading="saving" @click="save">{{ editingId ? '保存修改' : '创建设备' }}</el-button></template>
    </el-dialog>

    <el-dialog :model-value="Boolean(credential)" title="保存 Agent 接入凭据" width="min(580px, calc(100vw - 28px))" :close-on-click-modal="false" @update:model-value="(value: boolean) => { if (!value) credential = null }">
      <div v-if="credential" class="credential-panel">
        <div class="credential-warning"><KeyRound :size="18" /><p><strong>密钥仅显示这一次</strong><span>关闭窗口后无法再次查看。请立即写入目标服务器的 Agent 配置。</span></p></div>
        <dl><div><dt>设备 ID</dt><dd>{{ credential.device.id }}</dd></div><div><dt>Agent 密钥</dt><dd>{{ credential.agentKey }}</dd></div></dl>
      </div>
      <template #footer><el-button @click="credential = null">我已保存</el-button><el-button type="primary" @click="copyKey"><Copy :size="16" />复制密钥</el-button></template>
    </el-dialog>
  </section>
</template>
