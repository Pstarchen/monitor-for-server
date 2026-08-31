<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { Activity, Eye, EyeOff, LockKeyhole, Moon, ShieldCheck, Sun, UserRound } from 'lucide-vue-next'
import { useAuthStore } from '@/stores/auth'
import { errorMessage, getSetupStatus } from '@/lib/api'
import { safeLocalPath } from '@/lib/format'
import { setupIsReady } from '@/lib/setup-flow'
import BrandMark from '@/components/BrandMark.vue'
import { loadBranding, siteName } from '@/lib/branding'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()
const form = reactive({ username: '', password: '' })
const twoFactorCode = ref('')
const twoFactorStep = ref(false)
const loading = ref(false)
const error = ref('')
const revealPassword = ref(false)
const serviceReady = ref(true)
const serviceMessage = ref('')
const serviceFailed = ref(false)
const dark = ref(localStorage.getItem('guanlan-theme') === 'dark')
const returnTo = computed(() => safeLocalPath(Array.isArray(route.query.redirect) ? route.query.redirect[0] : route.query.redirect))
let serviceTimer: number | undefined
let disposed = false

function toggleTheme() {
  dark.value = !dark.value
  document.documentElement.classList.toggle('dark', dark.value)
  localStorage.setItem('guanlan-theme', dark.value ? 'dark' : 'light')
}

async function submit() {
  if (!serviceReady.value) return
  if (twoFactorStep.value) {
    if (!/^\d{6}$/.test(twoFactorCode.value)) {
      error.value = '请输入 6 位验证码'
      return
    }
  } else if (!form.username.trim() || !form.password) {
    error.value = '请输入用户名和密码'
    return
  }
  loading.value = true
  error.value = ''
  try {
    if (twoFactorStep.value) {
      const destination = await auth.verifyTwoFactor(twoFactorCode.value, returnTo.value)
      await router.replace(safeLocalPath(destination))
    } else {
      const result = await auth.login(form.username.trim(), form.password, returnTo.value)
      if (result.requiresTwoFactor) {
        twoFactorStep.value = true
        twoFactorCode.value = ''
      } else {
        await router.replace(safeLocalPath(result.returnTo))
      }
    }
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

function returnToPasswordStep() {
  twoFactorStep.value = false
  twoFactorCode.value = ''
  error.value = ''
}

async function checkServiceReadiness() {
  try {
    const status = await getSetupStatus()
    if (!status.configured) {
      await router.replace({ name: 'setup' })
      return
    }
    if (setupIsReady(status)) {
      serviceReady.value = true
      serviceMessage.value = ''
      serviceFailed.value = false
      await auth.initialize()
      if (auth.user) await router.replace({ name: 'dashboard' })
      return
    }
    serviceReady.value = false
    serviceMessage.value = status.message ?? '正在启动生产服务'
    serviceFailed.value = status.state === 'error'
  } catch {
    serviceReady.value = false
    serviceMessage.value = '正在等待安装服务恢复'
    serviceFailed.value = false
    return
  }
  if (!disposed) serviceTimer = window.setTimeout(checkServiceReadiness, 1500)
}

onMounted(() => {
  loadBranding()
  checkServiceReadiness()
})
onBeforeUnmount(() => {
  disposed = true
  if (serviceTimer !== undefined) window.clearTimeout(serviceTimer)
})
</script>

<template>
  <main class="auth-page">
    <header class="auth-topbar">
      <div class="brand auth-brand">
        <BrandMark />
        <span><strong>{{ siteName }}</strong><small>PRIVATE OPS</small></span>
      </div>
      <button class="icon-button" type="button" :aria-label="dark ? '切换浅色模式' : '切换深色模式'" :title="dark ? '浅色模式' : '深色模式'" @click="toggleTheme">
        <Sun v-if="dark" :size="18" /><Moon v-else :size="18" />
      </button>
    </header>

    <section class="auth-stage">
      <div class="auth-context" aria-hidden="true">
        <span class="auth-context-icon"><ShieldCheck :size="22" /></span>
        <p>PRIVATE MONITORING</p>
        <h1>把基础设施状态<br>留在自己的边界内</h1>
        <div class="auth-signal"><i /><span>指标、告警与审计统一管理</span></div>
      </div>

      <form class="auth-card fade-in-up" novalidate @submit.prevent="submit">
        <div class="auth-card-head">
          <p class="eyebrow">运维控制台</p>
          <h2>{{ twoFactorStep ? '输入验证码' : `登录${siteName}` }}</h2>
          <p>{{ twoFactorStep ? '打开身份验证器，输入当前显示的 6 位验证码' : '使用管理员分配的账号进入系统' }}</p>
        </div>

        <template v-if="!twoFactorStep">
          <label class="field-label" for="username">用户名</label>
          <div class="input-with-icon">
            <UserRound :size="17" />
            <input id="username" v-model="form.username" name="username" autocomplete="username" autofocus placeholder="请输入用户名" />
          </div>

          <label class="field-label" for="password">密码</label>
          <div class="input-with-icon">
            <LockKeyhole :size="17" />
            <input id="password" v-model="form.password" name="password" :type="revealPassword ? 'text' : 'password'" autocomplete="current-password" placeholder="请输入密码" />
            <button type="button" :aria-label="revealPassword ? '隐藏密码' : '显示密码'" :title="revealPassword ? '隐藏密码' : '显示密码'" @click="revealPassword = !revealPassword">
              <EyeOff v-if="revealPassword" :size="17" /><Eye v-else :size="17" />
            </button>
          </div>
        </template>
        <template v-else>
          <label class="field-label" for="two-factor-code">身份验证器验证码</label>
          <div class="input-with-icon">
            <ShieldCheck :size="17" />
            <input id="two-factor-code" v-model="twoFactorCode" name="one-time-code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" autofocus placeholder="输入 6 位验证码" />
          </div>
          <button class="auth-back-link" type="button" @click="returnToPasswordStep">返回修改账号或密码</button>
        </template>

        <p v-if="!serviceReady" :class="serviceFailed ? 'form-error' : 'auth-startup-status'" :role="serviceFailed ? 'alert' : 'status'"><span v-if="!serviceFailed" class="spinner" />{{ serviceMessage }}</p>
        <p v-if="error" class="form-error" role="alert">{{ error }}</p>
        <button class="primary-command button-press" type="submit" :disabled="loading || !serviceReady">
          <span v-if="loading" class="spinner" />
          <span>{{ loading ? '正在验证' : (twoFactorStep ? '验证并登录' : '登录') }}</span>
        </button>
        <p class="auth-security"><LockKeyhole :size="13" /> 会话凭据仅保存在安全 Cookie 中</p>
        <RouterLink class="auth-public-link" to="/"><Activity :size="13" /> 查看公开状态页</RouterLink>
      </form>
    </section>
  </main>
</template>
