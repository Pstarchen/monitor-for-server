<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import {
  Activity, BellRing, ChevronDown, CircleGauge, ClipboardList, Globe2, LogOut,
  Menu, Moon, Server, Settings, ShieldCheck, SlidersHorizontal, Sun, Terminal, Users, X, KeyRound,
} from 'lucide-vue-next'
import { ElMessage } from 'element-plus'
import { errorMessage } from '@/lib/api'
import { useAuthStore } from '@/stores/auth'
import { loadBranding, siteName } from '@/lib/branding'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()
const drawer = ref(false)
const profileDialog = ref(false)
const profileSaving = ref(false)
const profileError = ref('')
const profileForm = reactive({ displayName: '', currentPassword: '', newPassword: '' })
const dark = ref(localStorage.getItem('guanlan-theme') === 'dark')
let socket: WebSocket | null = null
let reconnectTimer = 0
let active = true

const navigation = [
  { label: '运行总览', path: '/dashboard', icon: CircleGauge },
  { label: '设备管理', path: '/devices', icon: Server },
  { label: '告警事件', path: '/alerts', icon: BellRing },
  { label: '告警规则', path: '/alert-rules', icon: SlidersHorizontal },
  { label: '服务监控', path: '/services', icon: Globe2 },
  { label: '动态域名解析', path: '/ddns', icon: Globe2 },
  { label: '任务执行', path: '/tasks', icon: Terminal },
  { label: 'API Token', path: '/tokens', icon: KeyRound },
]
const administration = [
  { label: '系统设置', path: '/settings', icon: Settings },
  { label: '账号权限', path: '/users', icon: Users },
  { label: '审计日志', path: '/audit', icon: ClipboardList },
]
const visibleAdministration = computed(() => auth.user?.role === 'ADMIN' ? administration : [])

const pageTitle = computed(() => {
  if (route.path.startsWith('/devices/')) return '设备详情'
  return [...navigation, ...administration].find((item) => route.path.startsWith(item.path))?.label ?? siteName.value
})

function isActive(path: string) {
  return path === '/devices' ? route.path === path || route.path.startsWith('/devices/') : route.path === path
}

function applyTheme() {
  document.documentElement.classList.toggle('dark', dark.value)
  localStorage.setItem('guanlan-theme', dark.value ? 'dark' : 'light')
}

function toggleTheme() {
  dark.value = !dark.value
  applyTheme()
}

async function logout() {
  await auth.logout()
  await router.replace('/login')
}

function openProfile() {
  profileForm.displayName = auth.user?.displayName ?? ''
  profileForm.currentPassword = ''
  profileForm.newPassword = ''
  profileError.value = ''
  profileDialog.value = true
}

async function saveProfile() {
  if (!profileForm.displayName.trim()) {
    profileError.value = '请输入显示名称'
    return
  }
  if (profileForm.newPassword && !profileForm.currentPassword) {
    profileError.value = '修改密码前请先输入当前密码'
    return
  }
  profileSaving.value = true
  profileError.value = ''
  try {
    await auth.updateProfile(profileForm.displayName.trim(), profileForm.currentPassword, profileForm.newPassword)
    profileDialog.value = false
    ElMessage.success(profileForm.newPassword ? '个人资料和密码已更新' : '个人资料已更新')
  } catch (cause) {
    profileError.value = errorMessage(cause)
  } finally {
    profileSaving.value = false
  }
}

function connectRealtime() {
  if (!active) return
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:'
  socket = new WebSocket(`${protocol}//${location.host}/ws/metrics`)
  socket.onmessage = (event) => {
    try {
      window.dispatchEvent(new CustomEvent('guanlan:realtime', { detail: JSON.parse(event.data) }))
    } catch {
      // Ignore malformed events and retain polling as the source of truth.
    }
  }
  socket.onclose = () => {
    if (active) reconnectTimer = window.setTimeout(connectRealtime, 3000)
  }
}

onMounted(() => {
  loadBranding()
  applyTheme()
  connectRealtime()
})

onBeforeUnmount(() => {
  active = false
  window.clearTimeout(reconnectTimer)
  socket?.close()
})
</script>

<template>
  <div class="app-shell">
    <aside class="sidebar desktop-sidebar">
      <RouterLink class="brand" to="/dashboard">
        <span class="brand-mark"><Activity :size="19" /></span>
        <span><strong>{{ siteName }}</strong><small>PRIVATE OPS</small></span>
      </RouterLink>
      <nav class="side-navigation" aria-label="主导航">
        <p class="nav-caption">监控中心</p>
        <RouterLink v-for="item in navigation" :key="item.path" :to="item.path" :class="{ active: isActive(item.path) }">
          <component :is="item.icon" :size="18" /><span>{{ item.label }}</span>
        </RouterLink>
        <template v-if="visibleAdministration.length">
          <p class="nav-caption">系统管理</p>
          <RouterLink v-for="item in visibleAdministration" :key="item.path" :to="item.path" :class="{ active: isActive(item.path) }">
            <component :is="item.icon" :size="18" /><span>{{ item.label }}</span>
          </RouterLink>
        </template>
      </nav>
      <div class="sidebar-foot">
        <ShieldCheck :size="17" />
        <span>私有化数据边界</span>
      </div>
    </aside>

    <el-drawer v-model="drawer" direction="ltr" size="272px" :with-header="false" class="mobile-drawer">
      <div class="drawer-head">
        <RouterLink class="brand" to="/dashboard" @click="drawer = false">
          <span class="brand-mark"><Activity :size="19" /></span><strong>{{ siteName }}</strong>
        </RouterLink>
        <button class="icon-button" type="button" aria-label="关闭导航" title="关闭导航" @click="drawer = false"><X :size="19" /></button>
      </div>
      <nav class="side-navigation" aria-label="移动端主导航">
        <p class="nav-caption">监控中心</p>
        <RouterLink v-for="item in navigation" :key="item.path" :to="item.path" :class="{ active: isActive(item.path) }" @click="drawer = false">
          <component :is="item.icon" :size="18" /><span>{{ item.label }}</span>
        </RouterLink>
        <template v-if="visibleAdministration.length">
          <p class="nav-caption">系统管理</p>
          <RouterLink v-for="item in visibleAdministration" :key="item.path" :to="item.path" :class="{ active: isActive(item.path) }" @click="drawer = false">
            <component :is="item.icon" :size="18" /><span>{{ item.label }}</span>
          </RouterLink>
        </template>
      </nav>
    </el-drawer>

    <div class="shell-body">
      <header class="topbar">
        <div class="topbar-left">
          <button class="icon-button mobile-menu" type="button" aria-label="打开导航" title="打开导航" @click="drawer = true"><Menu :size="20" /></button>
          <div><p>运维控制台</p><strong>{{ pageTitle }}</strong></div>
        </div>
        <div class="topbar-actions">
          <button class="icon-button" type="button" :aria-label="dark ? '切换浅色模式' : '切换深色模式'" :title="dark ? '浅色模式' : '深色模式'" @click="toggleTheme">
            <Sun v-if="dark" :size="18" /><Moon v-else :size="18" />
          </button>
          <el-dropdown trigger="click">
            <button class="account-button" type="button">
              <span class="avatar">{{ auth.user?.displayName.slice(0, 1) }}</span>
              <span class="account-copy"><strong>{{ auth.user?.displayName }}</strong><small>{{ auth.user?.role }}</small></span>
              <ChevronDown :size="15" />
            </button>
            <template #dropdown>
              <el-dropdown-menu>
                <el-dropdown-item @click="openProfile"><KeyRound :size="16" /> 个人资料与密码</el-dropdown-item>
                <el-dropdown-item @click="logout"><LogOut :size="16" /> 退出登录</el-dropdown-item>
              </el-dropdown-menu>
            </template>
          </el-dropdown>
        </div>
      </header>
      <main class="page-content">
        <RouterView v-slot="{ Component }">
          <Transition name="route" mode="out-in"><component :is="Component" /></Transition>
        </RouterView>
      </main>
    </div>

    <el-dialog v-model="profileDialog" title="个人资料与密码" width="min(480px, calc(100vw - 28px))" destroy-on-close>
      <el-form label-position="top" @submit.prevent="saveProfile">
        <el-form-item label="显示名称" required><el-input v-model="profileForm.displayName" maxlength="80" autocomplete="name" /></el-form-item>
        <el-form-item label="当前密码"><el-input v-model="profileForm.currentPassword" type="password" show-password autocomplete="current-password" placeholder="修改密码时填写" /></el-form-item>
        <el-form-item label="新密码"><el-input v-model="profileForm.newPassword" type="password" show-password autocomplete="new-password" placeholder="留空表示不修改，至少 12 位" /></el-form-item>
        <p v-if="profileError" class="form-error" role="alert">{{ profileError }}</p>
      </el-form>
      <template #footer><el-button @click="profileDialog = false">取消</el-button><el-button type="primary" :loading="profileSaving" @click="saveProfile">保存</el-button></template>
    </el-dialog>
  </div>
</template>
