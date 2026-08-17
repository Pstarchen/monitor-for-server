<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import {
  BellRing, Database, Globe2, KeyRound, LockKeyhole, Mail, MessageSquareText,
  RefreshCw, Save, Send, ShieldCheck, TimerReset,
} from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import type { Settings, WebhookSettings } from '@/types'

type ChannelKey = 'email' | 'dingtalk' | 'wecom'

const settings = ref<Settings | null>(null)
const form = reactive({
  metricRetentionDays: 30,
  deviceOfflineAfterSeconds: 30,
  defaultCollectionSeconds: 3,
  siteName: '观澜监控',
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

async function save() {
  saving.value = true
  try {
    settings.value = (await api.put<Settings>('/settings', form)).data
    apply(settings.value)
    ElMessage.success('系统与通知设置已保存')
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

onMounted(load)
</script>

<template>
  <section>
    <PageHeader eyebrow="SYSTEM POLICY" title="系统设置" description="集中管理数据策略、部署入口与告警通知。">
      <template #actions>
        <el-button @click="load"><RefreshCw :size="16" />重置</el-button>
        <el-button type="primary" class="button-press" :loading="saving" @click="save"><Save :size="16" />保存设置</el-button>
      </template>
    </PageHeader>

    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel">
      <EmptyState title="设置加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState>
    </div>

    <template v-else-if="settings">
      <div v-if="!settings.secretStorageReady" class="settings-notice" role="status">
        <LockKeyhole :size="18" />
        <div><strong>通知凭据暂不可写入</strong><p>部署端尚未配置 SETTINGS_ENCRYPTION_KEY；现有环境变量通道仍可继续使用。</p></div>
      </div>

      <div class="settings-layout">
        <article class="panel settings-panel">
          <div class="panel-head"><div><h2>监控策略</h2><p>历史数据与在线状态判定</p></div><TimerReset :size="17" /></div>
          <el-form label-position="top" class="settings-form">
            <el-form-item label="指标留存天数">
              <el-input-number v-model="form.metricRetentionDays" :min="1" :max="3650" />
              <p class="field-help">过期指标由后台定时清理，告警与审计记录不受影响。</p>
            </el-form-item>
            <el-form-item label="离线判定秒数">
              <el-input-number v-model="form.deviceOfflineAfterSeconds" :min="5" :max="3600" />
              <p class="field-help">超过该时长未收到上报时，设备进入离线状态并评估离线规则。</p>
            </el-form-item>
            <el-form-item label="默认采集周期">
              <el-segmented v-model="form.defaultCollectionSeconds" :options="[{ label: '1 秒', value: 1 }, { label: '3 秒', value: 3 }, { label: '10 秒', value: 10 }, { label: '30 秒', value: 30 }]" />
            </el-form-item>
          </el-form>
        </article>

        <article class="panel settings-panel">
          <div class="panel-head"><div><h2>站点与部署</h2><p>Agent 安装向导使用的公共入口</p></div><Globe2 :size="17" /></div>
          <el-form label-position="top" class="settings-form">
            <el-form-item label="站点名称"><el-input v-model="form.siteName" maxlength="60" /></el-form-item>
            <el-form-item label="公网入口">
              <el-input v-model="form.publicBaseUrl" placeholder="https://monitor.example.com" />
              <p class="field-help">生产环境使用 HTTPS 完整地址；留空时安装向导使用当前浏览器地址。</p>
            </el-form-item>
            <el-form-item label="服务时区"><el-input v-model="form.timezone" placeholder="Asia/Shanghai" /></el-form-item>
          </el-form>
        </article>
      </div>

      <section class="section">
        <div class="section-heading"><div><h2>通知通道</h2><p>密钥仅支持替换或清除，保存后不会再次返回明文</p></div><BellRing :size="17" /></div>

        <article class="panel channel-config channel-email">
          <div class="channel-config-head">
            <span class="channel-icon"><Mail :size="19" /></span>
            <div><h3>邮件通知</h3><p>{{ sourceText(settings.email.source) }}</p></div>
            <StatusBadge :status="channelStatus(settings.email)" />
            <el-switch v-model="form.email.enabled" aria-label="启用邮件通知" />
          </div>
          <el-form label-position="top" class="settings-form channel-form">
            <div class="form-grid channel-email-grid">
              <el-form-item label="SMTP 主机"><el-input v-model="form.email.host" placeholder="smtp.example.com" /></el-form-item>
              <el-form-item label="端口"><el-input-number v-model="form.email.port" :min="1" :max="65535" /></el-form-item>
              <el-form-item label="用户名"><el-input v-model="form.email.username" autocomplete="off" /></el-form-item>
              <el-form-item label="密码">
                <el-input v-model="form.email.password" type="password" show-password autocomplete="new-password" :disabled="!settings.secretStorageReady" :placeholder="settings.email.passwordConfigured ? '留空则保留现有密码' : '输入 SMTP 密码'" />
                <el-checkbox v-if="settings.email.source === 'DATABASE'" v-model="form.email.clearPassword" class="secret-clear">清除已保存密码</el-checkbox>
              </el-form-item>
              <el-form-item label="发件人"><el-input v-model="form.email.from" placeholder="monitor@example.com" /></el-form-item>
              <el-form-item label="收件人"><el-input v-model="form.email.recipients" placeholder="ops@example.com, owner@example.com" /></el-form-item>
            </div>
            <div class="channel-options">
              <el-checkbox v-model="form.email.auth">SMTP 身份验证</el-checkbox>
              <el-checkbox v-model="form.email.startTls">STARTTLS</el-checkbox>
              <el-button :disabled="!settings.email.enabled || !settings.email.configured" :loading="testing.email" @click="testChannel('email')"><Send :size="15" />发送测试</el-button>
            </div>
          </el-form>
        </article>

        <div class="webhook-grid">
          <article class="panel channel-config">
            <div class="channel-config-head">
              <span class="channel-icon"><MessageSquareText :size="19" /></span>
              <div><h3>钉钉机器人</h3><p>{{ sourceText(settings.dingtalk.source) }}</p></div>
              <StatusBadge :status="channelStatus(settings.dingtalk)" />
              <el-switch v-model="form.dingtalk.enabled" aria-label="启用钉钉通知" />
            </div>
            <el-form label-position="top" class="settings-form channel-form">
              <el-form-item label="Webhook">
                <el-input v-model="form.dingtalk.webhookUrl" type="password" show-password autocomplete="new-password" :disabled="!settings.secretStorageReady" :placeholder="settings.dingtalk.webhookConfigured ? '留空则保留现有地址' : 'https://oapi.dingtalk.com/...'" />
                <el-checkbox v-if="settings.dingtalk.source === 'DATABASE'" v-model="form.dingtalk.clearWebhook" class="secret-clear">清除已保存地址</el-checkbox>
              </el-form-item>
              <div class="channel-options channel-options-end"><el-button :disabled="!settings.dingtalk.enabled || !settings.dingtalk.configured" :loading="testing.dingtalk" @click="testChannel('dingtalk')"><Send :size="15" />发送测试</el-button></div>
            </el-form>
          </article>

          <article class="panel channel-config">
            <div class="channel-config-head">
              <span class="channel-icon"><MessageSquareText :size="19" /></span>
              <div><h3>企业微信机器人</h3><p>{{ sourceText(settings.wecom.source) }}</p></div>
              <StatusBadge :status="channelStatus(settings.wecom)" />
              <el-switch v-model="form.wecom.enabled" aria-label="启用企业微信通知" />
            </div>
            <el-form label-position="top" class="settings-form channel-form">
              <el-form-item label="Webhook">
                <el-input v-model="form.wecom.webhookUrl" type="password" show-password autocomplete="new-password" :disabled="!settings.secretStorageReady" :placeholder="settings.wecom.webhookConfigured ? '留空则保留现有地址' : 'https://qyapi.weixin.qq.com/...'" />
                <el-checkbox v-if="settings.wecom.source === 'DATABASE'" v-model="form.wecom.clearWebhook" class="secret-clear">清除已保存地址</el-checkbox>
              </el-form-item>
              <div class="channel-options channel-options-end"><el-button :disabled="!settings.wecom.enabled || !settings.wecom.configured" :loading="testing.wecom" @click="testChannel('wecom')"><Send :size="15" />发送测试</el-button></div>
            </el-form>
          </article>
        </div>
      </section>

      <section class="section policy-band">
        <div><Database :size="17" /><span><strong>指标存储</strong><small>私有数据库留存</small></span></div>
        <div><ShieldCheck :size="17" /><span><strong>凭据保护</strong><small>AES-GCM 加密</small></span></div>
        <div><KeyRound :size="17" /><span><strong>审计追踪</strong><small>保存与测试均留痕</small></span></div>
      </section>
    </template>
  </section>
</template>
