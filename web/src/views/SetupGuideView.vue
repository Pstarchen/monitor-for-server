<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { Activity, AlertCircle, ArrowLeft, ArrowRight, Check, CheckCircle2, Copy, Database, Eye, EyeOff, FileKey2, Globe2, KeyRound, LockKeyhole, ServerCog, ShieldCheck } from 'lucide-vue-next'
import { api, errorMessage, getSetupStatus, setupDatabaseErrorDetails, testSetupDatabase } from '@/lib/api'
import type { SetupRequest, SetupStatus } from '@/types'

const currentStep = ref(0)
const testingDatabase = ref(false)
const submitting = ref(false)
const completed = ref(false)
const error = ref('')
const databaseCheck = ref<'idle' | 'checking' | 'ready' | 'error'>('idle')
const databaseCheckMessage = ref('')
const authorizationSql = ref('')
const authorizationSqlCopied = ref(false)
const reveal = reactive({ database: false, admin: false })
const setupStatus = ref<SetupStatus | null>(null)

const initialOrigin = window.location.origin === 'http://localhost:5173' ? 'http://localhost:18080' : window.location.origin
const form = reactive<SetupRequest>({
  mysqlHost: '',
  mysqlPort: null,
  databaseName: '',
  mysqlUsername: '',
  mysqlPassword: '',
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
  { title: '初始化 MySQL', caption: '连接与表结构', icon: ServerCog },
  { title: '设置管理员', caption: '站点入口', icon: ShieldCheck },
]
const currentTitle = computed(() => steps[currentStep.value]?.title ?? '完成安装')

function messageFor(cause: unknown) {
  error.value = errorMessage(cause)
  authorizationSql.value = setupDatabaseErrorDetails(cause).authorizationSql ?? ''
  authorizationSqlCopied.value = false
}

function validateStep(step: number) {
  if (step === 0 && (!form.mysqlHost.trim() || !form.mysqlPort || !form.databaseName.trim() || !form.mysqlUsername.trim() || !form.mysqlPassword)) {
    error.value = '请填写 MySQL 地址、端口、数据库名、用户名和密码'
    return false
  }
  if (step === 1 && (!form.publicBaseUrl.trim() || !form.allowedOrigins.trim() || !form.siteName.trim() || !form.timezone.trim() || !form.adminUsername.trim() || form.adminPassword.length < 12 || form.adminPassword !== form.adminPasswordConfirm)) {
    error.value = '请完成站点和管理员信息，并确认管理员密码至少 12 位且两次一致'
    return false
  }
  return true
}

async function testDatabase() {
  if (!validateStep(0)) return
  testingDatabase.value = true
  databaseCheck.value = 'checking'
  databaseCheckMessage.value = '正在连接填写的 MySQL 数据库并检查表结构…'
  error.value = ''
  authorizationSql.value = ''
  authorizationSqlCopied.value = false
  try {
    await testSetupDatabase(form)
    databaseCheck.value = 'ready'
    databaseCheckMessage.value = '连接成功，目标数据库和监控表结构已准备好。'
    currentStep.value = 1
  } catch (cause) {
    messageFor(cause)
    databaseCheck.value = 'error'
    databaseCheckMessage.value = error.value
  } finally {
    testingDatabase.value = false
  }
}

async function copyAuthorizationSql() {
  if (!authorizationSql.value || !navigator.clipboard) return
  await navigator.clipboard.writeText(authorizationSql.value)
  authorizationSqlCopied.value = true
}

function nextStep() {
  error.value = ''
  if (currentStep.value === 0) return testDatabase()
  if (!validateStep(currentStep.value)) return
  if (currentStep.value < 1) currentStep.value += 1
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
    currentStep.value = 2
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
        <div class="setup-security-note"><LockKeyhole :size="15" /><span>MySQL 密码只写入总终端主机的私有配置，不会回显到页面或进入日志。</span></div>
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
              <p class="eyebrow">STEP {{ currentStep + 1 }} OF 2</p>
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
              <div class="setup-form-copy"><Database :size="18" /><div><h3>连接 MySQL 并初始化表结构</h3><p>请填写真实可达的 MySQL 地址、端口、数据库名、用户名和密码。数据库由你在 MySQL 管理端准备，向导只负责连接、校验并初始化监控表结构。</p></div></div>
              <div class="setup-form-grid setup-form-grid-two">
                <label class="setup-field"><span>MySQL 访问地址</span><input v-model="form.mysqlHost" autocomplete="off" placeholder="填写容器可访问的主机名或 IP" /></label>
                <label class="setup-field"><span>MySQL 端口</span><input v-model.number="form.mysqlPort" type="number" min="1" max="65535" inputmode="numeric" placeholder="3306" /></label>
                <label class="setup-field"><span>目标数据库名</span><input v-model="form.databaseName" autocomplete="off" placeholder="填写已创建的数据库名" /></label>
                <label class="setup-field"><span>MySQL 用户名</span><input v-model="form.mysqlUsername" autocomplete="username" placeholder="填写已授权的数据库用户" /></label>
                <label class="setup-field"><span>MySQL 密码</span><div class="setup-secret-field"><input v-model="form.mysqlPassword" :type="reveal.database ? 'text' : 'password'" autocomplete="current-password" /><button type="button" :aria-label="reveal.database ? '隐藏 MySQL 密码' : '显示 MySQL 密码'" :title="reveal.database ? '隐藏密码' : '显示密码'" @click="reveal.database = !reveal.database"><EyeOff v-if="reveal.database" :size="16" /><Eye v-else :size="16" /></button></div></label>
              </div>
              <p class="setup-inline-note"><KeyRound :size="15" />地址不会被安装器改写。请填写从总终端容器实际可访问的 MySQL 地址；如果 MySQL 在另一台服务器，填写该服务器的内网 IP 或 DNS。若提示错误码 1130，说明 MySQL 账号的来源主机授权不包含总终端。</p>
              <div v-if="databaseCheck !== 'idle'" class="setup-connection-result" :data-state="databaseCheck" role="status" aria-live="polite">
                <span class="setup-connection-result-icon"><span v-if="databaseCheck === 'checking'" class="spinner" /><CheckCircle2 v-else-if="databaseCheck === 'ready'" :size="16" /><AlertCircle v-else :size="16" /></span>
                <span>{{ databaseCheckMessage }}</span>
              </div>
              <div v-if="authorizationSql" class="setup-authorization-help">
                <div class="setup-authorization-head"><strong>错误码 1130 的处理 SQL</strong><button type="button" class="setup-copy-command" :aria-label="authorizationSqlCopied ? '已复制授权 SQL' : '复制授权 SQL'" :title="authorizationSqlCopied ? '已复制' : '复制授权 SQL'" @click="copyAuthorizationSql"><Check v-if="authorizationSqlCopied" :size="15" /><Copy v-else :size="15" /></button></div>
                <p>请在 MySQL 管理端按实际来源执行，替换允许来源主机和密码占位符；安装器不会替你决定账号来源范围。</p>
                <pre>{{ authorizationSql }}</pre>
              </div>
            </div>

            <div v-else class="setup-form-section">
              <div class="setup-form-copy"><ShieldCheck :size="18" /><div><h3>设置管理员和站点入口</h3><p>管理员账号会在生产数据库迁移完成后创建。数据库连接和表结构已在上一步验证，登录后仍可在系统设置中修改站点和通知信息。</p></div></div>
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

            <p v-if="error && !(currentStep === 0 && databaseCheck === 'error')" class="form-error setup-form-error" role="alert">{{ error }}</p>
            <div class="setup-form-actions">
              <button v-if="currentStep > 0" class="setup-secondary-command" type="button" @click="previousStep"><ArrowLeft :size="16" />上一步</button>
              <span v-else class="setup-form-spacer" />
              <button class="primary-command button-press" type="submit" :disabled="testingDatabase || submitting">
                <span v-if="testingDatabase || submitting" class="spinner" />
                <span>{{ testingDatabase ? '正在准备数据库' : submitting ? '正在保存配置' : currentStep === 1 ? '完成安装并启动' : '测试连接并初始化' }}</span>
                <ArrowRight v-if="!testingDatabase && !submitting" :size="16" />
              </button>
            </div>
          </form>
        </template>
      </section>
    </div>
  </main>
</template>
