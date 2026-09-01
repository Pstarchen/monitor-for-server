<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { CheckCircle2, Copy, KeyRound, Plus, ShieldCheck, Trash2 } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import EmptyState from '@/components/EmptyState.vue'
import LoadingState from '@/components/LoadingState.vue'
import MobileBindingPanel from '@/components/MobileBindingPanel.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { copyText } from '@/lib/clipboard'
import { dateTime } from '@/lib/format'
import { apiTokenScopeLabel, visibleApiTokenScopeGroups } from '@/lib/api-token-scopes'
import { createDefaultApiTokenForm, parseServerIds } from '@/lib/api-token-form'
import { resolveMobileBindingBaseUrl } from '@/lib/mobile-binding'
import { useAuthStore } from '@/stores/auth'
import type { ApiToken, CreatedApiToken } from '@/types'

const auth = useAuthStore()
const tokens = ref<ApiToken[]>([])
const loading = ref(true)
const saving = ref(false)
const dialog = ref(false)
const created = ref<CreatedApiToken | null>(null)
const form = reactive(createDefaultApiTokenForm())
const copied = ref(false)
const canAdmin = computed(() => auth.user?.role === 'ADMIN')
const scopeGroups = computed(() => visibleApiTokenScopeGroups(canAdmin.value))
const selectedScopeCount = computed(() => form.scopes.length)
const mobileBindingBaseUrl = computed(() => resolveMobileBindingBaseUrl(undefined, window.location.origin))

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
  Object.assign(form, createDefaultApiTokenForm())
  dialog.value = true
}

function closeCreated() {
  created.value = null
  copied.value = false
}

async function createToken() {
  if (!form.name.trim() || !form.scopes.length) {
    ElMessage.warning('请输入 Token 名称并至少选择一个权限')
    return
  }
  saving.value = true
  try {
    const result = (await api.post<CreatedApiToken>('/api-tokens', {
      name: form.name.trim(),
      scopes: [...form.scopes],
      serverIds: parseServerIds(form.serverIds),
      expiresInDays: Number(form.expiresInDays) || 0,
    })).data
    created.value = result
    copied.value = false
    dialog.value = false
    await load()
  } catch (cause) {
    ElMessage.error(errorMessage(cause))
    return
  } finally {
    saving.value = false
  }

  ElMessage.success('API Token 已创建，请立即完成绑定或复制明文')
}

async function copyCreated() {
  if (!created.value) return
  try {
    await copyText(created.value.secret)
    copied.value = true
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
    <PageHeader eyebrow="ACCESS TOKENS" title="API Token" description="按最小权限签发访问凭据，并把访问范围限制到指定服务器。">
      <template #actions><el-button type="primary" @click="openCreate"><Plus :size="15" />创建 Token</el-button></template>
    </PageHeader>

    <article class="panel token-settings">
      <div class="token-security-grid" role="list" aria-label="Token 安全策略">
        <div class="token-security-item" role="listitem"><span><KeyRound :size="16" /></span><div><strong>明文只出现一次</strong><p>创建成功后立即复制，关闭窗口后无法恢复。</p></div></div>
        <div class="token-security-item" role="listitem"><span><CheckCircle2 :size="16" /></span><div><strong>默认只读</strong><p>新 Token 预选移动端查看所需的设备、指标和告警读取权限。</p></div></div>
        <div class="token-security-item" role="listitem"><span><ShieldCheck :size="16" /></span><div><strong>可限制服务器</strong><p>填写白名单后，Token 只能访问这些服务器。</p></div></div>
      </div>
      <LoadingState v-if="loading" />
      <div v-else-if="tokens.length" class="token-list">
        <article v-for="token in tokens" :key="token.id" class="token-row" :data-revoked="Boolean(token.revokedAt)">
          <div class="token-row-main"><div class="token-identity"><strong>{{ token.name }}</strong><small class="mono-value">{{ token.tokenPrefix }}…</small></div><StatusBadge :status="token.revokedAt ? 'OFFLINE' : 'ONLINE'" /></div>
          <div class="token-row-meta">
            <div class="token-meta-block"><span class="token-meta-label">权限范围</span><div class="token-scope-tags"><span v-for="scope in token.scopes" :key="scope" class="token-scope-tag" :title="scope">{{ apiTokenScopeLabel(scope) }}</span></div></div>
            <span>{{ token.serverIds.length ? `${token.serverIds.length} 台服务器白名单` : '未限制服务器白名单' }}</span><span>{{ token.expiresAt ? `到期 ${dateTime(token.expiresAt)}` : '永不过期' }}</span><span>{{ token.lastUsedAt ? `最后使用 ${dateTime(token.lastUsedAt)}` : '尚未使用' }}</span>
          </div>
          <button v-if="!token.revokedAt" class="table-icon-button danger-command" type="button" title="吊销 Token" aria-label="吊销 Token" @click="revoke(token)"><Trash2 :size="16" /></button>
        </article>
      </div>
      <EmptyState v-else title="暂无 API Token" description="创建一个受限 Token，让移动端或自动化工具访问监控数据。"><el-button type="primary" @click="openCreate"><Plus :size="15" />创建 Token</el-button></EmptyState>
    </article>

    <el-dialog v-model="dialog" title="创建 API Token" width="min(680px, calc(100vw - 28px))" destroy-on-close>
      <div class="token-dialog-intro" role="note"><ShieldCheck :size="17" /><div><strong>先从只读权限开始</strong><p>只选择客户端实际需要的 scope。涉及写入、删除或远程执行的权限会扩大 Token 影响范围。</p></div></div>
      <el-form class="token-create-form" label-position="top">
        <el-form-item label="Token 名称" required><el-input v-model="form.name" maxlength="128" placeholder="例如：移动端只读" /></el-form-item>
        <el-form-item label="权限范围" required>
          <div class="token-scope-summary"><span>已选 {{ selectedScopeCount }} 项</span><small>建议仅保留客户端需要的读取权限</small></div>
          <el-checkbox-group v-model="form.scopes" class="token-scope-groups">
            <section v-for="group in scopeGroups" :key="group.key" class="token-scope-group">
              <div class="token-scope-group-head"><div><strong>{{ group.label }}</strong><p>{{ group.description }}</p></div><span>{{ group.options.length }} 项</span></div>
              <div class="token-scope-options"><el-checkbox v-for="[value, label] in group.options" :key="value" :value="value" :title="value">{{ label }}</el-checkbox></div>
            </section>
          </el-checkbox-group>
        </el-form-item>
        <el-form-item label="服务器 ID 白名单"><el-input v-model="form.serverIds" type="textarea" :rows="3" resize="vertical" placeholder="每行或使用英文逗号分隔，例如：node-a, node-b" /><p class="token-field-help">留空表示不限制服务器；填写后，Token 只能访问列出的设备 ID。</p></el-form-item>
        <el-form-item label="有效期"><div class="token-expiry-control"><el-input-number v-model="form.expiresInDays" :min="0" :max="3650" /><span class="field-suffix">天，0 表示永不过期</span></div></el-form-item>
      </el-form>
      <template #footer><el-button @click="dialog = false">取消</el-button><el-button type="primary" :loading="saving" @click="createToken">创建并显示 Token</el-button></template>
    </el-dialog>

    <el-dialog :model-value="Boolean(created)" title="立即保存 API Token" width="min(620px, calc(100vw - 28px))" :close-on-click-modal="false" :close-on-press-escape="false" :show-close="false">
      <div v-if="created" class="credential-panel"><div class="credential-warning"><KeyRound :size="18" /><p><strong>明文只显示这一次</strong><span>请立即完成鸿蒙 App 绑定，或复制并保存到安全的密钥管理器。PAT 可重复用于请求，直至到期或被吊销；关闭窗口后仅无法再次查看明文。</span></p></div><MobileBindingPanel :base-url="mobileBindingBaseUrl" :token="created.secret" :scopes="created.token.scopes" :token-expires-at="created.token.expiresAt" /><div class="credential-secret"><span>Token 明文</span><code>{{ created.secret }}</code></div><dl><div><dt>Token 名称</dt><dd>{{ created.token.name }}</dd></div><div><dt>权限范围</dt><dd><span v-for="scope in created.token.scopes" :key="scope" class="token-scope-tag" :title="scope">{{ apiTokenScopeLabel(scope) }}</span></dd></div><div><dt>服务器范围</dt><dd>{{ created.token.serverIds.length ? `${created.token.serverIds.length} 台服务器白名单` : '未限制服务器白名单' }}</dd></div></dl></div>
      <template #footer><el-button @click="closeCreated">我已保存</el-button><el-button type="primary" @click="copyCreated"><CheckCircle2 v-if="copied" :size="16" /><Copy v-else :size="16" />{{ copied ? '已复制 Token' : '复制 Token' }}</el-button></template>
    </el-dialog>
  </section>
</template>
