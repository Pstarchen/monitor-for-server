<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { Pencil, Plus, RefreshCw, ShieldCheck, UserRound } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import LoadingState from '@/components/LoadingState.vue'
import EmptyState from '@/components/EmptyState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { dateTime } from '@/lib/format'
import type { Role, User } from '@/types'

const users = ref<User[]>([])
const loading = ref(true)
const error = ref('')
const dialog = ref(false)
const saving = ref(false)
const editingId = ref<number | null>(null)
const form = reactive<{ username: string; password: string; displayName: string; role: Role; enabled: boolean; newPassword: string }>({ username: '', password: '', displayName: '', role: 'VIEWER', enabled: true, newPassword: '' })
const roleLabels: Record<Role, string> = { ADMIN: '管理员', OPERATOR: '运维人员', VIEWER: '只读用户' }
const roleDescriptions: Record<Role, string> = { ADMIN: '管理系统设置、账号、设备和规则', OPERATOR: '管理设备与告警规则、确认告警', VIEWER: '查看监控数据与告警，不可修改' }

async function load() {
  loading.value = true
  error.value = ''
  try {
    users.value = (await api.get<User[]>('/admin/users')).data
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

function openCreate() {
  editingId.value = null
  Object.assign(form, { username: '', password: '', displayName: '', role: 'VIEWER', enabled: true, newPassword: '' })
  dialog.value = true
}

function openEdit(user: User) {
  editingId.value = user.id
  Object.assign(form, { username: user.username, password: '', displayName: user.displayName, role: user.role, enabled: user.enabled, newPassword: '' })
  dialog.value = true
}

async function save() {
  if (!form.displayName.trim() || (!editingId.value && (!form.username.trim() || form.password.length < 12))) {
    ElMessage.warning(editingId.value ? '请输入显示名称' : '请填写用户名、显示名称和至少 12 位密码')
    return
  }
  if (editingId.value && form.newPassword && form.newPassword.length < 12) {
    ElMessage.warning('新密码至少需要 12 位')
    return
  }
  saving.value = true
  try {
    if (editingId.value) {
      await api.put(`/admin/users/${editingId.value}`, { displayName: form.displayName.trim(), role: form.role, enabled: form.enabled, newPassword: form.newPassword || null })
    } else {
      await api.post('/admin/users', { username: form.username.trim(), password: form.password, displayName: form.displayName.trim(), role: form.role })
    }
    dialog.value = false
    ElMessage.success(editingId.value ? '账号已更新' : '账号已创建')
    await load()
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
    <PageHeader eyebrow="ACCESS CONTROL" title="账号权限" description="按职责分配管理员、运维人员和只读用户权限。">
      <template #actions><el-button @click="load"><RefreshCw :size="16" />刷新</el-button><el-button type="primary" class="button-press" @click="openCreate"><Plus :size="16" />新建账号</el-button></template>
    </PageHeader>
    <div class="role-summary">
      <article v-for="(description, role) in roleDescriptions" :key="role" class="panel"><span><ShieldCheck :size="17" /></span><div><strong>{{ roleLabels[role] }}</strong><small>{{ description }}</small></div><b>{{ users.filter((user) => user.role === role).length }}</b></article>
    </div>
    <LoadingState v-if="loading" />
    <div v-else-if="error" class="panel state-panel"><EmptyState title="账号列表加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState></div>
    <article v-else class="panel section">
      <div v-if="users.length" class="table-wrap"><table class="data-table"><thead><tr><th>用户</th><th>用户名</th><th>角色</th><th>状态</th><th>创建时间</th><th class="actions-column">操作</th></tr></thead><tbody><tr v-for="user in users" :key="user.id"><td><div class="user-cell"><span><UserRound :size="16" /></span><strong>{{ user.displayName }}</strong></div></td><td class="mono-value">{{ user.username }}</td><td>{{ roleLabels[user.role] }}</td><td><StatusBadge :status="user.enabled ? 'ONLINE' : 'OFFLINE'" /></td><td>{{ dateTime(user.createdAt) }}</td><td class="row-actions"><button class="table-icon-button" type="button" title="编辑账号" aria-label="编辑账号" @click="openEdit(user)"><Pencil :size="16" /></button></td></tr></tbody></table></div>
      <EmptyState v-else title="暂无账号" description="创建第一个可登录的系统账号。" />
    </article>

    <el-dialog v-model="dialog" :title="editingId ? '编辑账号' : '新建账号'" width="min(520px, calc(100vw - 28px))" destroy-on-close>
      <el-form label-position="top">
        <div class="form-grid two-fields">
          <el-form-item label="用户名" required><el-input v-model="form.username" :disabled="Boolean(editingId)" maxlength="64" autocomplete="off" placeholder="字母、数字、点、横线或下划线" /></el-form-item>
          <el-form-item label="显示名称" required><el-input v-model="form.displayName" maxlength="80" placeholder="用于页面与审计日志" /></el-form-item>
          <el-form-item label="角色" required><el-select v-model="form.role"><el-option v-for="(label, role) in roleLabels" :key="role" :label="label" :value="role" /></el-select></el-form-item>
          <el-form-item v-if="editingId" label="账号状态"><el-switch v-model="form.enabled" active-text="启用" inactive-text="停用" /></el-form-item>
        </div>
        <el-form-item v-if="!editingId" label="初始密码" required><el-input v-model="form.password" type="password" show-password autocomplete="new-password" placeholder="至少 12 位" /></el-form-item>
        <el-form-item v-else label="重置密码"><el-input v-model="form.newPassword" type="password" show-password autocomplete="new-password" placeholder="留空表示不修改，填写时至少 12 位" /></el-form-item>
        <div class="role-notice"><ShieldCheck :size="16" /><span>{{ roleDescriptions[form.role] }}</span></div>
      </el-form>
      <template #footer><el-button @click="dialog = false">取消</el-button><el-button type="primary" :loading="saving" @click="save">{{ editingId ? '保存修改' : '创建账号' }}</el-button></template>
    </el-dialog>
  </section>
</template>
