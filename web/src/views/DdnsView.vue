<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { Pencil, Plus, RefreshCw, Trash2, Zap } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import EmptyState from '@/components/EmptyState.vue'
import LoadingState from '@/components/LoadingState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { dateTime } from '@/lib/format'
import type { DdnsConfig, DdnsHttpMethod, DdnsProvider } from '@/types'
import { useAuthStore } from '@/stores/auth'

const configs = ref<DdnsConfig[]>([])
const auth = useAuthStore()
const canEdit = computed(() => auth.user?.role === 'ADMIN' || auth.user?.role === 'OPERATOR')
const loading = ref(true)
const dialog = ref(false)
const editing = ref<number | null>(null)
const saving = ref(false)
const form = reactive({ name: '', provider: 'WEBHOOK' as DdnsProvider, domains: '', webhookUrl: '', method: 'GET' as DdnsHttpMethod, headersJson: '', bodyTemplate: '{"domain":"#domain#","ip":"#ip#","type":"#type#"}', credentialOne: '', credentialTwo: '', enabled: true, ipv4Enabled: true, ipv6Enabled: false, maxRetries: 3 })

async function load() { loading.value = true; try { configs.value = (await api.get<DdnsConfig[]>('/ddns')).data } catch (cause) { ElMessage.error(errorMessage(cause)) } finally { loading.value = false } }
function openCreate() { editing.value = null; Object.assign(form, { name: '', provider: 'WEBHOOK', domains: '', webhookUrl: '', method: 'GET', headersJson: '', bodyTemplate: '{"domain":"#domain#","ip":"#ip#","type":"#type#"}', credentialOne: '', credentialTwo: '', enabled: true, ipv4Enabled: true, ipv6Enabled: false, maxRetries: 3 }); dialog.value = true }
function openEdit(config: DdnsConfig) { editing.value = config.id; Object.assign(form, { name: config.name, provider: config.provider, domains: config.domains.join(', '), webhookUrl: '', method: config.method, headersJson: '', bodyTemplate: '', credentialOne: '', credentialTwo: '', enabled: config.enabled, ipv4Enabled: config.ipv4Enabled, ipv6Enabled: config.ipv6Enabled, maxRetries: config.maxRetries }); dialog.value = true }
async function save() { if (!form.name.trim() || !form.domains.trim() || (!form.ipv4Enabled && !form.ipv6Enabled)) { ElMessage.warning('请填写名称、域名并启用 IPv4 或 IPv6'); return }; saving.value = true; try { const payload = { ...form, domains: form.domains.split(/[,\n]/).map((item) => item.trim()).filter(Boolean), webhookUrl: form.webhookUrl || null, headersJson: form.headersJson || null, bodyTemplate: form.bodyTemplate || null, credentialOne: form.credentialOne || null, credentialTwo: form.credentialTwo || null }; if (editing.value) await api.put(`/ddns/${editing.value}`, payload); else await api.post('/ddns', payload); dialog.value = false; ElMessage.success('DDNS 配置已保存'); await load() } catch (cause) { ElMessage.error(errorMessage(cause)) } finally { saving.value = false } }
async function remove(config: DdnsConfig) { try { await ElMessageBox.confirm(`确定删除“${config.name}”吗？`, '删除 DDNS 配置', { type: 'warning' }); await api.delete(`/ddns/${config.id}`); await load(); ElMessage.success('已删除') } catch (cause) { if (cause !== 'cancel' && cause !== 'close') ElMessage.error(errorMessage(cause)) } }
async function test(config: DdnsConfig) { try { const ip = window.prompt('输入用于测试的 IP 地址', '127.0.0.1'); if (!ip) return; await api.post(`/ddns/${config.id}/test`, null, { params: { ip } }); ElMessage.success('DDNS 测试已执行'); await load() } catch (cause) { ElMessage.error(errorMessage(cause)) } }
onMounted(load)
</script>

<template>
  <section>
    <PageHeader eyebrow="NETWORK AUTOMATION" title="动态域名解析" description="Agent 上报新地址后，按设备关联的配置更新 DDNS。凭据只在服务端加密保存。">
      <template #actions><el-button @click="load"><RefreshCw :size="16" />刷新</el-button><el-button v-if="canEdit" type="primary" @click="openCreate"><Plus :size="16" />新建配置</el-button></template>
    </PageHeader>
    <LoadingState v-if="loading" />
    <article v-else class="panel"><div v-if="configs.length" class="table-wrap"><table class="data-table"><thead><tr><th>配置</th><th>供应商</th><th>域名</th><th>地址类型</th><th>状态</th><th>最近更新</th><th class="actions-column">操作</th></tr></thead><tbody><tr v-for="config in configs" :key="config.id"><td><strong>{{ config.name }}</strong><small>{{ config.maxRetries }} 次重试</small></td><td>{{ config.provider === 'WEBHOOK' ? 'Webhook' : '测试适配器' }}</td><td class="mono-value">{{ config.domains.join(', ') }}</td><td>{{ [config.ipv4Enabled ? 'IPv4' : '', config.ipv6Enabled ? 'IPv6' : ''].filter(Boolean).join(' / ') }}</td><td><StatusBadge :status="config.enabled ? (config.lastStatus === 'FAILED' ? 'OFFLINE' : 'ONLINE') : 'PENDING'" /></td><td>{{ config.lastUpdatedAt ? dateTime(config.lastUpdatedAt) : '--' }}</td><td v-if="canEdit" class="row-actions"><button class="table-icon-button" title="测试更新" aria-label="测试更新" @click="test(config)"><Zap :size="16" /></button><button class="table-icon-button" title="编辑配置" aria-label="编辑配置" @click="openEdit(config)"><Pencil :size="16" /></button><button class="table-icon-button danger-command" title="删除配置" aria-label="删除配置" @click="remove(config)"><Trash2 :size="16" /></button></td><td v-else>--</td></tr></tbody></table></div><EmptyState v-else title="暂无 DDNS 配置" description="创建配置后，在设备编辑中选择关联的 DDNS。"><el-button v-if="canEdit" type="primary" @click="openCreate"><Plus :size="16" />新建配置</el-button></EmptyState></article>
    <el-dialog v-model="dialog" :title="editing ? '编辑 DDNS 配置' : '新建 DDNS 配置'" width="min(720px, calc(100vw - 28px))" destroy-on-close><el-form label-position="top"><div class="form-grid two-fields"><el-form-item label="名称" required><el-input v-model="form.name" maxlength="100" /></el-form-item><el-form-item label="供应商"><el-select v-model="form.provider"><el-option label="Webhook" value="WEBHOOK" /><el-option label="测试适配器" value="DUMMY" /></el-select></el-form-item></div><el-form-item label="域名（逗号或换行分隔）" required><el-input v-model="form.domains" type="textarea" :rows="2" /></el-form-item><template v-if="form.provider === 'WEBHOOK'"><el-form-item label="Webhook URL"><el-input v-model="form.webhookUrl" placeholder="https://example.com/ddns" /></el-form-item><div class="form-grid two-fields"><el-form-item label="请求方式"><el-select v-model="form.method"><el-option v-for="method in ['GET','POST','PUT','PATCH','DELETE']" :key="method" :label="method" :value="method" /></el-select></el-form-item><el-form-item label="最大重试次数"><el-input-number v-model="form.maxRetries" :min="1" :max="10" /></el-form-item></div><el-form-item label="请求头 JSON（可选，更新时留空保留）"><el-input v-model="form.headersJson" type="textarea" :rows="2" placeholder='{"Authorization":"Bearer #access_secret#"}' /></el-form-item><el-form-item label="请求体模板"><el-input v-model="form.bodyTemplate" type="textarea" :rows="3" placeholder="#domain# #ip# #type# #record# #access_id# #access_secret#" /></el-form-item><div class="form-grid two-fields"><el-form-item label="凭据 1"><el-input v-model="form.credentialOne" type="password" show-password /></el-form-item><el-form-item label="凭据 2"><el-input v-model="form.credentialTwo" type="password" show-password /></el-form-item></div></template><div class="form-grid two-fields"><el-checkbox v-model="form.enabled">启用配置</el-checkbox><span class="form-inline-checks"><el-checkbox v-model="form.ipv4Enabled">IPv4</el-checkbox><el-checkbox v-model="form.ipv6Enabled">IPv6</el-checkbox></span></div></el-form><template #footer><el-button @click="dialog = false">取消</el-button><el-button type="primary" :loading="saving" @click="save">保存</el-button></template></el-dialog>
  </section>
</template>
