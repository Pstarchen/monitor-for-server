<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { onBeforeRouteLeave } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import {
  Activity, CheckCircle2, ChevronRight, Database, Globe2, KeyRound, LockKeyhole,
  Mail, MessageSquareText, RotateCcw, Save, Send, Settings2, ShieldCheck,
} from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { loadBranding } from '@/lib/branding'
import type { Settings, WebhookSettings } from '@/types'

type ChannelKey = 'email' | 'dingtalk' | 'wecom'
type SectionKey = 'general' | 'monitoring' | ChannelKey | 'security'

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
  publicBaseUrl: '',
  timezone: 'Asia/Shanghai',
  email: {
    enabled: false, host: '', port: 587, username: '', password: '', clearPassword: false,
    from: '', recipients: '', auth: true, startTls: true,
  },
  dingtalk: { enabled: false, webhookUrl: '', clearWebhook: false },
  wecom: { enabled: false, webhookUrl: '', clearWebhook: false },
})
const loading = ref(true)
const saving = ref(false)
const error = ref('')
const testing = reactive<Record<ChannelKey, boolean>>({ email: false, dingtalk: false, wecom: false })
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
    publicBaseUrl: value.publicBaseUrl,
    timezone: value.timezone,
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
  if (!settings.value || !['email', 'dingtalk', 'wecom'].includes(key)) return ''
  const channel = settings.value[key as ChannelKey]
  if (!channel.enabled) return 'disabled'
  return channel.configured ? 'ready' : 'attention'
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

onMounted(load)
</script>

<template>
  <section>
    <PageHeader eyebrow="SETTINGS" title="系统设置" description="管理监控行为、公共入口与通知渠道。">
      <template #actions>
        <div class="settings-page-actions">
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
                  <div class="setting-copy"><label for="public-url">公网入口</label><p>用于生成 Agent 安装命令，生产环境应使用 HTTPS。</p></div>
                  <div class="setting-control"><el-input id="public-url" v-model="form.publicBaseUrl" placeholder="https://monitor.example.com" /></div>
                </div>
                <div class="setting-row">
                  <div class="setting-copy"><label for="timezone">服务时区</label><p>应用于后台任务和界面时间显示。</p></div>
                  <div class="setting-control"><el-input id="timezone" v-model="form.timezone" placeholder="Asia/Shanghai" /></div>
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

          <template v-else>
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
        </main>
      </div>
    </template>
  </section>
</template>
