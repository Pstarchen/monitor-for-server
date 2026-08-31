import { createRouter, createWebHistory } from 'vue-router'
import { useAuthStore } from '@/stores/auth'
import { safeLocalPath } from '@/lib/format'
import { getSetupStatus } from '@/lib/api'
import { setupRouteRedirect } from '@/lib/setup-flow'
import AppShell from '@/components/AppShell.vue'
import type { Role } from '@/types'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/setup', name: 'setup', component: () => import('@/views/SetupGuideView.vue'), meta: { public: true } },
    { path: '/login', name: 'login', component: () => import('@/views/LoginView.vue'), meta: { public: true } },
    { path: '/', name: 'public-status', component: () => import('@/views/PublicStatusView.vue'), meta: { public: true } },
    { path: '/status', redirect: '/' },
    { path: '/status/', redirect: '/' },
    {
      path: '/', component: AppShell, children: [
        { path: 'dashboard', name: 'dashboard', component: () => import('@/views/DashboardView.vue') },
        { path: 'devices', name: 'devices', component: () => import('@/views/DevicesView.vue') },
        { path: 'discovery', name: 'discovery', component: () => import('@/views/DiscoveryView.vue'), meta: { roles: ['ADMIN', 'OPERATOR'] as Role[] } },
        { path: 'devices/:id', name: 'device-detail', component: () => import('@/views/DeviceDetailView.vue') },
        { path: 'alerts', name: 'alerts', component: () => import('@/views/AlertsView.vue') },
        { path: 'alert-rules', name: 'alert-rules', component: () => import('@/views/AlertRulesView.vue') },
        { path: 'maintenance', name: 'maintenance', component: () => import('@/views/MaintenanceWindowsView.vue') },
        { path: 'services', name: 'services', component: () => import('@/views/ServiceChecksView.vue') },
        { path: 'topology', name: 'topology', component: () => import('@/views/TopologyView.vue') },
        { path: 'reports', name: 'reports', component: () => import('@/views/ReportsView.vue') },
        { path: 'ddns', name: 'ddns', component: () => import('@/views/DdnsView.vue') },
        { path: 'tasks', name: 'tasks', component: () => import('@/views/AgentTasksView.vue') },
        { path: 'tokens', name: 'tokens', component: () => import('@/views/ApiTokensView.vue') },
        { path: 'settings', name: 'settings', component: () => import('@/views/SettingsView.vue'), meta: { role: 'ADMIN' } },
        { path: 'users', name: 'users', component: () => import('@/views/UsersView.vue'), meta: { role: 'ADMIN' } },
        { path: 'audit', name: 'audit', component: () => import('@/views/AuditView.vue'), meta: { role: 'ADMIN' } },
        { path: 'backups', name: 'backups', component: () => import('@/views/BackupsView.vue'), meta: { role: 'ADMIN' } },
      ],
    },
    { path: '/:pathMatch(.*)*', component: () => import('@/views/NotFoundView.vue'), meta: { public: true } },
  ],
})

router.beforeEach(async (to) => {
  // The public status page must remain reachable when the setup service is
  // still starting or temporarily unavailable. Its data request handles its
  // own loading/error state after the page has rendered.
  if (to.name === 'public-status') return true

  let setup: Awaited<ReturnType<typeof getSetupStatus>>
  try {
    setup = await getSetupStatus()
  } catch {
    setup = { configured: true, state: 'unavailable', message: '安装服务暂不可用' }
  }

  const setupRedirect = setupRouteRedirect(setup, to.name)
  if (setupRedirect) return { name: setupRedirect }
  if (!setup.configured || setup.state !== 'configured') return true

  const auth = useAuthStore()
  await auth.initialize()
  if (!to.meta.public && !auth.user) return { name: 'login', query: { redirect: safeLocalPath(to.fullPath) } }
  if (to.name === 'login' && auth.user) return '/dashboard'
  if (to.meta.role && auth.user?.role !== to.meta.role) return '/dashboard'
  const roles = to.meta.roles as Role[] | undefined
  if (roles && (!auth.user || !roles.includes(auth.user.role))) return '/dashboard'
})

export default router
