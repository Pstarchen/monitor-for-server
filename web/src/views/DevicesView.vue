<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import { Copy, KeyRound, Pencil, Plus, RefreshCw, Search, Server, Terminal, Trash2 } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { copyText } from '@/lib/clipboard'
import { percent, relativeTime } from '@/lib/format'
import { useAuthStore } from '@/stores/auth'
import type { AgentBootstrap, Device, DeviceCredential, DeviceStatus } from '@/types'

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
const credentialPlatform = ref<'linux' | 'windows'>('linux')
const agentServerUrl = ref(window.location.origin)
const collectionSeconds = ref(3)
const lightweight = ref(false)
const diskMountpoints = ref('')
const form = reactive({ name: '', location: '', groupName: '', primaryIp: '' })
const agentInstallerRawUrl = 'https://raw.githubusercontent.com/Pstarchen/monitor-for-server/main/deploy/install-agent'
const agentInstallerCacheKey = 'v4'
const agentKeyElement = ref<HTMLElement | null>(null)
const installCommandElement = ref<HTMLElement | null>(null)
let refreshTimer = 0

const canEdit = computed(() => auth.user?.role === 'ADMIN' || auth.user?.role === 'OPERATOR')
const filtered = computed(() => {
  const needle = search.value.trim().toLowerCase()
  return devices.value.filter((device) => (!status.value || device.status === status.value)
    && (!needle || [device.name, device.hostname, device.primaryIp, device.location, device.groupName].some((value) => value?.toLowerCase().includes(needle))))
})
const installCommand = computed(() => {
  if (!credential.value) return ''
  const url = agentServerHost(agentServerUrl.value)
  const disks = diskMountpoints.value.split(/[\n,]/).map((value) => value.trim()).filter(Boolean)
  if (credentialPlatform.value === 'windows') {
    const diskArgs = disks.map((value) => ` -DiskMountpoint '${powerShellQuote(value)}'`).join('')
    const lightArgs = lightweight.value ? ' -SkipProcesses -SkipConnections' : ''
    return `$env:GUANLAN_AGENT_KEY = '${powerShellQuote(credential.value.agentKey)}'\n` +
      `$installer = Join-Path $env:TEMP 'guanlan-install-agent.ps1'; Invoke-WebRequest -UseBasicParsing '${agentInstallerRawUrl}.ps1?${agentInstallerCacheKey}' -OutFile $installer; & powershell -ExecutionPolicy Bypass -File $installer -ServerUrl '${powerShellQuote(url)}' -DeviceId '${powerShellQuote(credential.value.device.id)}' -Interval '${collectionSeconds.value}s'${diskArgs}${lightArgs}; Remove-Item $installer -Force`
  }
  const diskArgs = disks.map((value) => ` --disk '${shellQuote(value)}'`).join('')
  const lightArgs = lightweight.value ? ' --skip-processes --skip-connections' : ''
  return `export GUANLAN_AGENT_KEY='${shellQuote(credential.value.agentKey)}'\n` +
    `curl -fsSL '${agentInstallerRawUrl}.sh?${agentInstallerCacheKey}' | sudo --preserve-env=GUANLAN_AGENT_KEY bash -s -- --server-url '${shellQuote(url)}' --device-id '${shellQuote(credential.value.device.id)}' --interval '${collectionSeconds.value}s'${diskArgs}${lightArgs}`
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

async function loadAgentBootstrap() {
  try {
    const data = (await api.get<AgentBootstrap>('/settings/agent-bootstrap', { params: { _agentBootstrap: Date.now() } })).data
    if (data.publicBaseUrl) agentServerUrl.value = data.publicBaseUrl
    if ([1, 3, 10, 30, 60].includes(data.defaultCollectionSeconds)) collectionSeconds.value = data.defaultCollectionSeconds
  } catch {
    // Viewers cannot create credentials; operators still fall back to the current origin on older servers.
  }
}

function showCredential(value: DeviceCredential) {
  credential.value = value
  credentialPlatform.value = 'linux'
  lightweight.value = false
  diskMountpoints.value = ''
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
      showCredential((await api.post<DeviceCredential>('/devices', payload)).data)
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
    showCredential((await api.post<DeviceCredential>(`/devices/${device.id}/rotate-key`)).data)
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
    await copyText(credential.value.agentKey)
    ElMessage.success('密钥已复制')
  } catch {
    selectText(agentKeyElement.value)
    ElMessage.warning('浏览器禁止自动复制，密钥已选中，请按 Ctrl+C')
  }
}

async function copyInstallCommand() {
  try {
    await copyText(installCommand.value)
    ElMessage.success('安装命令已复制')
  } catch {
    selectText(installCommandElement.value)
    ElMessage.warning('浏览器禁止自动复制，命令已选中，请按 Ctrl+C')
  }
}

function selectText(element: HTMLElement | null) {
  if (!element) return
  const selection = window.getSelection()
  if (!selection) return
  const range = document.createRange()
  range.selectNodeContents(element)
  selection.removeAllRanges()
  selection.addRange(range)
}

function shellQuote(value: string) {
  return value.split("'").join("'\"'\"'")
}

function powerShellQuote(value: string) {
  return value.split("'").join("''")
}

function agentServerHost(value: string) {
  const raw = value.trim().replace(/\/+$/, '')
  if (!raw) return ''
  try {
    const parsed = new URL(raw.includes('://') ? raw : `https://${raw}`)
    return parsed.host
  } catch {
    return raw.replace(/^https?:\/\//i, '').replace(/\/+$/, '')
  }
}

function scheduleRefresh() {
  window.clearTimeout(refreshTimer)
  refreshTimer = window.setTimeout(() => load(true), 400)
}

onMounted(() => {
  load()
  loadAgentBootstrap()
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
                <button v-if="auth.user?.role === 'ADMIN' && !device.controllerManaged" class="table-icon-button" type="button" title="轮换密钥" aria-label="轮换密钥" @click="rotateKey(device)"><KeyRound :size="16" /></button>
                <button v-if="auth.user?.role === 'ADMIN' && !device.controllerManaged" class="table-icon-button danger-command" type="button" title="删除设备" aria-label="删除设备" @click="remove(device)"><Trash2 :size="16" /></button>
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

    <el-dialog :model-value="Boolean(credential)" title="Agent 接入" width="min(720px, calc(100vw - 28px))" :close-on-click-modal="false" @update:model-value="(value: boolean) => { if (!value) credential = null }">
      <div v-if="credential" class="credential-panel">
        <div class="credential-warning"><KeyRound :size="18" /><p><strong>密钥仅显示这一次</strong><span>关闭窗口后无法再次查看。请立即写入目标服务器的 Agent 配置。</span></p></div>
        <dl><div><dt>设备 ID</dt><dd>{{ credential.device.id }}</dd></div><div><dt>Agent 密钥</dt><dd ref="agentKeyElement">{{ credential.agentKey }}</dd></div></dl>
        <div class="agent-install-options">
          <el-form label-position="top">
            <el-form-item label="监控平台域名或地址"><el-input v-model="agentServerUrl" /></el-form-item>
            <div class="form-grid two-fields">
              <el-form-item label="采集周期"><el-select v-model="collectionSeconds"><el-option v-for="value in [1, 3, 10, 30, 60]" :key="value" :label="`${value} 秒`" :value="value" /></el-select></el-form-item>
              <el-form-item label="磁盘白名单"><el-input v-model="diskMountpoints" placeholder="例如：/, /data" /></el-form-item>
            </div>
            <el-checkbox v-model="lightweight">轻量采集（跳过进程与 TCP 连接统计）</el-checkbox>
          </el-form>
        </div>
        <el-tabs v-model="credentialPlatform" class="install-tabs">
          <el-tab-pane label="Linux" name="linux" /><el-tab-pane label="Windows" name="windows" />
        </el-tabs>
        <div class="install-command"><Terminal :size="16" /><code ref="installCommandElement">{{ installCommand }}</code><button type="button" title="复制安装命令" aria-label="复制安装命令" @click="copyInstallCommand"><Copy :size="15" /></button></div>
      </div>
      <template #footer><el-button @click="credential = null">完成</el-button><el-button @click="copyKey"><KeyRound :size="16" />复制密钥</el-button><el-button type="primary" @click="copyInstallCommand"><Copy :size="16" />复制安装命令</el-button></template>
    </el-dialog>
  </section>
</template>
