<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import {
  AlertTriangle, ChevronRight, CirclePause, CirclePlay, Clock3, PackageCheck,
  Plus, RefreshCw, RotateCcw, Search, ShieldCheck, X, XCircle,
} from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import EmptyState from '@/components/EmptyState.vue'
import LoadingState from '@/components/LoadingState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import {
  availableRolloutActions, isStableAgentVersion, rolloutMemberStatusLabels,
  rolloutProgress, rolloutStatusLabels,
} from '@/lib/agent-rollout'
import type { AgentRolloutAction } from '@/lib/agent-rollout'
import { dateTime } from '@/lib/format'
import { useVisibilityPolling } from '@/lib/visibility-polling'
import { useAuthStore } from '@/stores/auth'
import type {
  AgentRollout, AgentRolloutMemberStatus, AgentRolloutStatus, Device, MaintenanceWindow,
} from '@/types'

const auth = useAuthStore()
const rollouts = ref<AgentRollout[]>([])
const devices = ref<Device[]>([])
const maintenanceWindows = ref<MaintenanceWindow[]>([])
const loading = ref(true)
const refreshing = ref(false)
const error = ref('')
const backgroundError = ref('')
const createDialog = ref(false)
const saving = ref(false)
const selected = ref<AgentRollout | null>(null)
const detailLoading = ref(false)
const actionBusy = ref('')
const search = ref('')
const statusFilter = ref<AgentRolloutStatus | ''>('')
const memberStatusFilter = ref<AgentRolloutMemberStatus | ''>('')

const form = reactive({
  targetVersion: '',
  deviceIds: [] as string[],
  maintenanceWindowId: null as number | null,
  canaryPercent: 10,
  ringCount: 3,
  maxConcurrent: 5,
  jitterSeconds: 30,
  failureThreshold: 20,
  verificationTimeoutSeconds: 600,
})

const canManage = computed(() => auth.user?.role === 'ADMIN')
const eligibleDevices = computed(() => devices.value.filter((device) => Boolean(device.agentVersion) && !device.controllerManaged))
const unavailableDeviceCount = computed(() => devices.value.length - eligibleDevices.value.length)
const enabledMaintenanceWindows = computed(() => maintenanceWindows.value.filter((window) => window.enabled))
const maintenanceWindowNames = computed(() => new Map(maintenanceWindows.value.map((window) => [window.id, window.name])))
const selectedActions = computed(() => selected.value ? availableRolloutActions(selected.value) : [])
const filteredMembers = computed(() => {
  if (!selected.value) return []
  return selected.value.members.filter((member) => !memberStatusFilter.value || member.status === memberStatusFilter.value)
})

const filteredRollouts = computed(() => {
  const needle = search.value.trim().toLowerCase()
  return rollouts.value.filter((rollout) => {
    if (statusFilter.value && rollout.status !== statusFilter.value) return false
    if (!needle) return true
    return [
      `#${rollout.id}`,
      rollout.targetVersion,
      rollout.createdBy,
      rollout.statusReason ?? '',
      ...rollout.members.map((member) => member.deviceName),
    ].some((value) => value.toLowerCase().includes(needle))
  })
})

const summary = computed(() => {
  const active = rollouts.value.filter((rollout) => ['RUNNING', 'ROLLING_BACK'].includes(rollout.status)).length
  const paused = rollouts.value.filter((rollout) => rollout.status === 'PAUSED').length
  const devices = rollouts.value.reduce((total, rollout) => total + rollout.members.length, 0)
  const failed = rollouts.value.reduce((total, rollout) => total + rolloutProgress(rollout).failed, 0)
  return { active, paused, devices, failed }
})

const actionMeta: Record<AgentRolloutAction, { label: string; completed: string }> = {
  start: { label: '启动发布', completed: '发布已启动' },
  pause: { label: '暂停', completed: '发布已暂停' },
  resume: { label: '继续', completed: '发布已恢复' },
  cancel: { label: '取消', completed: '发布已取消' },
  rollback: { label: '批量回滚', completed: '回滚已启动' },
}

async function load(background = false) {
  if (background) refreshing.value = true
  else loading.value = true
  try {
    const [rolloutResponse, deviceResponse, maintenanceResponse] = await Promise.all([
      api.get<AgentRollout[]>('/agent-rollouts', { params: { limit: 100 } }),
      api.get<Device[]>('/devices'),
      api.get<MaintenanceWindow[]>('/maintenance-windows'),
    ])
    rollouts.value = rolloutResponse.data
    devices.value = deviceResponse.data
    maintenanceWindows.value = maintenanceResponse.data
    syncSelected()
    error.value = ''
    backgroundError.value = ''
  } catch (cause) {
    const message = errorMessage(cause)
    if (background && rollouts.value.length) backgroundError.value = message
    else error.value = message
  } finally {
    loading.value = false
    refreshing.value = false
  }
}

async function refreshRollouts() {
  refreshing.value = true
  try {
    rollouts.value = (await api.get<AgentRollout[]>('/agent-rollouts', { params: { limit: 100 } })).data
    syncSelected()
    backgroundError.value = ''
  } catch (cause) {
    backgroundError.value = errorMessage(cause)
  } finally {
    refreshing.value = false
  }
}

function syncSelected() {
  if (!selected.value) return
  selected.value = rollouts.value.find((rollout) => rollout.id === selected.value?.id) ?? selected.value
}

function mergeRollout(updated: AgentRollout) {
  const index = rollouts.value.findIndex((rollout) => rollout.id === updated.id)
  if (index === -1) rollouts.value.unshift(updated)
  else rollouts.value.splice(index, 1, updated)
  if (selected.value?.id === updated.id) selected.value = updated
}

function openCreate() {
  Object.assign(form, {
    targetVersion: '',
    deviceIds: [],
    maintenanceWindowId: null,
    canaryPercent: 10,
    ringCount: 3,
    maxConcurrent: 5,
    jitterSeconds: 30,
    failureThreshold: 20,
    verificationTimeoutSeconds: 600,
  })
  createDialog.value = true
}

async function createRollout() {
  if (!isStableAgentVersion(form.targetVersion)) {
    ElMessage.warning('目标版本必须是稳定版本，例如 v1.20.15')
    return
  }
  if (!form.deviceIds.length) {
    ElMessage.warning('请至少选择一台 Agent 设备')
    return
  }
  saving.value = true
  try {
    const created = (await api.post<AgentRollout>('/agent-rollouts', {
      targetVersion: form.targetVersion.trim(),
      deviceIds: form.deviceIds,
      maintenanceWindowId: form.maintenanceWindowId,
      canaryPercent: form.canaryPercent,
      ringCount: form.ringCount,
      maxConcurrent: form.maxConcurrent,
      jitterSeconds: form.jitterSeconds,
      failureThreshold: form.failureThreshold,
      verificationTimeoutSeconds: form.verificationTimeoutSeconds,
    })).data
    mergeRollout(created)
    selected.value = created
    createDialog.value = false
    ElMessage.success('发布草稿已创建')
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    saving.value = false
  }
}

async function showRollout(rollout: AgentRollout) {
  selected.value = rollout
  memberStatusFilter.value = ''
  detailLoading.value = true
  try {
    mergeRollout((await api.get<AgentRollout>(`/agent-rollouts/${rollout.id}`)).data)
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    detailLoading.value = false
  }
}

async function runAction(rollout: AgentRollout, action: AgentRolloutAction) {
  const meta = actionMeta[action]
  let reason: string | null = null
  try {
    if (action === 'start') {
      await ElMessageBox.confirm(
        `启动 #${rollout.id} 后，将按批次向 ${rollout.members.length} 台 Agent 下发 ${rollout.targetVersion}。`,
        '启动 Agent 发布',
        { type: 'warning', confirmButtonText: '确认启动', cancelButtonText: '返回检查' },
      )
    } else {
      const result = await ElMessageBox.prompt(
        action === 'rollback'
          ? `将把已更新设备恢复到各自发布前版本。请输入操作原因（可选）。`
          : `请输入${meta.label}原因（可选）。`,
        meta.label,
        {
          type: action === 'rollback' || action === 'cancel' ? 'warning' : 'info',
          confirmButtonText: `确认${meta.label}`,
          cancelButtonText: '返回',
          inputPlaceholder: '最多 500 个字符',
          inputValidator: (value: string) => value.length <= 500 || '操作原因不能超过 500 个字符',
        },
      ) as { value: string }
      reason = result.value.trim() || null
    }
    actionBusy.value = `${rollout.id}:${action}`
    const updated = (await api.post<AgentRollout>(
      `/agent-rollouts/${rollout.id}/${action}`,
      action === 'start' ? undefined : { reason },
    )).data
    mergeRollout(updated)
    ElMessage.success(meta.completed)
  } catch (cause) {
    if (cause !== 'cancel' && cause !== 'close') ElMessage.error(errorMessage(cause))
  } finally {
    actionBusy.value = ''
  }
}

function ringText(rollout: AgentRollout) {
  if (rollout.currentRing < 0) return `未开始 / ${rollout.ringCount} 批`
  return `第 ${Math.min(rollout.currentRing + 1, rollout.ringCount)} / ${rollout.ringCount} 批`
}

function maintenanceWindowText(rollout: AgentRollout) {
  if (!rollout.maintenanceWindowId) return '不限制维护窗口'
  return maintenanceWindowNames.value.get(rollout.maintenanceWindowId) ?? `维护窗口 #${rollout.maintenanceWindowId}`
}

function secondsText(value: number) {
  if (value >= 3600 && value % 3600 === 0) return `${value / 3600} 小时`
  if (value >= 60 && value % 60 === 0) return `${value / 60} 分钟`
  return `${value} 秒`
}

function deviceOptionLabel(device: Device) {
  const online = device.status === 'ONLINE' ? '在线' : device.status === 'OFFLINE' ? '离线' : '待接入'
  return `${device.name} · ${device.agentVersion} · ${online}`
}

onMounted(() => { void load() })
useVisibilityPolling(() => refreshRollouts(), 8_000)
</script>

<template>
  <section>
    <PageHeader eyebrow="CONTROLLED DELIVERY" title="Agent 发布" description="以实时版本上报确认升级结果，并按灰度批次、并发上限和失败阈值控制影响范围。">
      <template #actions>
        <el-button :loading="refreshing" @click="load(true)"><RefreshCw :size="16" />刷新</el-button>
        <el-button v-if="canManage" type="primary" :disabled="!eligibleDevices.length" @click="openCreate"><Plus :size="16" />新建发布</el-button>
      </template>
    </PageHeader>

    <div v-if="!canManage" class="rollout-permission" role="status">
      <ShieldCheck :size="17" />
      <span>当前账号可查看发布进度；创建、控制和回滚仅限管理员。</span>
    </div>

    <div class="rollout-summary" aria-label="Agent 发布概览">
      <div><span>进行中</span><strong>{{ summary.active }}</strong></div>
      <div><span>已暂停</span><strong>{{ summary.paused }}</strong></div>
      <div><span>纳入设备</span><strong>{{ summary.devices }}</strong></div>
      <div :data-alert="summary.failed > 0"><span>当前失败</span><strong>{{ summary.failed }}</strong></div>
    </div>

    <div class="filter-bar rollout-filter-bar">
      <el-input v-model="search" clearable class="rollout-search" placeholder="搜索版本、设备或发布编号">
        <template #prefix><Search :size="15" /></template>
      </el-input>
      <el-select v-model="statusFilter" clearable class="compact-select" placeholder="全部状态">
        <el-option v-for="(label, value) in rolloutStatusLabels" :key="value" :label="label" :value="value" />
      </el-select>
      <span class="filter-count">{{ filteredRollouts.length }} / {{ rollouts.length }} 个发布</span>
      <span v-if="backgroundError" class="rollout-refresh-error" role="alert"><AlertTriangle :size="14" />数据刷新失败</span>
    </div>

    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel">
      <EmptyState title="发布列表加载失败" :description="error"><el-button @click="load()">重新加载</el-button></EmptyState>
    </div>
    <article v-else class="panel rollout-list-panel">
      <div v-if="filteredRollouts.length" class="table-wrap">
        <table class="data-table rollout-table">
          <thead><tr><th>目标版本</th><th>状态</th><th>进度</th><th>当前批次</th><th>发布策略</th><th>创建时间</th><th class="actions-column">详情</th></tr></thead>
          <tbody>
            <tr v-for="rollout in filteredRollouts" :key="rollout.id">
              <td>
                <button class="rollout-release" type="button" @click="showRollout(rollout)">
                  <span><PackageCheck :size="17" /></span>
                  <span><strong>{{ rollout.targetVersion }}</strong><small>#{{ rollout.id }} · {{ rollout.members.length }} 台设备</small></span>
                </button>
              </td>
              <td><StatusBadge :status="rollout.status" :label="rolloutStatusLabels[rollout.status]" /></td>
              <td>
                <div class="rollout-progress-cell">
                  <div><span>{{ rolloutProgress(rollout).confirmed }} 已确认</span><strong>{{ rolloutProgress(rollout).percent }}%</strong></div>
                  <el-progress :percentage="rolloutProgress(rollout).percent" :stroke-width="6" :show-text="false" />
                  <small v-if="rolloutProgress(rollout).failed">{{ rolloutProgress(rollout).failed }} 台失败</small>
                </div>
              </td>
              <td>{{ ringText(rollout) }}</td>
              <td><strong>{{ rollout.canaryPercent }}% 灰度</strong><small class="table-secondary-text">并发 {{ rollout.maxConcurrent }} · 阈值 {{ rollout.failureThreshold }}%</small></td>
              <td>{{ dateTime(rollout.createdAt) }}<small class="table-secondary-text">{{ rollout.createdBy }}</small></td>
              <td class="row-actions"><button class="rollout-open-button" type="button" title="查看发布详情" aria-label="查看发布详情" @click="showRollout(rollout)"><ChevronRight :size="18" /></button></td>
            </tr>
          </tbody>
        </table>
      </div>
      <EmptyState v-else :title="rollouts.length ? '没有匹配的发布' : '暂无 Agent 发布'" :description="rollouts.length ? '调整筛选条件后重试。' : '创建发布草稿后，可先检查批次和目标设备再启动。'">
        <el-button v-if="canManage && !rollouts.length && eligibleDevices.length" type="primary" @click="openCreate"><Plus :size="16" />新建发布</el-button>
      </EmptyState>
    </article>

    <el-drawer
      :model-value="Boolean(selected)"
      size="min(760px, 100vw)"
      class="rollout-detail-drawer"
      :with-header="false"
      aria-labelledby="rollout-detail-title"
      @update:model-value="(value: boolean) => { if (!value) selected = null }"
    >
      <template v-if="selected">
        <header class="rollout-detail-head">
          <div>
            <span>Agent 发布 #{{ selected.id }}</span>
            <h2 id="rollout-detail-title">{{ selected.targetVersion }}</h2>
          </div>
          <div class="rollout-detail-head-actions">
            <StatusBadge :status="selected.status" :label="rolloutStatusLabels[selected.status]" />
            <button class="rollout-detail-close" type="button" title="关闭发布详情" aria-label="关闭发布详情" @click="selected = null"><X :size="19" /></button>
          </div>
        </header>

        <div v-if="selected.statusReason" class="rollout-reason" :data-error="['FAILED', 'PAUSED'].includes(selected.status)">
          <AlertTriangle :size="16" /><span>{{ selected.statusReason }}</span>
        </div>

        <div v-if="canManage && selectedActions.length" class="rollout-actions" aria-label="发布操作">
          <el-button
            v-for="action in selectedActions"
            :key="action"
            :type="action === 'start' || action === 'resume' ? 'primary' : action === 'rollback' || action === 'cancel' ? 'danger' : 'default'"
            :plain="action !== 'start' && action !== 'resume'"
            :loading="actionBusy === `${selected.id}:${action}`"
            :disabled="Boolean(actionBusy)"
            @click="runAction(selected, action)"
          >
            <CirclePlay v-if="action === 'start' || action === 'resume'" :size="16" />
            <CirclePause v-else-if="action === 'pause'" :size="16" />
            <RotateCcw v-else-if="action === 'rollback'" :size="16" />
            <XCircle v-else :size="16" />
            {{ actionMeta[action].label }}
          </el-button>
        </div>

        <section class="rollout-detail-section rollout-overview-section">
          <div class="rollout-detail-grid">
            <div><span>确认进度</span><strong>{{ rolloutProgress(selected).confirmed }} / {{ rolloutProgress(selected).total }}</strong></div>
            <div><span>当前批次</span><strong>{{ ringText(selected) }}</strong></div>
            <div><span>失败设备</span><strong :data-error="rolloutProgress(selected).failed > 0">{{ rolloutProgress(selected).failed }}</strong></div>
            <div><span>处理中</span><strong>{{ rolloutProgress(selected).active }}</strong></div>
          </div>
          <el-progress :percentage="rolloutProgress(selected).percent" :stroke-width="8" />
        </section>

        <section class="rollout-detail-section">
          <h3>调度策略</h3>
          <dl class="rollout-definition-list">
            <div><dt>维护窗口</dt><dd>{{ maintenanceWindowText(selected) }}</dd></div>
            <div><dt>灰度与批次</dt><dd>{{ selected.canaryPercent }}% · {{ selected.ringCount }} 批</dd></div>
            <div><dt>并发与抖动</dt><dd>{{ selected.maxConcurrent }} 台 · {{ secondsText(selected.jitterSeconds) }}</dd></div>
            <div><dt>失败暂停阈值</dt><dd>{{ selected.failureThreshold }}%</dd></div>
            <div><dt>版本确认超时</dt><dd>{{ secondsText(selected.verificationTimeoutSeconds) }}</dd></div>
            <div><dt>创建信息</dt><dd>{{ selected.createdBy }} · {{ dateTime(selected.createdAt) }}</dd></div>
          </dl>
        </section>

        <section class="rollout-detail-section">
          <div class="rollout-member-heading">
            <div><h3>设备明细</h3><p>任务被接受后，仍需等待 Agent 实时上报目标版本。</p></div>
            <el-select v-model="memberStatusFilter" clearable class="member-status-filter" placeholder="全部状态">
              <el-option v-for="(label, value) in rolloutMemberStatusLabels" :key="value" :label="label" :value="value" />
            </el-select>
          </div>
          <div v-if="detailLoading" class="rollout-detail-loading"><span class="spinner" />正在刷新详情</div>
          <div v-else-if="filteredMembers.length" class="table-wrap rollout-member-table-wrap">
            <table class="data-table rollout-member-table">
              <thead><tr><th>设备</th><th>批次</th><th>状态</th><th>任务</th><th>时间</th></tr></thead>
              <tbody>
                <tr v-for="member in filteredMembers" :key="member.id">
                  <td><RouterLink class="rollout-device-link" :to="`/devices/${member.deviceId}`">{{ member.deviceName }}</RouterLink><small class="table-secondary-text">{{ member.previousVersion }} → {{ selected.targetVersion }}</small></td>
                  <td>第 {{ member.ring + 1 }} 批<small class="table-secondary-text">序号 {{ member.order + 1 }}</small></td>
                  <td><StatusBadge :status="member.status" :label="rolloutMemberStatusLabels[member.status]" /><small v-if="member.error" class="rollout-member-error" :title="member.error">{{ member.error }}</small></td>
                  <td>{{ member.taskId ? `#${member.taskId}` : '--' }}<small class="table-secondary-text">尝试 {{ member.attempt }} 次</small></td>
                  <td>{{ member.confirmedAt ? dateTime(member.confirmedAt) : member.queuedAt ? dateTime(member.queuedAt) : '--' }}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <EmptyState v-else title="没有匹配的设备" description="调整状态筛选后重试。" />
        </section>
      </template>
    </el-drawer>

    <el-dialog v-model="createDialog" title="新建 Agent 发布" width="min(720px, calc(100vw - 28px))" destroy-on-close>
      <el-form label-position="top" @submit.prevent="createRollout">
        <div class="rollout-create-intro"><PackageCheck :size="18" /><span>发布先保存为草稿，启动后才会向 Agent 下发固定格式的更新任务。</span></div>
        <el-form-item label="目标版本" required>
          <el-input v-model="form.targetVersion" maxlength="32" placeholder="v1.20.15" />
        </el-form-item>
        <el-form-item label="目标设备" required>
          <el-select v-model="form.deviceIds" multiple filterable collapse-tags :max-collapse-tags="3" placeholder="选择已上报版本的 Agent">
            <el-option v-for="device in eligibleDevices" :key="device.id" :label="deviceOptionLabel(device)" :value="device.id" />
          </el-select>
          <small v-if="unavailableDeviceCount" class="rollout-form-hint">{{ unavailableDeviceCount }} 台设备因未上报版本或由 Controller 管理而不可选。</small>
        </el-form-item>
        <el-form-item label="维护窗口">
          <el-select v-model="form.maintenanceWindowId" clearable placeholder="不限制维护窗口">
            <el-option v-for="window in enabledMaintenanceWindows" :key="window.id" :label="window.name" :value="window.id" />
          </el-select>
        </el-form-item>
        <div class="rollout-form-divider"><span>灰度与并发</span></div>
        <div class="rollout-form-grid">
          <el-form-item label="首批灰度（%）"><el-input-number v-model="form.canaryPercent" :min="0" :max="100" /></el-form-item>
          <el-form-item label="发布批次"><el-input-number v-model="form.ringCount" :min="1" :max="20" /></el-form-item>
          <el-form-item label="最大并发"><el-input-number v-model="form.maxConcurrent" :min="1" :max="100" /></el-form-item>
          <el-form-item label="最大抖动（秒）"><el-input-number v-model="form.jitterSeconds" :min="0" :max="86400" /></el-form-item>
          <el-form-item label="失败暂停阈值（%）"><el-input-number v-model="form.failureThreshold" :min="1" :max="100" /></el-form-item>
          <el-form-item label="版本确认超时（秒）"><el-input-number v-model="form.verificationTimeoutSeconds" :min="30" :max="86400" /></el-form-item>
        </div>
        <div class="rollout-create-note" role="note"><Clock3 :size="16" /><span>更新任务退出成功不等于升级完成；目标版本必须由任务下发后的实时上报确认。</span></div>
      </el-form>
      <template #footer><el-button @click="createDialog = false">取消</el-button><el-button type="primary" :loading="saving" @click="createRollout">创建草稿</el-button></template>
    </el-dialog>
  </section>
</template>

<style scoped>
.rollout-permission {
  min-height: 42px;
  display: flex;
  align-items: center;
  gap: 9px;
  margin-bottom: 16px;
  padding: 9px 12px;
  border: 1px solid var(--border);
  border-radius: 6px;
  color: var(--muted);
  background: var(--surface);
  font-size: 12px;
}

.rollout-permission svg { flex: 0 0 auto; color: var(--info); }

.rollout-summary {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  margin-bottom: 18px;
  border-top: 1px solid var(--border);
  border-bottom: 1px solid var(--border);
  background: color-mix(in srgb, var(--surface) 72%, transparent);
}

.rollout-summary > div { min-width: 0; padding: 15px 18px; border-right: 1px solid var(--border); }
.rollout-summary > div:last-child { border-right: 0; }
.rollout-summary span { display: block; color: var(--muted); font-size: 11px; }
.rollout-summary strong { display: block; margin-top: 5px; font-size: 22px; line-height: 1; }
.rollout-summary [data-alert="true"] strong { color: var(--danger); }

.rollout-filter-bar { flex-wrap: wrap; }
.rollout-search { width: min(320px, 100%); }
.rollout-refresh-error { display: inline-flex; align-items: center; gap: 5px; color: var(--danger); font-size: 11px; }
.rollout-list-panel { min-height: 220px; }
.rollout-table { min-width: 1040px; }

.rollout-release {
  min-width: 180px;
  display: inline-flex;
  align-items: center;
  gap: 10px;
  padding: 0;
  border: 0;
  color: inherit;
  background: transparent;
  text-align: left;
  cursor: pointer;
}

.rollout-release > span:first-child {
  width: 34px;
  height: 34px;
  display: inline-grid;
  flex: 0 0 auto;
  place-items: center;
  border: 1px solid var(--border);
  border-radius: 6px;
  color: var(--accent);
  background: var(--surface-subtle);
}

.rollout-release strong, .rollout-release small { display: block; }
.rollout-release strong { font-size: 13px; }
.rollout-release small { margin-top: 3px; color: var(--muted); font-size: 10px; }
.rollout-release:hover strong, .rollout-release:focus-visible strong { color: var(--accent); }
.rollout-release:focus-visible, .rollout-open-button:focus-visible, .rollout-device-link:focus-visible { outline: 2px solid var(--info); outline-offset: 3px; }

.rollout-progress-cell { width: 180px; }
.rollout-progress-cell > div { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 6px; font-size: 10px; }
.rollout-progress-cell > div span { color: var(--muted); }
.rollout-progress-cell > small { display: block; margin-top: 5px; color: var(--danger); font-size: 10px; }

.rollout-open-button {
  width: 44px;
  height: 44px;
  display: inline-grid;
  place-items: center;
  border: 0;
  border-radius: 6px;
  color: var(--muted);
  background: transparent;
  cursor: pointer;
}

.rollout-open-button:hover { color: var(--foreground); background: var(--surface-subtle); }

:deep(.rollout-detail-drawer .el-drawer__body) { padding: 0 22px 32px; }
.rollout-detail-head { position: sticky; top: 0; z-index: 2; display: flex; align-items: center; justify-content: space-between; gap: 16px; min-height: 86px; border-bottom: 1px solid var(--border); background: var(--surface); }
.rollout-detail-head span:first-child { color: var(--muted); font-size: 11px; }
.rollout-detail-head h2 { margin-top: 4px; font-size: 22px; }
.rollout-detail-head-actions { display: flex; align-items: center; gap: 10px; }
.rollout-detail-close { width: 44px; height: 44px; display: inline-grid; place-items: center; border: 1px solid var(--border); border-radius: 6px; color: var(--muted); background: var(--surface); cursor: pointer; }
.rollout-detail-close:hover { color: var(--foreground); border-color: var(--border-strong); background: var(--surface-subtle); }
.rollout-detail-close:focus-visible { outline: 2px solid var(--info); outline-offset: 2px; }
.rollout-reason { display: flex; align-items: flex-start; gap: 8px; margin-top: 16px; padding: 11px 12px; border-left: 3px solid var(--info); color: var(--muted); background: var(--info-bg); font-size: 12px; line-height: 1.55; }
.rollout-reason[data-error="true"] { border-left-color: var(--warning); background: var(--warning-bg); }
.rollout-reason svg { flex: 0 0 auto; margin-top: 1px; }
.rollout-actions { display: flex; flex-wrap: wrap; gap: 8px; padding: 16px 0; border-bottom: 1px solid var(--border); }
.rollout-actions :deep(.el-button) { min-height: 44px; margin-left: 0; }
.rollout-detail-section { padding: 20px 0; border-bottom: 1px solid var(--border); }
.rollout-detail-section:last-child { border-bottom: 0; }
.rollout-detail-section h3 { font-size: 14px; }
.rollout-overview-section :deep(.el-progress) { margin-top: 15px; }

.rollout-detail-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); }
.rollout-detail-grid > div { min-width: 0; padding: 0 14px; border-right: 1px solid var(--border); }
.rollout-detail-grid > div:first-child { padding-left: 0; }
.rollout-detail-grid > div:last-child { padding-right: 0; border-right: 0; }
.rollout-detail-grid span { display: block; color: var(--muted); font-size: 10px; }
.rollout-detail-grid strong { display: block; margin-top: 5px; font-size: 17px; }
.rollout-detail-grid strong[data-error="true"] { color: var(--danger); }

.rollout-definition-list { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0 24px; margin-top: 12px; }
.rollout-definition-list > div { min-width: 0; display: grid; grid-template-columns: 118px minmax(0, 1fr); gap: 10px; padding: 10px 0; border-bottom: 1px solid var(--border); }
.rollout-definition-list dt { color: var(--muted); font-size: 11px; }
.rollout-definition-list dd { overflow-wrap: anywhere; font-size: 12px; }

.rollout-member-heading { display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; margin-bottom: 12px; }
.rollout-member-heading p { margin-top: 4px; color: var(--muted); font-size: 11px; line-height: 1.5; }
.member-status-filter { width: 190px; flex: 0 0 auto; }
.rollout-member-table-wrap { border: 1px solid var(--border); border-radius: 6px; }
.rollout-member-table { min-width: 760px; }
.rollout-device-link { color: var(--foreground); font-weight: 650; text-decoration: none; }
.rollout-device-link:hover { color: var(--accent); }
.rollout-member-error { display: block; max-width: 190px; margin-top: 5px; overflow: hidden; color: var(--danger); font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }
.rollout-detail-loading { min-height: 140px; display: flex; align-items: center; justify-content: center; gap: 8px; color: var(--muted); font-size: 12px; }

.rollout-create-intro, .rollout-create-note { display: flex; align-items: flex-start; gap: 9px; margin-bottom: 18px; padding: 11px 12px; border-left: 3px solid var(--accent); color: var(--muted); background: var(--accent-soft); font-size: 12px; line-height: 1.55; }
.rollout-create-note { margin: 2px 0 0; border-left-color: var(--info); background: var(--info-bg); }
.rollout-create-intro svg, .rollout-create-note svg { flex: 0 0 auto; margin-top: 1px; }
.rollout-form-hint { display: block; margin-top: 6px; color: var(--muted); font-size: 10px; }
.rollout-form-divider { display: flex; align-items: center; gap: 12px; margin: 2px 0 16px; color: var(--muted); font-size: 11px; }
.rollout-form-divider::after { height: 1px; flex: 1; background: var(--border); content: ''; }
.rollout-form-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0 14px; }
.rollout-form-grid :deep(.el-input-number) { width: 100%; }

@media (max-width: 760px) {
  .rollout-summary { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .rollout-summary > div:nth-child(2) { border-right: 0; }
  .rollout-summary > div:nth-child(-n + 2) { border-bottom: 1px solid var(--border); }
  .rollout-filter-bar > * { width: 100%; }
  .rollout-filter-bar .filter-count { margin-left: 0; }
  :deep(.rollout-detail-drawer .el-drawer__body) { padding: 0 14px 24px; }
  .rollout-detail-head { min-height: 76px; }
  .rollout-actions :deep(.el-button) { flex: 1 1 calc(50% - 4px); }
  .rollout-detail-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px 0; }
  .rollout-detail-grid > div:nth-child(2) { padding-right: 0; border-right: 0; }
  .rollout-detail-grid > div:nth-child(3) { padding-left: 0; }
  .rollout-definition-list { grid-template-columns: 1fr; }
  .rollout-member-heading { align-items: stretch; flex-direction: column; }
  .member-status-filter { width: 100%; }
  .rollout-form-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

@media (max-width: 480px) {
  .rollout-form-grid { grid-template-columns: 1fr; }
  .rollout-detail-grid { grid-template-columns: 1fr; gap: 0; }
  .rollout-detail-grid > div { padding: 11px 0; border-right: 0; border-bottom: 1px solid var(--border); }
  .rollout-detail-grid > div:last-child { border-bottom: 0; }
  .rollout-definition-list > div { grid-template-columns: 1fr; gap: 4px; }
}
</style>
