<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { Activity, ArrowRight, Eye, EyeOff, FileKey2, LockKeyhole, ShieldCheck } from 'lucide-vue-next'
import { api, errorMessage, getSetupStatus } from '@/lib/api'
import { loadBranding, siteName } from '@/lib/branding'
import type { SetupRequest } from '@/types'

const submitting = ref(false)
const error = ref('')
const revealAdminPassword = ref(false)
const router = useRouter()

const initialOrigin = window.location.origin === 'http://localhost:5173' ? 'http://localhost:18080' : window.location.origin
const form = reactive<SetupRequest>({
  publicBaseUrl: initialOrigin,
  allowedOrigins: initialOrigin,
  siteName: '观澜监控',
  timezone: 'Asia/Shanghai',
  adminUsername: 'admin',
  adminPassword: '',
  adminPasswordConfirm: '',
})

function validateForm() {
  if (!form.publicBaseUrl.trim() || !form.allowedOrigins.trim() || !form.siteName.trim() || !form.timezone.trim() || !form.adminUsername.trim() || form.adminPassword.length < 12 || form.adminPassword !== form.adminPasswordConfirm) {
    error.value = '请完成站点和管理员信息，并确认管理员密码至少 12 位且两次一致'
    return false
  }
  return true
}

async function completeSetup() {
  error.value = ''
  if (!validateForm()) return
  submitting.value = true
  try {
    await api.post('/setup/complete', form, { timeout: 60_000 })
    await router.replace({ name: 'login' })
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    submitting.value = false
  }
}

onMounted(async () => {
  loadBranding()
  try {
    const status = await getSetupStatus()
    if (status.configured && status.state !== 'error') await router.replace({ name: 'login' })
    if (status.state === 'error') error.value = status.message ?? '服务启动失败，请重新提交配置'
  } catch { }
})
</script>

<template>
  <main class="setup-page">
    <header class="auth-topbar setup-topbar">
      <RouterLink class="brand auth-brand" to="/login">
        <span class="brand-mark"><Activity :size="19" /></span>
        <span><strong>{{ siteName }}</strong><small>PRIVATE OPS</small></span>
      </RouterLink>
      <span class="setup-topbar-label">首次运行安装向导</span>
    </header>

    <div class="setup-layout setup-wizard-layout">
      <aside class="setup-intro">
        <span class="setup-intro-icon"><FileKey2 :size="22" /></span>
        <p class="eyebrow">FIRST-RUN SETUP</p>
        <h1>先把边界<br>配置清楚</h1>
        <p class="setup-intro-copy">配置站点入口和管理员账号，完成后即可登录并接入服务器。</p>
        <div class="setup-security-note"><LockKeyhole :size="15" /><span>PostgreSQL 仅在 Docker 内网运行，数据库密码由安装器自动生成并保存在服务器私有配置。</span></div>
      </aside>

      <section class="setup-workspace setup-wizard" aria-label="首次运行安装向导">
        <div class="setup-wizard-head">
            <div>
              <p class="eyebrow">FIRST-RUN CONFIGURATION</p>
              <h2>设置站点与管理员</h2>
            </div>
            <span class="setup-wizard-state">未完成</span>
        </div>

        <form class="setup-form" novalidate @submit.prevent="completeSetup">
            <div class="setup-form-section">
              <div class="setup-form-copy"><ShieldCheck :size="18" /><div><h3>完成首次配置</h3><p>内置 PostgreSQL 已就绪。这里只需设置站点入口和首个管理员，表结构会在启动时自动创建。</p></div></div>
              <div class="setup-form-grid setup-form-grid-two">
                <label class="setup-field setup-field-wide"><span>公网入口</span><input v-model="form.publicBaseUrl" type="url" autocomplete="url" placeholder="https://monitor.example.com" /></label>
                <label class="setup-field setup-field-wide"><span>允许的 Web 来源</span><input v-model="form.allowedOrigins" autocomplete="url" placeholder="https://monitor.example.com" /></label>
                <label class="setup-field"><span>站点名称</span><input v-model="form.siteName" autocomplete="organization" /></label>
                <label class="setup-field"><span>服务时区</span><input v-model="form.timezone" autocomplete="off" placeholder="Asia/Shanghai" /></label>
                <label class="setup-field"><span>管理员用户名</span><input v-model="form.adminUsername" autocomplete="username" /></label>
                <label class="setup-field"><span>管理员密码</span><div class="setup-secret-field"><input v-model="form.adminPassword" :type="revealAdminPassword ? 'text' : 'password'" autocomplete="new-password" /><button type="button" :aria-label="revealAdminPassword ? '隐藏管理员密码' : '显示管理员密码'" :title="revealAdminPassword ? '隐藏密码' : '显示密码'" @click="revealAdminPassword = !revealAdminPassword"><EyeOff v-if="revealAdminPassword" :size="16" /><Eye v-else :size="16" /></button></div></label>
                <label class="setup-field"><span>再次输入管理员密码</span><input v-model="form.adminPasswordConfirm" type="password" autocomplete="new-password" /></label>
              </div>
            </div>

            <p v-if="error" class="form-error setup-form-error" role="alert">{{ error }}</p>
            <div class="setup-form-actions">
              <span class="setup-form-spacer" />
              <button class="primary-command button-press" type="submit" :disabled="submitting">
                <span v-if="submitting" class="spinner" />
                <span>{{ submitting ? '正在保存配置' : '完成安装并启动' }}</span>
                <ArrowRight v-if="!submitting" :size="16" />
              </button>
            </div>
        </form>
      </section>
    </div>
  </main>
</template>
