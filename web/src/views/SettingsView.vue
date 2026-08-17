<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { BellRing, Database, Mail, MessageSquareText, RefreshCw, Save, TimerReset } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import type { Settings } from '@/types'

const settings = ref<Settings | null>(null)
const form = reactive({ metricRetentionDays: 30, deviceOfflineAfterSeconds: 30, defaultCollectionSeconds: 3 })
const loading = ref(true)
const saving = ref(false)
const error = ref('')

async function load() {
  loading.value = true
  error.value = ''
  try {
    settings.value = (await api.get<Settings>('/settings')).data
    Object.assign(form, {
      metricRetentionDays: settings.value.metricRetentionDays,
      deviceOfflineAfterSeconds: settings.value.deviceOfflineAfterSeconds,
      defaultCollectionSeconds: settings.value.defaultCollectionSeconds,
    })
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
    Object.assign(form, {
      metricRetentionDays: settings.value.metricRetentionDays,
      deviceOfflineAfterSeconds: settings.value.deviceOfflineAfterSeconds,
      defaultCollectionSeconds: settings.value.defaultCollectionSeconds,
    })
    ElMessage.success('系统设置已保存')
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    saving.value = false
  }
}

onMounted(load)
</script>

<template>
  <section>
    <PageHeader eyebrow="SYSTEM POLICY" title="系统设置" description="调整数据留存、设备离线判定和默认采集周期。通知凭据仍由部署环境变量管理。">
      <template #actions><el-button @click="load"><RefreshCw :size="16" />重置</el-button><el-button type="primary" class="button-press" :loading="saving" @click="save"><Save :size="16" />保存设置</el-button></template>
    </PageHeader>
    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel"><EmptyState title="设置加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState></div>
    <template v-else-if="settings">
      <div class="settings-layout">
        <article class="panel settings-panel">
          <div class="panel-head"><div><h2>监控策略</h2><p>修改后由服务端任务和新接入 Agent 使用</p></div><TimerReset :size="17" /></div>
          <el-form label-position="top" class="settings-form">
            <el-form-item label="指标留存天数"><el-input-number v-model="form.metricRetentionDays" :min="1" :max="3650" /><p class="field-help">过期的历史指标会由后台定时任务清理，告警与审计记录不受影响。</p></el-form-item>
            <el-form-item label="离线判定秒数"><el-input-number v-model="form.deviceOfflineAfterSeconds" :min="5" :max="3600" /><p class="field-help">超过该时长未收到 Agent 上报时，将设备标记为离线并评估离线规则。</p></el-form-item>
            <el-form-item label="默认采集周期"><el-segmented v-model="form.defaultCollectionSeconds" :options="[{ label: '1 秒', value: 1 }, { label: '3 秒', value: 3 }, { label: '10 秒', value: 10 }]" /><p class="field-help">用于生成 Agent 推荐配置；已部署 Agent 仍以本机配置为准。</p></el-form-item>
          </el-form>
        </article>

        <article class="panel settings-panel">
          <div class="panel-head"><div><h2>数据与安全</h2><p>当前服务端执行边界</p></div><Database :size="17" /></div>
          <div class="policy-list">
            <div><Database :size="17" /><span><strong>时序指标</strong><small>存储于私有 MySQL，按设置周期清理</small></span></div>
            <div><BellRing :size="17" /><span><strong>在线状态</strong><small>Redis 加速读取，数据库保留最终状态</small></span></div>
            <div><TimerReset :size="17" /><span><strong>审计追踪</strong><small>设备、规则、账号和设置变更均记录操作者</small></span></div>
          </div>
        </article>
      </div>

      <section class="section">
        <div class="section-heading"><div><h2>通知通道</h2><p>通道密钥必须通过服务端环境变量注入，网页不读取也不保存凭据</p></div></div>
        <div class="channel-grid">
          <article class="panel channel-card"><span><Mail :size="19" /></span><div><strong>邮件通知</strong><small>SMTP 与收件人配置</small></div><StatusBadge :status="settings.emailConfigured ? 'ONLINE' : 'OFFLINE'" /></article>
          <article class="panel channel-card"><span><MessageSquareText :size="19" /></span><div><strong>钉钉机器人</strong><small>Webhook 告警推送</small></div><StatusBadge :status="settings.dingtalkConfigured ? 'ONLINE' : 'OFFLINE'" /></article>
          <article class="panel channel-card"><span><MessageSquareText :size="19" /></span><div><strong>企业微信机器人</strong><small>Webhook 告警推送</small></div><StatusBadge :status="settings.wecomConfigured ? 'ONLINE' : 'OFFLINE'" /></article>
        </div>
      </section>
    </template>
  </section>
</template>
