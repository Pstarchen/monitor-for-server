<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import { Copy, Download, KeyRound, Pencil, Plus, RefreshCw, Search, Server, Terminal, Trash2 } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { buildAgentInstallCommand, type AgentInstallSource } from '@/lib/agent-install'
import { copyText } from '@/lib/clipboard'
import { downloadCsv } from '@/lib/csv'
import { percent, relativeTime } from '@/lib/format'
import { useVisibilityPolling } from '@/lib/visibility-polling'
import { useAuthStore } from '@/stores/auth'
import type { AgentBootstrap, Device, DeviceCredential, DeviceHealthState, DeviceStatus, DdnsConfig } from '@/types'

const router = useRouter()
const route = useRoute()
const auth = useAuthStore()
const devices = ref<Device[]>([])
const ddnsConfigs = ref<DdnsConfig[]>([])
const loading = ref(true)
const error = ref('')
const search = ref('')
const status = ref<DeviceStatus | ''>('')
const tag = ref('')
const group = ref('')
const environment = ref('')
const healthState = ref<DeviceHealthState | ''>('')
const dialog = ref(false)
const saving = ref(false)
const editingId = ref<string | null>(null)
const credential = ref<DeviceCredential | null>(null)
const credentialPlatform = ref<'linux' | 'windows'>('linux')
const agentInstallSource = ref<AgentInstallSource>('controller')
const agentServerUrl = ref(window.location.origin)
const collectionSeconds = ref(3)
const lightweight = ref(false)
const collectAllProcesses = ref(false)
const processCollectionLimit = ref(64)
const diskMountpoints = ref('')
const form = reactive({ name: '', location: '', groupName: '', primaryIp: '', tags: [] as string[], assetTag: '', ownerName: '', vendor: '', model: '', serialNumber: '', environment: '', purchaseDate: '', warrantyExpiresAt: '', description: '', ddnsEnabled: false, ddnsConfigId: null as number | null, publicVisible: true })
const agentInstallSourceOptions: Array<{ label: string; value: AgentInstallSource }> = [
  { label: '总控直连', value: 'controller' },
  { label: 'Gitee 镜像', value: 'gitee' },
]
const agentKeyElement = ref<HTMLElement | null>(null)
const installCommandElement = ref<HTMLElement | null>(null)
let refreshTimer = 0

const canEdit = computed(() => auth.user?.role === 'ADMIN' || auth.user?.role === 'OPERATOR')
const knownTags = computed(() => Array.from(new Set(devices.value.flatMap((device) => device.tags ?? []))).sort((left, right) => left.localeCompare(right, 'zh-CN')))
const knownGroups = computed(() => Array.from(new Set(devices.value.map((device) => device.groupName).filter((value): value is string => Boolean(value)))).sort((left, right) => left.localeCompare(right, 'zh-CN')))
const knownEnvironments = computed(() => Array.from(new Set(devices.value.map((device) => device.environment).filter((value): value is string => Boolean(value)))).sort((left, right) => left.localeCompare(right, 'zh-CN')))
const environmentLabels: Record<string, string> = { production: '生产', staging: '预发布', testing: '测试', development: '开发', 'disaster-recovery': '灾备' }
const healthLabels: Record<DeviceHealthState, string> = { HEALTHY: '健康', DEGRADED: '数据延迟', OFFLINE: 'Agent 离线', PENDING: '待接入' }
const filtered = computed(() => {
  const needle = search.value.trim().toLowerCase()
  return devices.value.filter((device) => (!status.value || device.status === status.value)
    && (!tag.value || (device.tags ?? []).includes(tag.value))
    && (!group.value || device.groupName === group.value)
    && (!environment.value || device.environment === environment.value)
    && (!healthState.value || device.health?.state === healthState.value)
    && (!needle || [device.name, device.hostname, device.primaryIp, device.location, device.groupName, device.assetTag, device.ownerName, device.vendor, device.model, device.serialNumber, device.environment, ...(device.tags ?? [])].some((value) => value?.toLowerCase().includes(needle))))
})

function exportInventory() {
  if (!filtered.value.length) {
    ElMessage.info('当前筛选没有可导出的设备')
    return
  }
  const headers = ['设备名称', '状态', '健康', '分组', '环境', '主机名', '主 IP', '操作系统', '架构', 'CPU 使用率', '内存使用率', '磁盘使用率', '最近上报', '资产编号', '责任人', '供应商', '型号', '序列号']
  const rows = filtered.value.map((device) => [
    device.name,
    device.status === 'ONLINE' ? '在线' : device.status === 'OFFLINE' ? '离线' : '待接入',
    healthLabels[device.health?.state ?? 'PENDING'],
    device.groupName ?? '',
    device.environment ? (environmentLabels[device.environment] ?? device.environment) : '',
    device.hostname ?? '',
    device.primaryIp ?? '',
    device.os ?? '',
    device.architecture ?? '',
    device.latest ? `${device.latest.cpuUsage.toFixed(2)}%` : '',
    device.latest ? `${device.latest.memoryUsage.toFixed(2)}%` : '',
    device.latest ? `${device.latest.diskUsage.toFixed(2)}%` : '',
    device.lastSeenAt ?? '',
    device.assetTag ?? '',
    device.ownerName ?? '',
    device.vendor ?? '',
    device.model ?? '',
    device.serialNumber ?? '',
  ])
  downloadCsv(`guanlan-devices-${new Date().toISOString().slice(0, 10)}.csv`, headers, rows)
  ElMessage.success(`已导出 ${rows.length} 台设备`)
}
const installCommand = computed(() => {
  if (!credential.value) return ''
  const url = agentServerHost(agentServerUrl.value)
  const disks = diskMountpoints.value.split(/[\n,]/).map((value) => value.trim()).filter(Boolean)
  return buildAgentInstallCommand({
    platform: credentialPlatform.value,
    source: agentInstallSource.value,
    serverUrl: url,
    deviceId: credential.value.device.id,
    agentKey: credential.value.agentKey,
    collectionSeconds: collectionSeconds.value,
    diskMountpoints: disks,
    lightweight: lightweight.value,
    collectAllProcesses: collectAllProcesses.value,
    processCollectionLimit: processCollectionLimit.value,
  })
})

async function load(background = false) {
  if (!background) loading.value = true
  error.value = ''
  try {
    const [deviceResponse, ddnsResponse] = await Promise.all([api.get<Device[]>('/devices'), api.get<DdnsConfig[]>('/ddns')])
    devices.value = deviceResponse.data
    ddnsConfigs.value = ddnsResponse.data
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
  agentInstallSource.value = 'controller'
  lightweight.value = false
  collectAllProcesses.value = false
  processCollectionLimit.value = 64
  diskMountpoints.value = ''
}

function openCreate() {
  editingId.value = null
  Object.assign(form, { name: '', location: '', groupName: '', primaryIp: '', tags: [], assetTag: '', ownerName: '', vendor: '', model: '', serialNumber: '', environment: '', purchaseDate: '', warrantyExpiresAt: '', description: '', ddnsEnabled: false, ddnsConfigId: null, publicVisible: true })
  dialog.value = true
}

function openEdit(device: Device) {
  if (!auth.canManageDevice(device.id)) return
  editingId.value = device.id
  Object.assign(form, { name: device.name, location: device.location ?? '', groupName: device.groupName ?? '', primaryIp: device.primaryIp ?? '', tags: [...(device.tags ?? [])], assetTag: device.assetTag ?? '', ownerName: device.ownerName ?? '', vendor: device.vendor ?? '', model: device.model ?? '', serialNumber: device.serialNumber ?? '', environment: device.environment ?? '', purchaseDate: device.purchaseDate ?? '', warrantyExpiresAt: device.warrantyExpiresAt ?? '', description: device.description ?? '', ddnsEnabled: device.ddnsEnabled, ddnsConfigId: device.ddnsConfigId, publicVisible: device.publicVisible })
  dialog.value = true
}

async function save() {
  if (!form.name.trim()) {
    ElMessage.warning('请输入设备名称')
    return
  }
  saving.value = true
  try {
    const payload = { name: form.name.trim(), location: form.location.trim() || null, groupName: form.groupName.trim() || null, primaryIp: form.primaryIp.trim() || null, tags: form.tags.map((tag) => tag.trim()).filter(Boolean), assetTag: form.assetTag.trim() || null, ownerName: form.ownerName.trim() || null, vendor: form.vendor.trim() || null, model: form.model.trim() || null, serialNumber: form.serialNumber.trim() || null, environment: form.environment || null, purchaseDate: form.purchaseDate || null, warrantyExpiresAt: form.warrantyExpiresAt || null, description: form.description.trim() || null, ddnsEnabled: form.ddnsEnabled, ddnsConfigId: form.ddnsEnabled ? form.ddnsConfigId : null, publicVisible: form.publicVisible }
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

function agentServerHost(value: string) {
  const raw = value.trim().replace(/\/+$/, '')
  if (!raw) return ''
  try {
    const parsed = new URL(raw.includes('://') ? raw : `https://${raw}`)
    return parsed.origin
  } catch {
    return raw
  }
}

function scheduleRefresh() {
  window.clearTimeout(refreshTimer)
  refreshTimer = window.setTimeout(() => load(true), 400)
}

onMounted(() => {
  load().then(() => {
    const requestedId = typeof route.query.edit === 'string' ? route.query.edit : ''
    const requested = devices.value.find((device) => device.id === requestedId)
    if (requested && auth.canManageDevice(requested.id)) openEdit(requested)
    const discoveredAddress = typeof route.query.add === 'string' ? route.query.add : ''
    if (discoveredAddress && !requested) {
      openCreate()
      form.primaryIp = discoveredAddress
      form.name = `发现设备 ${discoveredAddress}`
      void router.replace({ query: { ...route.query, add: undefined } })
    }
  })
  loadAgentBootstrap()
  window.addEventListener('guanlan:realtime', scheduleRefresh)
})
watch(() => route.query.edit, (value) => {
  const requested = devices.value.find((device) => device.id === value)
  if (requested && auth.canManageDevice(requested.id)) openEdit(requested)
})
useVisibilityPolling(() => load(true))
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
        <el-button :disabled="!filtered.length" title="导出当前筛选结果" @click="exportInventory"><Download :size="16" />导出清单</el-button>
        <el-button v-if="canEdit" class="button-press" type="primary" @click="openCreate"><Plus :size="16" />添加设备</el-button>
      </template>
    </PageHeader>

    <div class="filter-bar">
      <el-input v-model="search" clearable class="search-input" placeholder="搜索名称、地址或分组"><template #prefix><Search :size="15" /></template></el-input>
      <el-select v-model="status" clearable placeholder="全部状态" class="compact-select">
        <el-option label="在线" value="ONLINE" /><el-option label="离线" value="OFFLINE" /><el-option label="待接入" value="PENDING" />
      </el-select>
      <el-select v-model="tag" clearable placeholder="全部标签" class="compact-select">
        <el-option v-for="item in knownTags" :key="item" :label="item" :value="item" />
      </el-select>
      <el-select v-model="group" clearable placeholder="全部分组" class="compact-select">
        <el-option v-for="item in knownGroups" :key="item" :label="item" :value="item" />
      </el-select>
      <el-select v-model="environment" clearable placeholder="全部环境" class="compact-select">
        <el-option v-for="item in knownEnvironments" :key="item" :label="environmentLabels[item] ?? item" :value="item" />
      </el-select>
      <el-select v-model="healthState" clearable placeholder="全部健康状态" class="compact-select">
        <el-option v-for="(label, value) in healthLabels" :key="value" :label="label" :value="value" />
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
              <td><button class="device-link" type="button" @click="router.push(`/devices/${device.id}`)"><span><Server :size="17" /></span><span><strong>{{ device.name }}</strong><small>{{ device.primaryIp || device.hostname || '等待 Agent 上报地址' }}</small><small v-if="device.assetTag || device.ownerName">{{ device.assetTag || '未编资产号' }} · {{ device.ownerName || '未指定责任人' }}</small></span></button></td>
              <td class="device-health-cell"><StatusBadge :status="device.status" /><small class="device-health-detail" :data-state="device.health.state">{{ device.health.reason }}</small></td>
              <td><strong class="plain-cell">{{ device.groupName || '未分组' }}</strong><small class="cell-subtext">{{ device.location || '未设置位置' }}</small><span v-if="device.tags?.length" class="tag-list"><em v-for="tag in device.tags" :key="tag">{{ tag }}</em></span></td>
              <td>{{ device.latest ? percent(device.latest.cpuUsage) : '--' }}</td>
              <td>{{ device.latest ? percent(device.latest.memoryUsage) : '--' }}</td>
              <td>{{ relativeTime(device.lastSeenAt) }}</td>
              <td class="row-actions">
                <button v-if="canEdit && auth.canManageDevice(device.id)" class="table-icon-button" type="button" title="编辑设备" aria-label="编辑设备" @click="openEdit(device)"><Pencil :size="16" /></button>
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

    <el-dialog v-model="dialog" :title="editingId ? '编辑设备' : '添加设备'" width="min(720px, calc(100vw - 28px))" destroy-on-close>
      <el-form label-position="top" @submit.prevent="save">
        <div class="form-grid two-fields">
          <el-form-item label="设备名称" required><el-input v-model="form.name" maxlength="100" placeholder="例如：生产环境 API-01" /></el-form-item>
          <el-form-item label="主 IP"><el-input v-model="form.primaryIp" maxlength="64" placeholder="可由 Agent 上报后补充" /></el-form-item>
          <el-form-item label="设备分组"><el-input v-model="form.groupName" maxlength="80" placeholder="例如：生产环境" /></el-form-item>
          <el-form-item label="物理位置"><el-input v-model="form.location" maxlength="120" placeholder="例如：上海机房 A3" /></el-form-item>
          <el-form-item label="设备标签"><el-select v-model="form.tags" multiple filterable allow-create default-first-option collapse-tags collapse-tags-tooltip placeholder="例如：生产、核心、华东"><el-option v-for="tag in knownTags" :key="tag" :label="tag" :value="tag" /></el-select><p class="field-help">可添加最多 20 个标签，用于搜索与总览筛选。</p></el-form-item>
          <el-form-item label="资产编号"><el-input v-model="form.assetTag" maxlength="80" placeholder="例如：SRV-2025-001" /></el-form-item>
          <el-form-item label="责任人"><el-input v-model="form.ownerName" maxlength="100" placeholder="例如：运维一组 / 张三" /></el-form-item>
          <el-form-item label="供应商"><el-input v-model="form.vendor" maxlength="100" placeholder="例如：Dell、华为云" /></el-form-item>
          <el-form-item label="型号"><el-input v-model="form.model" maxlength="120" placeholder="例如：PowerEdge R760" /></el-form-item>
          <el-form-item label="序列号"><el-input v-model="form.serialNumber" maxlength="120" /></el-form-item>
          <el-form-item label="环境"><el-select v-model="form.environment" clearable placeholder="选择环境"><el-option label="生产" value="production" /><el-option label="预发布" value="staging" /><el-option label="测试" value="testing" /><el-option label="开发" value="development" /><el-option label="灾备" value="disaster-recovery" /></el-select></el-form-item>
          <el-form-item label="采购日期"><el-date-picker v-model="form.purchaseDate" type="date" value-format="YYYY-MM-DD" placeholder="选择日期" /></el-form-item>
          <el-form-item label="保修到期"><el-date-picker v-model="form.warrantyExpiresAt" type="date" value-format="YYYY-MM-DD" placeholder="选择日期" /></el-form-item>
          <el-form-item class="form-span-two" label="资产说明"><el-input v-model="form.description" type="textarea" :rows="2" maxlength="500" show-word-limit placeholder="记录用途、机柜位置或交接信息" /></el-form-item>
          <el-form-item label="DDNS 配置"><el-checkbox v-model="form.ddnsEnabled">启用动态域名解析</el-checkbox><el-select v-if="form.ddnsEnabled" v-model="form.ddnsConfigId" clearable placeholder="选择 DDNS 配置"><el-option v-for="config in ddnsConfigs" :key="config.id" :label="config.name" :value="config.id" /></el-select></el-form-item>
          <el-form-item label="公开状态页"><el-checkbox v-model="form.publicVisible">在公开状态页展示此设备</el-checkbox></el-form-item>
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
            <el-form-item label="安装源">
              <el-segmented v-model="agentInstallSource" :options="agentInstallSourceOptions" />
              <p class="field-help">{{ agentInstallSource === 'controller' ? '从当前总控直接下载安装器，目标服务器无需访问代码托管平台。' : '适用于访问 GitHub 困难的中国大陆服务器。' }}</p>
            </el-form-item>
            <div class="form-grid two-fields">
              <el-form-item label="采集周期"><el-select v-model="collectionSeconds"><el-option v-for="value in [1, 3, 10, 30, 60]" :key="value" :label="`${value} 秒`" :value="value" /></el-select></el-form-item>
              <el-form-item label="磁盘白名单"><el-input v-model="diskMountpoints" placeholder="例如：/, /data" /></el-form-item>
            </div>
            <div class="agent-option-list">
              <el-checkbox v-model="lightweight">轻量采集（跳过进程与 TCP 连接统计）</el-checkbox>
              <el-checkbox v-model="collectAllProcesses" :disabled="lightweight">采集完整进程清单（最多 256 个）</el-checkbox>
              <el-input-number v-if="collectAllProcesses && !lightweight" v-model="processCollectionLimit" :min="32" :max="256" :step="16" controls-position="right" aria-label="进程采集上限" />
            </div>
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
