<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { Copy, KeyRound, Plus, ShieldCheck, Trash2 } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import EmptyState from '@/components/EmptyState.vue'
import LoadingState from '@/components/LoadingState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { copyText } from '@/lib/clipboard'
import { dateTime } from '@/lib/format'
import { visibleApiTokenScopes } from '@/lib/api-token-scopes'
import { useAuthStore } from '@/stores/auth'
import type { ApiToken, CreatedApiToken } from '@/types'

const auth = useAuthStore()
const tokens = ref<ApiToken[]>([])
const loading = ref(true)
const saving = ref(false)
const dialog = ref(false)
const created = ref<CreatedApiToken | null>(null)
const form = reactive({ name: '', scopes: ['nezha:inventory:read'], serverIds: '', expiresInDays: 90 })
const canAdmin = computed(() => auth.user?.role === 'ADMIN')
const scopes = computed(() => visibleApiTokenScopes(canAdmin.value))

async function load() {
  loading.value = true
  try {
    tokens.value = (await api.get<ApiToken[]>('/api-tokens')).data
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    loading.value = false
  }
}

function openCreate() {
  Object.assign(form, { name: '', scopes: ['nezha:inventory:read'], serverIds: '', expiresInDays: 90 })
  dialog.value = true
}

async function createToken() {
  if (!form.name.trim() || !form.scopes.length) {
    ElMessage.warning('请输入 Token 名称并至少选择一个权限')
    return
  }
  saving.value = true
  try {
    created.value = (await api.post<CreatedApiToken>('/api-tokens', {
      name: form.name.trim(),
      scopes: form.scopes,
      serverIds: form.serverIds.split(',').map((value) => value.trim()).filter(Boolean),
      expiresInDays: Number(form.expiresInDays) || 0,
    })).data
    dialog.value = false
    await load()
    ElMessage.success('API Token 已创建，请立即复制明文')
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
  } finally {
    saving.value = false
  }
}

async function copyCreated() {
  if (!created.value) return
  try {
    await copyText(created.value.secret)
    ElMessage.success('Token 已复制')
  } catch {
    ElMessage.error('复制失败，请手动选择 Token')
  }
}

async function revoke(token: ApiToken) {
  try {
    await ElMessageBox.confirm(`吊销“${token.name}”后，使用它的客户端会立即失去访问权限。`, '吊销 API Token', { type: 'warning', confirmButtonText: '确认吊销', cancelButtonText: '取消' })
    await api.delete(`/api-tokens/${token.id}`)
    ElMessage.success('API Token 已吊销')
    await load()
  } catch (cause) {
    if (cause !== 'cancel' && cause !== 'close') ElMessage.error(errorMessage(cause))
  }
}

onMounted(load)
</script>

<template>
  <section>
    <PageHeader eyebrow="ACCESS TOKENS" title="API Token" description="为移动端、脚本或自动化工具签发受限访问凭据。">
      <template #actions><el-button type="primary" @click="openCreate"><Plus :size="15" />创建 Token</el-button></template>
    </PageHeader>

    <article class="panel token-settings">
      <div class="settings-notice token-notice" role="note"><ShieldCheck :size="17" /><p>明文 Token 只在创建成功后显示一次。请按最小权限选择 scope，并在需要时填写服务器 ID 白名单。</p></div>
      <LoadingState v-if="loading" />
      <div v-else-if="tokens.length" class="token-list">
        <article v-for="token in tokens" :key="token.id" class="token-row" :data-revoked="Boolean(token.revokedAt)">
          <div class="token-row-main"><div><strong>{{ token.name }}</strong><small class="mono-value">{{ token.tokenPrefix }}…</small></div><StatusBadge :status="token.revokedAt ? 'OFFLINE' : 'ONLINE'" /></div>
          <div class="token-row-meta"><span>{{ token.scopes.join('、') }}</span><span>{{ token.serverIds.length ? `${token.serverIds.length} 台服务器白名单` : '不限制服务器白名单' }}</span><span>{{ token.expiresAt ? `到期 ${dateTime(token.expiresAt)}` : '永不过期' }}</span><span>{{ token.lastUsedAt ? `最后使用 ${dateTime(token.lastUsedAt)}` : '尚未使用' }}</span></div>
          <button v-if="!token.revokedAt" class="table-icon-button danger-command" type="button" title="吊销 Token" aria-label="吊销 Token" @click="revoke(token)"><Trash2 :size="16" /></button>
        </article>
      </div>
      <EmptyState v-else title="暂无 API Token" description="创建一个受限 Token，让移动端或自动化工具访问监控数据。"><el-button type="primary" @click="openCreate"><Plus :size="15" />创建 Token</el-button></EmptyState>
    </article>

    <el-dialog v-model="dialog" title="创建 API Token" width="min(620px, calc(100vw - 28px))" destroy-on-close>
      <el-form label-position="top">
        <el-form-item label="Token 名称" required><el-input v-model="form.name" maxlength="128" placeholder="例如：移动端只读" /></el-form-item>
        <el-form-item label="权限范围" required><el-checkbox-group v-model="form.scopes" class="token-scope-grid"><el-checkbox v-for="[value, label] in scopes" :key="value" :value="value">{{ label }}</el-checkbox></el-checkbox-group></el-form-item>
        <el-form-item label="服务器 ID 白名单"><el-input v-model="form.serverIds" placeholder="多个 ID 使用英文逗号分隔，留空表示不限制" /></el-form-item>
        <el-form-item label="有效期"><el-input-number v-model="form.expiresInDays" :min="0" :max="3650" /><span class="field-suffix">天，0 表示永不过期</span></el-form-item>
      </el-form>
      <template #footer><el-button @click="dialog = false">取消</el-button><el-button type="primary" :loading="saving" @click="createToken">创建并显示 Token</el-button></template>
    </el-dialog>

    <el-dialog :model-value="Boolean(created)" title="保存 API Token 明文" width="min(620px, calc(100vw - 28px))" :close-on-click-modal="false" @update:model-value="(value: boolean) => { if (!value) created = null }">
      <div v-if="created" class="credential-panel"><div class="credential-warning"><KeyRound :size="18" /><p><strong>明文只显示这一次</strong><span>关闭窗口后无法再次查看，请立即复制并保存到安全的密钥管理器。</span></p></div><dl><div><dt>Token</dt><dd class="mono-value">{{ created.secret }}</dd></div><div><dt>权限</dt><dd>{{ created.token.scopes.join('、') }}</dd></div></dl></div>
      <template #footer><el-button @click="created = null">我已保存</el-button><el-button type="primary" @click="copyCreated"><Copy :size="16" />复制 Token</el-button></template>
    </el-dialog>
  </section>
</template>
