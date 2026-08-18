<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { Activity, ArrowLeft, ArrowRight, CheckCircle2, Database, Eye, EyeOff, FileKey2, Globe2, KeyRound, LockKeyhole, ServerCog, ShieldCheck } from 'lucide-vue-next'
import { api, errorMessage, getSetupStatus, testSetupDatabase } from '@/lib/api'
import type { SetupRequest, SetupStatus } from '@/types'

const currentStep = ref(0)
const testingDatabase = ref(false)
const submitting = ref(false)
const completed = ref(false)
const error = ref('')
const reveal = reactive({ adminDatabase: false, appDatabase: false, admin: false })
const setupStatus = ref<SetupStatus | null>(null)

const initialOrigin = window.location.origin === 'http://localhost:5173' ? 'http://localhost:18080' : window.location.origin
const form = reactive<SetupRequest>({
  mysqlAdminHost: 'host.docker.internal',
  mysqlAdminPort: 3306,
  mysqlAdminUsername: '',
  mysqlAdminPassword: '',
  mysqlAppHost: 'host.docker.internal',
  mysqlAppPort: 3306,
  databaseName: 'monitor',
  appUsername: 'monitor',
  appPassword: '',
  appPasswordConfirm: '',
  publicBaseUrl: initialOrigin,
  allowedOrigins: initialOrigin,
  siteName: '观澜监控',
  timezone: 'Asia/Shanghai',
  webPort: 18080,
  webBindAddress: '0.0.0.0',
  adminUsername: 'admin',
  adminPassword: '',
  adminPasswordConfirm: '',
})

const steps = [
  { title: '检测 MySQL', caption: '连接信息', icon: ServerCog },
  { title: '创建应用账号', caption: '授权信息', icon: Database },
  { title: '设置管理员', caption: '站点入口', icon: ShieldCheck },
]
const currentTitle = computed(() => steps[currentStep.value]?.title ?? '完成安装')

function messageFor(cause: unknown) {
  error.value = errorMessage(cause)
}

function validateStep(step: number) {
  if (step === 0 && (!form.mysqlAdminHost.trim() || !form.mysqlAdminPort || !form.databaseName.trim() || !form.mysqlAdminUsername.trim() || !form.mysqlAdminPassword)) {
    error.value = '请填写 MySQL 地址、端口、数据库名、用户名和密码'
    return false
  }
  if (step === 1 && (!form.mysqlAppHost.trim() || !form.mysqlAppPort || !form.appUsername.trim() || form.appPassword.length < 12 || form.appPassword !== form.appPasswordConfirm)) {
    error.value = '请填写应用连接信息，并确认应用密码至少 12 位且两次一致'
    return false
  }
  if (step === 2 && (!form.publicBaseUrl.trim() || !form.allowedOrigins.trim() || !form.siteName.trim() || !form.timezone.trim() || !form.adminUsername.trim() || form.adminPassword.length < 12 || form.adminPassword !== form.adminPasswordConfirm)) {
    error.value = '请完成站点和管理员信息，并确认管理员密码至少 12 位且两次一致'
    return false
  }
  return true
}

async function testDatabase() {
  if (!validateStep(0)) return
  testingDatabase.value = true
  error.value = ''
  try {
    await testSetupDatabase(form)
    if (form.mysqlAppHost === 'host.docker.internal' && form.mysqlAppPort === 3306) {
      form.mysqlAppHost = form.mysqlAdminHost
      form.mysqlAppPort = form.mysqlAdminPort
    }
    currentStep.value = 1
  } catch (cause) {
    messageFor(cause)
  } finally {
    testingDatabase.value = false
  }
}

function nextStep() {
  error.value = ''
  if (currentStep.value === 0) return testDatabase()
  if (!validateStep(currentStep.value)) return
  if (currentStep.value < 2) currentStep.value += 1
  else completeSetup()
}

function previousStep() {
  error.value = ''
  if (currentStep.value > 0) currentStep.value -= 1
}

async function completeSetup() {
  submitting.value = true
  error.value = ''
  try {
    await api.post<SetupStatus>('/setup/complete', form, { timeout: 60_000 })
    completed.value = true
    currentStep.value = 3
    await waitForService()
  } catch (cause) {
    messageFor(cause)
  } finally {
    submitting.value = false
  }
}

async function waitForService() {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    await new Promise(resolve => window.setTimeout(resolve, 1500))
    try {
      const status = await getSetupStatus()
      setupStatus.value = status
      if (status.state === 'error') {
        error.value = status.message ?? '服务重建失败，请检查 Docker 日志'
        return
      }
      if (status.configured) return
    } catch {
      // The web container may briefly restart while the production server is recreated.
    }
  }
}

onMounted(async () => {
  try {
    setupStatus.value = await getSetupStatus()
    if (setupStatus.value.configured) completed.value = true
  } catch {
    setupStatus.value = { configured: false, state: 'unavailable', message: '安装服务暂不可用' }
  }
})
</script>

<template>
  <main class="setup-page">
    <header class="auth-topbar setup-topbar">
      <RouterLink class="brand auth-brand" to="/login">
        <span class="brand-mark"><Activity :size="19" /></span>
        <span><strong>观澜监控</strong><small>PRIVATE OPS</small></span>
      </RouterLink>
      <span class="setup-topbar-label">首次运行安装向导</span>
    </header>

    <div class="setup-layout setup-wizard-layout">
      <aside class="setup-intro">
        <span class="setup-intro-icon"><FileKey2 :size="22" /></span>
        <p class="eyebrow">FIRST-RUN SETUP</p>
        <h1>先把边界<br>配置清楚</h1>
        <p class="setup-intro-copy">这是总终端第一次运行时的安装向导。配置会写入服务器本地，完成后才开放登录和监控数据。</p>
        <div class="setup-security-note"><LockKeyhole :size="15" /><span>MySQL 管理密码只用于本次建库，不会写入配置文件，也不会进入日志。</span></div>
      </aside>

      <section class="setup-workspace setup-wizard" aria-label="首次运行安装向导">
        <div v-if="completed" class="setup-complete-state">
          <span class="setup-complete-icon"><CheckCircle2 :size="25" /></span>
          <p class="eyebrow">READY TO SIGN IN</p>
          <h2>{{ setupStatus?.state === 'error' ? '配置已保存，服务需要检查' : '总终端正在切换到生产配置' }}</h2>
          <p>{{ error || '数据库和管理员信息已保存。服务重建完成后即可登录控制台。' }}</p>
          <a class="primary-command button-press" :href="setupStatus?.baseUrl || form.publicBaseUrl"><Globe2 :size="16" />打开站点</a>
          <RouterLink class="setup-login-link setup-complete-login" to="/login">前往登录 <ArrowRight :size="15" /></RouterLink>
        </div>

        <template v-else>
          <div class="setup-wizard-head">
            <div>
              <p class="eyebrow">STEP {{ currentStep + 1 }} OF 3</p>
              <h2>{{ currentTitle }}</h2>
            </div>
            <span class="setup-wizard-state">未完成</span>
          </div>

          <div class="setup-progress" aria-label="安装步骤">
            <div v-for="(step, index) in steps" :key="step.title" class="setup-progress-item" :data-active="index === currentStep" :data-done="index < currentStep">
              <span>{{ index < currentStep ? '✓' : `0${index + 1}` }}</span>
              <strong>{{ step.title }}</strong>
              <small>{{ step.caption }}</small>
            </div>
          </div>

          <form class="setup-form" novalidate @submit.prevent="nextStep">
            <div v-if="currentStep === 0" class="setup-form-section">
              <div class="setup-form-copy"><Database :size="18" /><div><h3>填写 MySQL 连接信息并检测</h3><p>一次填写访问地址、端口、目标数据库名、用户名和密码。数据库不存在时，后续步骤会自动创建；已存在的数据库不会被覆盖。</p></div></div>
              <div class="setup-form-grid setup-form-grid-two">
                <label class="setup-field"><span>MySQL 访问地址</span><input v-model="form.mysqlAdminHost" autocomplete="off" placeholder="host.docker.internal" /></label>
                <label class="setup-field"><span>MySQL 端口</span><input v-model.number="form.mysqlAdminPort" type="number" min="1" max="65535" inputmode="numeric" placeholder="3306" /></label>
                <label class="setup-field"><span>目标数据库名</span><input v-model="form.databaseName" autocomplete="off" placeholder="monitor" /></label>
                <label class="setup-field"><span>MySQL 用户名</span><input v-model="form.mysqlAdminUsername" autocomplete="username" placeholder="root" /></label>
                <label class="setup-field"><span>MySQL 密码</span><div class="setup-secret-field"><input v-model="form.mysqlAdminPassword" :type="reveal.adminDatabase ? 'text' : 'password'" autocomplete="current-password" /><button type="button" :aria-label="reveal.adminDatabase ? '隐藏 MySQL 密码' : '显示 MySQL 密码'" :title="reveal.adminDatabase ? '隐藏密码' : '显示密码'" @click="reveal.adminDatabase = !reveal.adminDatabase"><EyeOff v-if="reveal.adminDatabase" :size="16" /><Eye v-else :size="16" /></button></div></label>
              </div>
              <p class="setup-inline-note"><KeyRound :size="15" />同机 MySQL 请使用 <code>host.docker.internal</code>，不要填写容器内的 <code>127.0.0.1</code>。点击继续会先检测连接和数据库名。</p>
            </div>

            <div v-else-if="currentStep === 1" class="setup-form-section">
              <div class="setup-form-copy"><Database :size="18" /><div><h3>设置应用连接和账号</h3><p>管理连接已通过检测。这里设置服务容器连接 MySQL 的地址，以及安装器创建的应用账号和授权密码。地址和端口默认沿用上一步，可按容器网络调整。</p></div></div>
              <div class="setup-form-grid setup-form-grid-two">
                <label class="setup-field"><span>容器连接地址</span><input v-model="form.mysqlAppHost" autocomplete="off" placeholder="host.docker.internal" /></label>
                <label class="setup-field"><span>容器连接端口</span><input v-model.number="form.mysqlAppPort" type="number" min="1" max="65535" inputmode="numeric" /></label>
                <label class="setup-field"><span>新应用用户名</span><input v-model="form.appUsername" autocomplete="off" placeholder="monitor" /></label>
                <label class="setup-field"><span>应用数据库密码</span><div class="setup-secret-field"><input v-model="form.appPassword" :type="reveal.appDatabase ? 'text' : 'password'" autocomplete="new-password" /><button type="button" :aria-label="reveal.appDatabase ? '隐藏应用数据库密码' : '显示应用数据库密码'" :title="reveal.appDatabase ? '隐藏密码' : '显示密码'" @click="reveal.appDatabase = !reveal.appDatabase"><EyeOff v-if="reveal.appDatabase" :size="16" /><Eye v-else :size="16" /></button></div></label>
                <label class="setup-field"><span>再次输入应用密码</span><input v-model="form.appPasswordConfirm" type="password" autocomplete="new-password" /></label>
              </div>
            </div>

            <div v-else class="setup-form-section">
              <div class="setup-form-copy"><ShieldCheck :size="18" /><div><h3>设置管理员和站点入口</h3><p>管理员账号会在生产数据库迁移完成后创建。登录后仍可在系统设置中修改站点和通知信息。</p></div></div>
              <div class="setup-form-grid setup-form-grid-two">
                <label class="setup-field setup-field-wide"><span>公网入口</span><input v-model="form.publicBaseUrl" type="url" autocomplete="url" placeholder="https://monitor.example.com" /></label>
                <label class="setup-field setup-field-wide"><span>允许的 Web 来源</span><input v-model="form.allowedOrigins" autocomplete="url" placeholder="https://monitor.example.com" /></label>
                <label class="setup-field"><span>站点名称</span><input v-model="form.siteName" autocomplete="organization" /></label>
                <label class="setup-field"><span>服务时区</span><input v-model="form.timezone" autocomplete="off" placeholder="Asia/Shanghai" /></label>
                <label class="setup-field"><span>Web 端口</span><input v-model.number="form.webPort" type="number" min="1" max="65535" inputmode="numeric" /></label>
                <label class="setup-field"><span>Web 绑定地址</span><select v-model="form.webBindAddress"><option value="0.0.0.0">0.0.0.0（允许 IP 直连）</option><option value="127.0.0.1">127.0.0.1（仅宝塔反代）</option></select></label>
                <label class="setup-field"><span>管理员用户名</span><input v-model="form.adminUsername" autocomplete="username" /></label>
                <label class="setup-field"><span>管理员密码</span><div class="setup-secret-field"><input v-model="form.adminPassword" :type="reveal.admin ? 'text' : 'password'" autocomplete="new-password" /><button type="button" :aria-label="reveal.admin ? '隐藏管理员密码' : '显示管理员密码'" :title="reveal.admin ? '隐藏密码' : '显示密码'" @click="reveal.admin = !reveal.admin"><EyeOff v-if="reveal.admin" :size="16" /><Eye v-else :size="16" /></button></div></label>
                <label class="setup-field"><span>再次输入管理员密码</span><input v-model="form.adminPasswordConfirm" type="password" autocomplete="new-password" /></label>
              </div>
            </div>

            <p v-if="error" class="form-error setup-form-error" role="alert">{{ error }}</p>
            <div class="setup-form-actions">
              <button v-if="currentStep > 0" class="setup-secondary-command" type="button" @click="previousStep"><ArrowLeft :size="16" />上一步</button>
              <span v-else class="setup-form-spacer" />
              <button class="primary-command button-press" type="submit" :disabled="testingDatabase || submitting">
                <span v-if="testingDatabase || submitting" class="spinner" />
                <span>{{ testingDatabase ? '正在测试连接' : submitting ? '正在保存配置' : currentStep === 2 ? '完成安装并启动' : '继续' }}</span>
                <ArrowRight v-if="!testingDatabase && !submitting" :size="16" />
              </button>
            </div>
          </form>
        </template>
      </section>
    </div>
  </main>
</template>
