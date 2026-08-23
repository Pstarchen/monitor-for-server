<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { onBeforeRouteLeave } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import {
  Activity, CheckCircle2, ChevronRight, Copy, Database, Globe2, KeyRound, LockKeyhole,
  Clock3, Download, GitCommit, Mail, MessageSquareText, RefreshCw, RotateCcw,
  Plus, Save, Send, ServerCog, Settings2, ShieldCheck, Trash2, Upload,
} from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { copyText } from '@/lib/clipboard'
import { dateTime } from '@/lib/format'
import { loadBranding } from '@/lib/branding'
import { visibleApiTokenScopes } from '@/lib/api-token-scopes'
import { shortRevision, shouldPollUpdate, updateStateText } from '@/lib/controller-update'
import { useAuthStore } from '@/stores/auth'
import type { ApiToken, ControllerServiceStatus, ControllerUpdateStatus, CreatedApiToken, Settings, WebhookSettings } from '@/types'

type ChannelKey = 'email' | 'dingtalk' | 'wecom'
type SectionKey = 'general' | 'monitoring' | ChannelKey | 'security' | 'tokens' | 'updates'

const sections = [
  {
    label: '基础配置',
    items: [
      { key: 'general' as const, label: '站点与部署', description: '名称、入口与时区', icon: Globe2 },
      { key: 'monitoring' as const, label: '监控策略', description: '采集、离线与留存', icon: Activity },
    ],
  },
  {
    label: '通知渠道',
    items: [
      { key: 'email' as const, label: '邮件通知', description: 'SMTP 发信服务', icon: Mail },
      { key: 'dingtalk' as const, label: '钉钉机器人', description: '群机器人 Webhook', icon: MessageSquareText },
      { key: 'wecom' as const, label: '企业微信', description: '群机器人 Webhook', icon: MessageSquareText },
    ],
  },
  {
    label: '系统状态',
    items: [
      { key: 'security' as const, label: '安全与存储', description: '凭据和数据边界', icon: ShieldCheck },
      { key: 'tokens' as const, label: 'API Token', description: '移动端与自动化访问', icon: KeyRound },
      { key: 'updates' as const, label: '系统更新', description: '版本检查与升级策略', icon: RefreshCw },
    ],
  },
]

const settings = ref<Settings | null>(null)
const activeSection = ref<SectionKey>('general')
const baseline = ref('')
const form = reactive({
  metricRetentionDays: 30,
  deviceOfflineAfterSeconds: 30,
  defaultCollectionSeconds: 3,
  siteName: '星辰云巡',
  siteIconUrl: '/favicon.svg',
  publicBaseUrl: '',
  timezone: 'Asia/Shanghai',
  enableMcp: false,
  email: {
    enabled: false, host: '', port: 587, username: '', password: '', clearPassword: false,
    from: '', recipients: '', auth: true, startTls: true,
  },
  dingtalk: { enabled: false, webhookUrl: '', clearWebhook: false },
  wecom: { enabled: false, webhookUrl: '', clearWebhook: false },
})
const loading = ref(true)
const saving = ref(false)
const uploadingIcon = ref(false)
const iconUploadProgress = ref(0)
const siteIconInput = ref<HTMLInputElement | null>(null)
const error = ref('')
const testing = reactive<Record<ChannelKey, boolean>>({ email: false, dingtalk: false, wecom: false })
const controllerUpdate = ref<ControllerUpdateStatus | null>(null)
const updateLoading = ref(false)
const updateAction = ref<'check' | 'apply' | 'auto' | ''>('')
const updateError = ref('')
const waitingForRestart = ref(false)
const apiTokens = ref<ApiToken[]>([])
const tokenLoading = ref(false)
const tokenDialog = ref(false)
const tokenSaving = ref(false)
const createdToken = ref<CreatedApiToken | null>(null)
const tokenForm = reactive({ name: '', scopes: ['nezha:inventory:read'], serverIds: '', expiresInDays: 90 })
const auth = useAuthStore()
const canAdmin = computed(() => auth.user?.role === 'ADMIN')
const scopes = computed(() => visibleApiTokenScopes(canAdmin.value))
let updatePollTimer: ReturnType<typeof setTimeout> | undefined
const hasChanges = computed(() => baseline.value !== '' && baseline.value !== snapshot())

function snapshot() {
  return JSON.stringify(form)
}

function apply(value: Settings) {
  Object.assign(form, {
    metricRetentionDays: value.metricRetentionDays,
    deviceOfflineAfterSeconds: value.deviceOfflineAfterSeconds,
    defaultCollectionSeconds: value.defaultCollectionSeconds,
    siteName: value.siteName,
    siteIconUrl: value.siteIconUrl,
    publicBaseUrl: value.publicBaseUrl,
    timezone: value.timezone,
    enableMcp: value.enableMcp,
  })
  Object.assign(form.email, {
    enabled: value.email.enabled,
    host: value.email.host,
    port: value.email.port,
    username: value.email.username,
    password: '',
    clearPassword: false,
    from: value.email.from,
    recipients: value.email.recipients,
    auth: value.email.auth,
    startTls: value.email.startTls,
  })
  Object.assign(form.dingtalk, { enabled: value.dingtalk.enabled, webhookUrl: '', clearWebhook: false })
  Object.assign(form.wecom, { enabled: value.wecom.enabled, webhookUrl: '', clearWebhook: false })
  baseline.value = snapshot()
}

async function load() {
  loading.value = true
  error.value = ''
  try {
    settings.value = (await api.get<Settings>('/settings')).data
    apply(settings.value)
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

async function loadApiTokens() {
  tokenLoading.value = true
  try {
    apiTokens.value = (await api.get<ApiToken[]>('/api-tokens')).data
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    tokenLoading.value = false
  }
}

function openTokenDialog() {
  Object.assign(tokenForm, { name: '', scopes: ['nezha:inventory:read'], serverIds: '', expiresInDays: 90 })
  tokenDialog.value = true
}

async function createApiToken() {
  if (!tokenForm.name.trim() || !tokenForm.scopes.length) {
    ElMessage.warning('请输入 Token 名称并至少选择一个权限')
    return
  }
  tokenSaving.value = true
  try {
    createdToken.value = (await api.post<CreatedApiToken>('/api-tokens', {
      name: tokenForm.name.trim(),
      scopes: tokenForm.scopes,
      serverIds: tokenForm.serverIds.split(',').map((value) => value.trim()).filter(Boolean),
      expiresInDays: Number(tokenForm.expiresInDays) || 0,
    })).data
    tokenDialog.value = false
    await loadApiTokens()
    ElMessage.success('API Token 已创建，请立即复制明文')
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    tokenSaving.value = false
  }
}

async function copyApiToken() {
  if (!createdToken.value) return
  try {
    await copyText(createdToken.value.secret)
    ElMessage.success('Token 已复制')
  } catch {
    ElMessage.error('复制失败，请手动选择 Token')
  }
}

async function revokeApiToken(token: ApiToken) {
  try {
    await ElMessageBox.confirm(`吊销“${token.name}”后，使用它的客户端会立即失去访问权限。`, '吊销 API Token', { type: 'warning', confirmButtonText: '确认吊销', cancelButtonText: '取消' })
    await api.delete(`/api-tokens/${token.id}`)
    ElMessage.success('API Token 已吊销')
    await loadApiTokens()
  } catch (cause) {
    if (cause !== 'cancel' && cause !== 'close') ElMessage.error(errorMessage(cause))
  }
}

function reset() {
  if (!settings.value) return
  apply(settings.value)
  ElMessage.info('已撤销未保存的修改')
}

async function save() {
  if (!hasChanges.value) return
  saving.value = true
  try {
    settings.value = (await api.put<Settings>('/settings', form)).data
    apply(settings.value)
    await loadBranding(true)
    ElMessage.success('系统设置已保存')
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    saving.value = false
  }
}

function chooseSiteIcon() {
  if (hasChanges.value) {
    ElMessage.warning('请先保存或撤销当前修改，再上传网站图标')
    return
  }
  siteIconInput.value?.click()
}

async function uploadSiteIcon(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  input.value = ''
  if (!file) return
  if (!file.type.startsWith('image/')) {
    ElMessage.error('请选择图片文件')
    return
  }
  if (file.size > 50 * 1024 * 1024) {
    ElMessage.error('网站图标不能超过 50MB')
    return
  }
  uploadingIcon.value = true
  iconUploadProgress.value = 0
  try {
    const body = new FormData()
    body.append('file', file, file.name)
    const response = await api.post<Settings>('/settings/site-icon', body, {
      onUploadProgress: (progress) => {
        if (progress.total) iconUploadProgress.value = Math.round(progress.loaded * 100 / progress.total)
      },
    })
    settings.value = response.data
    apply(response.data)
    await loadBranding(true)
    ElMessage.success('网站图标上传成功')
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    uploadingIcon.value = false
  }
}

function restoreDefaultSiteIcon() {
  form.siteIconUrl = '/favicon.svg'
}

async function testChannel(channel: ChannelKey) {
  testing[channel] = true
  try {
    const { data } = await api.post<{ message: string }>(`/settings/notifications/${channel}/test`)
    ElMessage.success(data.message)
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    testing[channel] = false
  }
}

function channelStatus(channel: { enabled: boolean; configured: boolean }) {
  if (!channel.enabled) return 'OFFLINE'
  return channel.configured ? 'ONLINE' : 'PENDING'
}

function sourceText(source: WebhookSettings['source']) {
  if (source === 'DATABASE') return '控制台加密保存'
  if (source === 'ENVIRONMENT') return '部署环境提供'
  return '尚未设置'
}

function navState(key: SectionKey) {
  if (key === 'updates') {
    if (!controllerUpdate.value) return ''
    return controllerUpdate.value.state === 'ERROR' || controllerUpdate.value.updateAvailable ? 'attention' : 'ready'
  }
  if (!settings.value || !['email', 'dingtalk', 'wecom'].includes(key)) return ''
  const channel = settings.value[key as ChannelKey]
  if (!channel.enabled) return 'disabled'
  return channel.configured ? 'ready' : 'attention'
}

function scheduleUpdatePoll(delay = 3000) {
  if (updatePollTimer) clearTimeout(updatePollTimer)
  updatePollTimer = setTimeout(() => loadControllerUpdate(true), delay)
}

async function loadControllerUpdate(silent = false) {
  if (!silent) updateLoading.value = true
  try {
    controllerUpdate.value = (await api.get<ControllerUpdateStatus>('/admin/controller-update')).data
    updateError.value = ''
    if (!shouldPollUpdate(controllerUpdate.value.state)) {
      waitingForRestart.value = false
      updateAction.value = ''
    }
    if (shouldPollUpdate(controllerUpdate.value.state)) scheduleUpdatePoll()
  } catch (cause) {
    if (waitingForRestart.value) {
      scheduleUpdatePoll(4000)
    } else {
      updateError.value = errorMessage(cause)
    }
  } finally {
    updateLoading.value = false
  }
}

async function checkControllerUpdate() {
  updateAction.value = 'check'
  updateError.value = ''
  try {
    controllerUpdate.value = (await api.post<ControllerUpdateStatus>('/admin/controller-update/check')).data
    scheduleUpdatePoll()
  } catch (cause) {
    updateAction.value = ''
    ElMessage.error(errorMessage(cause))
  }
}

async function applyControllerUpdate() {
  try {
    await ElMessageBox.confirm(
      '更新会拉取最新总控镜像并依次重启服务，控制台可能暂时无法访问，但不会删除监控数据。',
      '立即更新总控',
      { confirmButtonText: '开始更新', cancelButtonText: '取消', type: 'warning' },
    )
  } catch {
    return
  }
  updateAction.value = 'apply'
  waitingForRestart.value = true
  updateError.value = ''
  try {
    controllerUpdate.value = (await api.post<ControllerUpdateStatus>('/admin/controller-update/apply')).data
    ElMessage.success('更新任务已启动')
    scheduleUpdatePoll(2000)
  } catch (cause) {
    waitingForRestart.value = false
    updateAction.value = ''
    ElMessage.error(errorMessage(cause))
  }
}

async function setControllerAutoUpdate(value: string | number | boolean) {
  updateAction.value = 'auto'
  try {
    controllerUpdate.value = (await api.put<ControllerUpdateStatus>('/admin/controller-update/auto', { enabled: Boolean(value) })).data
    ElMessage.success(Boolean(value) ? '已启用每日自动更新' : '已关闭自动更新')
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    updateAction.value = ''
  }
}

function formatUpdateTime(value?: string) {
  if (!value) return '暂无记录'
  return new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(new Date(value))
}

function serviceName(service: ControllerServiceStatus['name']) {
  return ({ setup: '安装与更新服务', server: '总控 API', web: 'Web 控制台' } as Record<string, string>)[service] ?? service
}

function healthText(health: string) {
  return ({ healthy: '运行正常', starting: '正在启动', running: '运行中', unhealthy: '状态异常', exited: '已停止', not_found: '未运行' } as Record<string, string>)[health] ?? health
}

function canTest(channel: ChannelKey) {
  if (!settings.value || hasChanges.value) return false
  const value = settings.value[channel]
  return value.enabled && value.configured
}

onBeforeRouteLeave(async () => {
  if (!hasChanges.value) return true
  try {
    await ElMessageBox.confirm('当前设置尚未保存，离开后修改将丢失。', '离开系统设置', {
      confirmButtonText: '放弃修改', cancelButtonText: '继续编辑', type: 'warning',
    })
    return true
  } catch {
    return false
  }
})

watch(activeSection, (section) => {
  if (section === 'updates' && !controllerUpdate.value && !updateLoading.value) loadControllerUpdate()
  if (section === 'tokens' && !apiTokens.value.length && !tokenLoading.value) loadApiTokens()
})

onMounted(() => {
  load()
  loadApiTokens()
  loadControllerUpdate()
})
onBeforeUnmount(() => {
  if (updatePollTimer) clearTimeout(updatePollTimer)
})
</script>

<template>
  <section>
    <PageHeader eyebrow="SETTINGS" title="系统设置" description="管理监控行为、公共入口与通知渠道。">
      <template #actions>
        <div v-if="activeSection !== 'updates'" class="settings-page-actions">
          <span class="save-state" :data-dirty="hasChanges"><CheckCircle2 :size="14" />{{ hasChanges ? '有未保存修改' : '所有设置已保存' }}</span>
          <el-button :disabled="!hasChanges || saving" @click="reset"><RotateCcw :size="16" />撤销修改</el-button>
          <el-button type="primary" class="button-press" :disabled="!hasChanges" :loading="saving" @click="save"><Save :size="16" />保存设置</el-button>
        </div>
      </template>
    </PageHeader>

    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel">
      <EmptyState title="设置加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState>
    </div>

    <template v-else-if="settings">
      <div v-if="!settings.secretStorageReady" class="settings-notice" role="status">
        <LockKeyhole :size="18" />
        <div><strong>通知凭据存储未启用</strong><p>配置部署端加密密钥后，才可在控制台保存 SMTP 密码和 Webhook。</p></div>
        <button type="button" @click="activeSection = 'security'">查看状态<ChevronRight :size="14" /></button>
      </div>

      <div class="settings-workspace panel">
        <aside class="settings-index" aria-label="设置分类">
          <div class="settings-index-head"><span><Settings2 :size="17" /></span><div><strong>设置中心</strong><small>选择需要编辑的项目</small></div></div>
          <nav>
            <section v-for="section in sections" :key="section.label">
              <p>{{ section.label }}</p>
              <button v-for="item in section.items" :key="item.key" type="button" :class="{ active: activeSection === item.key }" @click="activeSection = item.key">
                <span class="settings-nav-icon"><component :is="item.icon" :size="16" /></span>
                <span class="settings-nav-copy"><strong>{{ item.label }}</strong><small>{{ item.description }}</small></span>
                <i v-if="navState(item.key)" :data-state="navState(item.key)" />
                <ChevronRight v-else :size="14" />
              </button>
            </section>
          </nav>
        </aside>

        <main class="settings-editor">
          <template v-if="activeSection === 'general'">
            <header class="settings-editor-head"><span><Globe2 :size="18" /></span><div><h2>站点与部署</h2><p>定义控制台身份和 Agent 连接入口。</p></div></header>
            <el-form class="settings-editor-body" @submit.prevent="save">
              <div class="setting-list">
                <div class="setting-row">
                  <div class="setting-copy"><label for="site-name">站点名称</label><p>显示在侧栏和登录页的产品名称。</p></div>
                  <div class="setting-control"><el-input id="site-name" v-model="form.siteName" maxlength="60" show-word-limit /></div>
                </div>
                <div class="setting-row">
                  <div class="setting-copy"><label for="site-icon-url">网站图标</label><p>浏览器标签页使用的图标。可填写站内路径或 HTTPS 图片地址，留空恢复默认图标。</p></div>
                  <div class="setting-control site-icon-control">
                    <div class="site-icon-preview"><img :src="form.siteIconUrl || '/favicon.svg'" alt="" /></div>
                    <div class="site-icon-fields">
                      <el-input id="site-icon-url" v-model="form.siteIconUrl" placeholder="/favicon.svg 或 https://example.com/icon.svg" />
                      <div class="site-icon-actions">
                        <input ref="siteIconInput" class="site-icon-file-input" type="file" accept="image/*" @change="uploadSiteIcon" />
                        <el-button :loading="uploadingIcon" :disabled="uploadingIcon" @click="chooseSiteIcon"><Upload :size="15" />上传图标</el-button>
                        <el-button v-if="form.siteIconUrl !== '/favicon.svg'" :disabled="uploadingIcon" @click="restoreDefaultSiteIcon"><RotateCcw :size="15" />恢复默认</el-button>
                        <span class="site-icon-hint">图片文件，最大 50MB</span>
                      </div>
                      <el-progress v-if="uploadingIcon" :percentage="iconUploadProgress" :show-text="false" :stroke-width="4" />
                    </div>
                  </div>
                </div>
                <div class="setting-row">
                  <div class="setting-copy"><label for="public-url">公网入口</label><p>用于生成 Agent 安装命令，生产环境应使用 HTTPS。</p></div>
                  <div class="setting-control"><el-input id="public-url" v-model="form.publicBaseUrl" placeholder="https://monitor.example.com" /></div>
                </div>
                <div class="setting-row">
                  <div class="setting-copy"><label for="timezone">服务时区</label><p>应用于后台任务和界面时间显示。</p></div>
                  <div class="setting-control"><el-input id="timezone" v-model="form.timezone" placeholder="Asia/Shanghai" /></div>
                </div>
                <div class="setting-row">
                  <div class="setting-copy"><label>MCP HTTP 接口</label><p>开启后允许带有 API Token 的 MCP 客户端访问服务器工具；默认关闭。</p></div>
                  <div class="setting-control"><el-switch v-model="form.enableMcp" aria-label="启用 MCP HTTP 接口" /></div>
                </div>
              </div>
            </el-form>
          </template>

          <template v-else-if="activeSection === 'monitoring'">
            <header class="settings-editor-head"><span><Activity :size="18" /></span><div><h2>监控策略</h2><p>控制数据留存、离线判定和 Agent 上报频率。</p></div></header>
            <el-form class="settings-editor-body" @submit.prevent="save">
              <div class="setting-list">
                <div class="setting-row">
                  <div class="setting-copy"><label for="retention-days">指标留存</label><p>过期指标按日清理，不影响告警和审计记录。</p></div>
                  <div class="setting-control compact"><el-input-number id="retention-days" v-model="form.metricRetentionDays" :min="1" :max="3650" /><span>天</span></div>
                </div>
                <div class="setting-row">
                  <div class="setting-copy"><label for="offline-seconds">离线判定</label><p>超过该时长未上报时，将设备标记为离线。</p></div>
                  <div class="setting-control compact"><el-input-number id="offline-seconds" v-model="form.deviceOfflineAfterSeconds" :min="5" :max="3600" /><span>秒</span></div>
                </div>
                <div class="setting-row">
                  <div class="setting-copy"><label>Agent 上报周期</label><p>已安装 Agent 会在下次成功上报后应用此周期，新安装指引也会使用该值。</p></div>
                  <div class="setting-control"><el-segmented v-model="form.defaultCollectionSeconds" :options="[{ label: '1 秒', value: 1 }, { label: '3 秒', value: 3 }, { label: '10 秒', value: 10 }, { label: '30 秒', value: 30 }, { label: '60 秒', value: 60 }]" /></div>
                </div>
              </div>
            </el-form>
          </template>

          <template v-else-if="activeSection === 'email'">
            <header class="settings-editor-head channel-editor-head">
              <span><Mail :size="18" /></span><div><h2>邮件通知</h2><p>{{ sourceText(settings.email.source) }} · SMTP 发信服务</p></div>
              <StatusBadge :status="channelStatus(settings.email)" /><el-switch v-model="form.email.enabled" aria-label="启用邮件通知" />
            </header>
            <el-form class="settings-editor-body" @submit.prevent="save">
              <div class="setting-list">
                <div class="setting-row"><div class="setting-copy"><label for="smtp-host">SMTP 主机</label><p>邮件服务商提供的服务器域名。</p></div><div class="setting-control"><el-input id="smtp-host" v-model="form.email.host" placeholder="smtp.example.com" /></div></div>
                <div class="setting-row"><div class="setting-copy"><label for="smtp-port">SMTP 端口</label><p>常用 STARTTLS 端口为 587。</p></div><div class="setting-control compact"><el-input-number id="smtp-port" v-model="form.email.port" :min="1" :max="65535" /></div></div>
                <div class="setting-row"><div class="setting-copy"><label for="smtp-username">登录用户名</label><p>关闭身份验证时可留空。</p></div><div class="setting-control"><el-input id="smtp-username" v-model="form.email.username" autocomplete="off" /></div></div>
                <div class="setting-row"><div class="setting-copy"><label for="smtp-password">登录密码</label><p>{{ settings.email.passwordConfigured ? '已保存密码，留空不会覆盖。' : '尚未保存 SMTP 密码。' }}</p></div><div class="setting-control secret-control"><el-input id="smtp-password" v-model="form.email.password" type="password" show-password autocomplete="new-password" :disabled="!settings.secretStorageReady" :placeholder="settings.email.passwordConfigured ? '输入新密码以替换' : '输入 SMTP 密码'" /><el-checkbox v-if="settings.email.source === 'DATABASE'" v-model="form.email.clearPassword">清除已保存密码</el-checkbox></div></div>
                <div class="setting-row"><div class="setting-copy"><label for="email-from">发件人</label><p>建议与 SMTP 账号授权的地址一致。</p></div><div class="setting-control"><el-input id="email-from" v-model="form.email.from" placeholder="monitor@example.com" /></div></div>
                <div class="setting-row"><div class="setting-copy"><label for="email-recipients">收件人</label><p>多个地址使用英文逗号分隔。</p></div><div class="setting-control"><el-input id="email-recipients" v-model="form.email.recipients" placeholder="ops@example.com, owner@example.com" /></div></div>
                <div class="setting-row"><div class="setting-copy"><label>连接安全</label><p>按邮件服务商要求启用认证和加密。</p></div><div class="setting-control checkbox-row"><el-checkbox v-model="form.email.auth">SMTP 身份验证</el-checkbox><el-checkbox v-model="form.email.startTls">STARTTLS</el-checkbox></div></div>
              </div>
              <div class="settings-section-actions"><p>{{ hasChanges ? '保存当前修改后可发送测试通知。' : '测试将使用服务器已保存的配置。' }}</p><el-button :disabled="!canTest('email')" :loading="testing.email" @click="testChannel('email')"><Send :size="15" />发送测试邮件</el-button></div>
            </el-form>
          </template>

          <template v-else-if="activeSection === 'dingtalk' || activeSection === 'wecom'">
            <header class="settings-editor-head channel-editor-head">
              <span><MessageSquareText :size="18" /></span>
              <div><h2>{{ activeSection === 'dingtalk' ? '钉钉机器人' : '企业微信机器人' }}</h2><p>{{ sourceText(settings[activeSection].source) }} · 群机器人通知</p></div>
              <StatusBadge :status="channelStatus(settings[activeSection])" /><el-switch v-model="form[activeSection].enabled" :aria-label="`启用${activeSection === 'dingtalk' ? '钉钉' : '企业微信'}通知`" />
            </header>
            <el-form class="settings-editor-body" @submit.prevent="save">
              <div class="setting-list">
                <div class="setting-row">
                  <div class="setting-copy"><label :for="`${activeSection}-webhook`">Webhook 地址</label><p>地址将加密保存，读取设置时不会返回明文。</p></div>
                  <div class="setting-control secret-control">
                    <el-input :id="`${activeSection}-webhook`" v-model="form[activeSection].webhookUrl" type="password" show-password autocomplete="new-password" :disabled="!settings.secretStorageReady" :placeholder="settings[activeSection].webhookConfigured ? '输入新地址以替换' : activeSection === 'dingtalk' ? 'https://oapi.dingtalk.com/...' : 'https://qyapi.weixin.qq.com/...'" />
                    <el-checkbox v-if="settings[activeSection].source === 'DATABASE'" v-model="form[activeSection].clearWebhook">清除已保存地址</el-checkbox>
                  </div>
                </div>
              </div>
              <div class="settings-section-actions"><p>{{ hasChanges ? '保存当前修改后可测试通道。' : '测试将发送一条验证消息。' }}</p><el-button :disabled="!canTest(activeSection)" :loading="testing[activeSection]" @click="testChannel(activeSection)"><Send :size="15" />发送测试消息</el-button></div>
            </el-form>
          </template>

          <template v-else-if="activeSection === 'tokens'">
            <header class="settings-editor-head token-editor-head"><span><KeyRound :size="18" /></span><div><h2>API Token</h2><p>为移动端、脚本或自动化工具签发受限访问凭据。</p></div><el-button type="primary" class="button-press" @click="openTokenDialog"><Plus :size="15" />创建 Token</el-button></header>
            <div class="settings-editor-body token-settings">
              <div class="settings-notice token-notice" role="note"><ShieldCheck :size="17" /><p>明文 Token 只会在创建成功后显示一次。请按最小权限选择 scope，并在需要时填写服务器 ID 白名单。</p></div>
              <LoadingState v-if="tokenLoading" />
              <div v-else-if="apiTokens.length" class="token-list">
                <article v-for="token in apiTokens" :key="token.id" class="token-row" :data-revoked="Boolean(token.revokedAt)">
                  <div class="token-row-main"><div><strong>{{ token.name }}</strong><small class="mono-value">{{ token.tokenPrefix }}…</small></div><StatusBadge :status="token.revokedAt ? 'OFFLINE' : 'ONLINE'" /></div>
                  <div class="token-row-meta"><span>{{ token.scopes.join('、') }}</span><span>{{ token.serverIds.length ? `${token.serverIds.length} 台服务器白名单` : '不限制服务器白名单' }}</span><span>{{ token.expiresAt ? `到期 ${dateTime(token.expiresAt)}` : '永不过期' }}</span><span>{{ token.lastUsedAt ? `最后使用 ${dateTime(token.lastUsedAt)}` : '尚未使用' }}</span></div>
                  <button v-if="!token.revokedAt" class="table-icon-button danger-command" type="button" title="吊销 Token" aria-label="吊销 Token" @click="revokeApiToken(token)"><Trash2 :size="16" /></button>
                </article>
              </div>
              <EmptyState v-else title="暂无 API Token" description="创建一个只读 Token，即可让移动端或自动化工具访问监控数据。"><el-button type="primary" @click="openTokenDialog"><Plus :size="15" />创建 Token</el-button></EmptyState>
            </div>
          </template>

          <template v-else-if="activeSection === 'security'">
            <header class="settings-editor-head"><span><ShieldCheck :size="18" /></span><div><h2>安全与存储</h2><p>查看敏感配置的保护边界和持久化状态。</p></div></header>
            <div class="settings-editor-body security-settings">
              <div class="security-state" :data-ready="settings.secretStorageReady"><span><LockKeyhole :size="18" /></span><div><strong>{{ settings.secretStorageReady ? '凭据加密存储已启用' : '凭据加密存储未启用' }}</strong><p>{{ settings.secretStorageReady ? '新的 SMTP 密码和 Webhook 将使用 AES-256-GCM 加密。' : '通知环境变量仍可使用，但控制台无法保存新的敏感值。' }}</p></div><StatusBadge :status="settings.secretStorageReady ? 'ONLINE' : 'PENDING'" /></div>
              <dl class="security-list">
                <div><dt><Database :size="15" />指标数据</dt><dd><strong>私有数据库</strong><span>{{ form.metricRetentionDays }} 天留存</span></dd></div>
                <div><dt><KeyRound :size="15" />邮件凭据</dt><dd><strong>{{ sourceText(settings.email.source) }}</strong><span>{{ settings.email.passwordConfigured ? '密码已配置' : '未配置密码' }}</span></dd></div>
                <div><dt><MessageSquareText :size="15" />钉钉 Webhook</dt><dd><strong>{{ sourceText(settings.dingtalk.source) }}</strong><span>{{ settings.dingtalk.webhookConfigured ? '地址已配置' : '未配置地址' }}</span></dd></div>
                <div><dt><MessageSquareText :size="15" />企业微信 Webhook</dt><dd><strong>{{ sourceText(settings.wecom.source) }}</strong><span>{{ settings.wecom.webhookConfigured ? '地址已配置' : '未配置地址' }}</span></dd></div>
              </dl>
              <div class="security-footnote"><ShieldCheck :size="16" /><p>设置接口只返回配置状态。保存和测试操作均写入审计日志。</p></div>
            </div>
          </template>

          <template v-else>
            <header class="settings-editor-head"><span><RefreshCw :size="18" /></span><div><h2>系统更新</h2><p>检查并更新总控镜像，更新源优先使用已配置的国内镜像。</p></div></header>
            <div class="settings-editor-body update-settings">
              <LoadingState v-if="updateLoading && !controllerUpdate" />
              <EmptyState v-else-if="updateError && !controllerUpdate" title="更新状态加载失败" :description="updateError">
                <el-button @click="loadControllerUpdate()">重新加载</el-button>
              </EmptyState>
              <template v-else-if="controllerUpdate">
                <div class="update-state" :data-state="controllerUpdate.state" role="status" aria-live="polite">
                  <span><RefreshCw :size="18" :class="{ spinning: shouldPollUpdate(controllerUpdate.state) }" /></span>
                  <div>
                    <strong>{{ updateStateText(controllerUpdate.state, controllerUpdate.updateAvailable) }}</strong>
                    <p>{{ waitingForRestart ? '服务正在重启，控制台恢复后会自动刷新状态。' : controllerUpdate.message }}</p>
                  </div>
                  <i>{{ controllerUpdate.state }}</i>
                </div>

                <dl class="update-version-list">
                  <div>
                    <dt><GitCommit :size="15" />当前构建版本</dt>
                    <dd><code :title="controllerUpdate.currentRevision">{{ shortRevision(controllerUpdate.currentRevision) }}</code><span>正在运行</span></dd>
                  </div>
                  <div>
                    <dt><Download :size="15" />最新构建版本</dt>
                    <dd><code :title="controllerUpdate.latestRevision">{{ shortRevision(controllerUpdate.latestRevision) }}</code><span>{{ controllerUpdate.checkedAt ? '最近检查结果' : '检查后显示' }}</span></dd>
                  </div>
                </dl>

                <div class="setting-list">
                  <div class="setting-row update-auto-row">
                    <div class="setting-copy"><label>每日自动更新</label><p>每天 04:00 按服务时区检查并应用新镜像；失败时保留当前数据卷。</p></div>
                    <div class="setting-control update-switch"><Clock3 :size="16" /><span>{{ controllerUpdate.autoUpdate ? '已启用' : '已关闭' }}</span><el-switch :model-value="controllerUpdate.autoUpdate" :loading="updateAction === 'auto'" aria-label="每日自动更新" @change="setControllerAutoUpdate" /></div>
                  </div>
                </div>

                <dl class="update-time-list">
                  <div><dt>最近检查</dt><dd>{{ formatUpdateTime(controllerUpdate.checkedAt) }}</dd></div>
                  <div><dt>最近更新</dt><dd>{{ formatUpdateTime(controllerUpdate.updatedAt) }}</dd></div>
                  <div><dt>下次自动更新</dt><dd>{{ controllerUpdate.autoUpdate ? formatUpdateTime(controllerUpdate.nextAutoUpdateAt) : '自动更新未启用' }}</dd></div>
                </dl>

                <section class="update-services" aria-labelledby="update-services-title">
                  <div class="update-services-head"><div><ServerCog :size="16" /><strong id="update-services-title">总控服务</strong></div><span>{{ controllerUpdate.services.length }} 个组件</span></div>
                  <div v-if="controllerUpdate.services.length" class="update-service-list">
                    <div v-for="service in controllerUpdate.services" :key="service.name">
                      <span><i :data-health="service.health" />{{ serviceName(service.name) }}</span>
                      <code :title="service.revision">{{ shortRevision(service.revision) }}</code>
                      <small>{{ healthText(service.health) }}</small>
                    </div>
                  </div>
                  <p v-else class="update-services-empty">尚未检测到运行中的总控组件。</p>
                </section>

                <div v-if="updateError" class="update-inline-error" role="alert">{{ updateError }}</div>
                <div class="settings-section-actions update-actions">
                  <p>更新过程不会修改 PostgreSQL 和 Redis 数据卷。</p>
                  <div>
                    <el-button :loading="updateAction === 'check'" :disabled="shouldPollUpdate(controllerUpdate.state)" @click="checkControllerUpdate"><RefreshCw :size="15" />检查更新</el-button>
                    <el-button type="primary" :loading="updateAction === 'apply'" :disabled="!controllerUpdate.updateAvailable || shouldPollUpdate(controllerUpdate.state)" @click="applyControllerUpdate"><Download :size="15" />立即更新</el-button>
                  </div>
                </div>
              </template>
            </div>
          </template>
        </main>
      </div>

      <el-dialog v-model="tokenDialog" title="创建 API Token" width="min(620px, calc(100vw - 28px))" destroy-on-close>
        <el-form label-position="top">
          <el-form-item label="Token 名称" required><el-input v-model="tokenForm.name" maxlength="128" placeholder="例如：鸿蒙移动端只读" /></el-form-item>
          <el-form-item label="权限范围" required><el-checkbox-group v-model="tokenForm.scopes" class="token-scope-grid">
            <el-checkbox v-for="[value, label] in scopes" :key="value" :value="value">{{ label }}</el-checkbox>
          </el-checkbox-group></el-form-item>
          <el-form-item label="服务器 ID 白名单"><el-input v-model="tokenForm.serverIds" placeholder="多个 ID 使用英文逗号分隔，留空表示不额外限制" /></el-form-item>
          <el-form-item label="有效期"><el-input-number v-model="tokenForm.expiresInDays" :min="0" :max="3650" /><span class="field-suffix">天，0 表示永不过期</span></el-form-item>
        </el-form>
        <template #footer><el-button @click="tokenDialog = false">取消</el-button><el-button type="primary" :loading="tokenSaving" @click="createApiToken">创建并显示 Token</el-button></template>
      </el-dialog>

      <el-dialog :model-value="Boolean(createdToken)" title="保存 API Token 明文" width="min(620px, calc(100vw - 28px))" :close-on-click-modal="false" @update:model-value="(value: boolean) => { if (!value) createdToken = null }">
        <div v-if="createdToken" class="credential-panel"><div class="credential-warning"><KeyRound :size="18" /><p><strong>明文只显示这一次</strong><span>关闭窗口后无法再次查看，请立即复制并保存到安全的密钥管理器。</span></p></div><dl><div><dt>Token</dt><dd class="mono-value">{{ createdToken.secret }}</dd></div><div><dt>权限</dt><dd>{{ createdToken.token.scopes.join('、') }}</dd></div></dl></div>
        <template #footer><el-button @click="createdToken = null">我已保存</el-button><el-button type="primary" @click="copyApiToken"><Copy :size="16" />复制 Token</el-button></template>
      </el-dialog>
    </template>
  </section>
</template>
