import { createRouter, createWebHistory } from 'vue-router'
import { useAuthStore } from '@/stores/auth'
import { safeLocalPath } from '@/lib/format'
import { getSetupStatus } from '@/lib/api'
import AppShell from '@/components/AppShell.vue'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/setup', name: 'setup', component: () => import('@/views/SetupGuideView.vue'), meta: { public: true } },
    { path: '/login', name: 'login', component: () => import('@/views/LoginView.vue'), meta: { public: true } },
    {
      path: '/', component: AppShell, children: [
        { path: '', redirect: '/dashboard' },
        { path: 'dashboard', name: 'dashboard', component: () => import('@/views/DashboardView.vue') },
        { path: 'devices', name: 'devices', component: () => import('@/views/DevicesView.vue') },
        { path: 'devices/:id', name: 'device-detail', component: () => import('@/views/DeviceDetailView.vue') },
        { path: 'alerts', name: 'alerts', component: () => import('@/views/AlertsView.vue') },
        { path: 'alert-rules', name: 'alert-rules', component: () => import('@/views/AlertRulesView.vue') },
        { path: 'settings', name: 'settings', component: () => import('@/views/SettingsView.vue'), meta: { role: 'ADMIN' } },
        { path: 'users', name: 'users', component: () => import('@/views/UsersView.vue'), meta: { role: 'ADMIN' } },
        { path: 'audit', name: 'audit', component: () => import('@/views/AuditView.vue'), meta: { role: 'ADMIN' } },
      ],
    },
    { path: '/:pathMatch(.*)*', component: () => import('@/views/NotFoundView.vue'), meta: { public: true } },
  ],
})

router.beforeEach(async (to) => {
  let setup: Awaited<ReturnType<typeof getSetupStatus>>
  try {
    setup = await getSetupStatus()
  } catch {
    setup = { configured: true, state: 'unavailable', message: '安装服务暂不可用' }
  }

  if (!setup.configured && to.name !== 'setup') return { name: 'setup' }
  if (setup.configured && setup.state !== 'unavailable' && to.name === 'setup') return { name: 'login' }

  const auth = useAuthStore()
  await auth.initialize()
  if (!to.meta.public && !auth.user) return { name: 'login', query: { redirect: safeLocalPath(to.fullPath) } }
  if (to.name === 'login' && auth.user) return '/dashboard'
  if (to.meta.role && auth.user?.role !== to.meta.role) return '/dashboard'
})

export default router
