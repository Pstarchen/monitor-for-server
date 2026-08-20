<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import {
  Activity, BellRing, ChevronDown, CircleGauge, ClipboardList, LogOut,
  Menu, Moon, Server, Settings, ShieldCheck, SlidersHorizontal, Sun, Users, X,
} from 'lucide-vue-next'
import { useAuthStore } from '@/stores/auth'
import { loadBranding, siteName } from '@/lib/branding'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()
const drawer = ref(false)
const dark = ref(localStorage.getItem('guanlan-theme') === 'dark')
let socket: WebSocket | null = null
let reconnectTimer = 0
let active = true

const navigation = [
  { label: '运行总览', path: '/dashboard', icon: CircleGauge },
  { label: '设备管理', path: '/devices', icon: Server },
  { label: '告警事件', path: '/alerts', icon: BellRing },
  { label: '告警规则', path: '/alert-rules', icon: SlidersHorizontal },
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
  </div>
</template>
