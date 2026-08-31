<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { Copy, Plus, Radar, RefreshCw, Search, Square, Timer } from 'lucide-vue-next'
import { ElMessage } from 'element-plus'
import PageHeader from '@/components/PageHeader.vue'
import EmptyState from '@/components/EmptyState.vue'
import LoadingState from '@/components/LoadingState.vue'
import { api, errorMessage } from '@/lib/api'
import { copyText } from '@/lib/clipboard'
import { dateTime } from '@/lib/format'
import { useRouter } from 'vue-router'
import type { DiscoveryDetail, DiscoveryResult, DiscoveryScan, DiscoveryScanStatus } from '@/types'

const router = useRouter()
const tasks = ref<DiscoveryScan[]>([])
const selected = ref<DiscoveryDetail | null>(null)
const loading = ref(true)
const starting = ref(false)
const error = ref('')
const form = reactive({ cidr: '192.168.1.0/24', ports: '22,80,443,8080', timeoutMs: 500, concurrency: 16 })
let timer = 0

const active = computed(() => tasks.value.some((task) => task.status === 'QUEUED' || task.status === 'RUNNING'))
const progress = computed(() => {
  const scan = selected.value?.scan
  return scan && scan.totalHosts ? Math.round((scan.scannedHosts / scan.totalHosts) * 100) : 0
})
const statusLabels: Record<DiscoveryScanStatus, string> = { QUEUED: '排队中', RUNNING: '扫描中', SUCCEEDED: '已完成', FAILED: '失败', CANCELED: '已取消' }

async function load(silent = false) {
  if (!silent) loading.value = true
  error.value = ''
  try {
    tasks.value = (await api.get<DiscoveryScan[]>('/discovery', { params: { limit: 30 } })).data
    const current = selected.value?.scan.id
    if (current) await loadDetail(current)
    else if (tasks.value.length) await loadDetail(tasks.value[0].id)
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

async function loadDetail(id: number) {
  try { selected.value = (await api.get<DiscoveryDetail>(`/discovery/${id}`)).data }
  catch (cause) { error.value = errorMessage(cause) }
}

async function start() {
  const ports = form.ports.split(/[,\s]+/).map((value) => Number(value)).filter((value) => Number.isInteger(value) && value > 0)
  if (!ports.length) { ElMessage.warning('请输入至少一个端口'); return }
  starting.value = true
  try {
    const scan = (await api.post<DiscoveryScan>('/discovery', { cidr: form.cidr.trim(), ports, timeoutMs: form.timeoutMs, concurrency: form.concurrency })).data
    ElMessage.success(`扫描任务已创建，将探测 ${scan.totalHosts} 个地址`)
    await load()
    await loadDetail(scan.id)
  } catch (cause) { ElMessage.error(errorMessage(cause)) }
  finally { starting.value = false }
}

async function cancel() {
  if (!selected.value || (selected.value.scan.status !== 'QUEUED' && selected.value.scan.status !== 'RUNNING')) return
  try { await api.post(`/discovery/${selected.value.scan.id}/cancel`); ElMessage.success('扫描已取消'); await load() }
  catch (cause) { ElMessage.error(errorMessage(cause)) }
}

async function copyAddress(result: DiscoveryResult) {
  try { await copyText(result.address); ElMessage.success('地址已复制') }
  catch { ElMessage.warning('浏览器禁止自动复制，请手动复制地址') }
}

function addDevice(result: DiscoveryResult) { void router.push({ name: 'devices', query: { add: result.address } }) }
function openPorts(result: DiscoveryResult) { return result.openPorts.length ? result.openPorts.join(', ') : '主机可达，未发现开放端口' }

onMounted(() => { void load(); timer = window.setInterval(() => { if (active.value) void load(true) }, 2500) })
onBeforeUnmount(() => window.clearInterval(timer))
</script>

<template>
  <section>
    <PageHeader eyebrow="NETWORK DISCOVERY" title="网络发现" description="从总控服务器探测私网地址与常见服务端口，快速补齐设备清单。">
      <template #actions><el-button @click="load"><RefreshCw :size="16" />刷新</el-button></template>
    </PageHeader>

    <div class="discovery-layout">
      <article class="panel discovery-launch-panel">
        <header class="panel-head"><div><h2>发起扫描</h2><p>仅支持 /24 到 /32 的 RFC1918 私网网段</p></div><Radar :size="20" /></header>
        <el-form label-position="top" @submit.prevent="start">
          <el-form-item label="IPv4 CIDR" required><el-input v-model="form.cidr" placeholder="例如 192.168.1.0/24"><template #prefix><Search :size="15" /></template></el-input></el-form-item>
          <el-form-item label="探测端口"><el-input v-model="form.ports" placeholder="22, 80, 443, 8080" /><p class="field-help">最多 32 个端口，使用逗号或空格分隔。</p></el-form-item>
          <div class="form-grid two-fields"><el-form-item label="单端口超时"><el-input-number v-model="form.timeoutMs" :min="50" :max="3000" :step="50" controls-position="right"><template #suffix>ms</template></el-input-number></el-form-item><el-form-item label="并发主机数"><el-input-number v-model="form.concurrency" :min="1" :max="32" controls-position="right" /></el-form-item></div>
          <el-button class="button-press" type="primary" :loading="starting" native-type="submit"><Radar :size="16" />开始扫描</el-button>
        </el-form>
        <div class="discovery-safety"><Timer :size="15" /><span>扫描运行在总控服务器，范围和资源均有硬限制，不会探测公网地址。</span></div>
      </article>

      <article class="panel discovery-history-panel">
        <header class="panel-head"><div><h2>扫描记录</h2><p>{{ tasks.length }} 条任务 · 运行中的任务会自动刷新</p></div></header>
        <LoadingState v-if="loading && !tasks.length" />
        <div v-else-if="error && !tasks.length" class="discovery-error">{{ error }}<el-button text @click="load">重试</el-button></div>
        <div v-else-if="tasks.length" class="discovery-task-list">
          <button v-for="task in tasks" :key="task.id" type="button" class="discovery-task" :class="{ selected: selected?.scan.id === task.id }" @click="loadDetail(task.id)"><span><strong>{{ task.cidr }}</strong><small>{{ dateTime(task.createdAt) }} · {{ task.createdBy }}</small></span><span class="discovery-task-meta"><b>{{ task.discoveredHosts }} 台</b><em :data-status="task.status">{{ statusLabels[task.status] }}</em></span></button>
        </div>
        <EmptyState v-else title="暂无扫描记录" description="输入一个私网网段后开始第一次发现。"><Radar :size="1" /></EmptyState>
      </article>
    </div>

    <article v-if="selected" class="panel discovery-results-panel">
      <header class="panel-head"><div><h2>发现结果</h2><p>{{ selected.scan.cidr }} · {{ selected.scan.scannedHosts }} / {{ selected.scan.totalHosts }} 个地址已检查</p></div><div class="discovery-result-actions"><span v-if="selected.scan.status === 'RUNNING'" class="discovery-progress"><span :style="{ width: `${progress}%` }" />{{ progress }}%</span><el-button v-if="selected.scan.status === 'QUEUED' || selected.scan.status === 'RUNNING'" type="danger" plain @click="cancel"><Square :size="15" />取消扫描</el-button><el-button @click="loadDetail(selected.scan.id)"><RefreshCw :size="15" />刷新结果</el-button></div></header>
      <div v-if="selected.scan.error" class="discovery-error" role="alert">{{ selected.scan.error }}</div>
      <div v-if="selected.results.length" class="table-wrap"><table class="data-table discovery-table"><thead><tr><th>地址</th><th>可达性</th><th>开放端口</th><th>响应耗时</th><th class="actions-column">操作</th></tr></thead><tbody><tr v-for="result in selected.results" :key="result.id"><td><strong class="mono-value">{{ result.address }}</strong><small v-if="result.hostname" class="cell-subtext">{{ result.hostname }}</small></td><td><span class="discovery-reachable" :data-reachable="result.reachable">{{ result.reachable ? '主机可达' : '端口可达' }}</span></td><td><span class="port-list">{{ openPorts(result) }}</span></td><td>{{ result.latencyMs == null ? '--' : `${result.latencyMs} ms` }}</td><td class="row-actions"><button class="table-icon-button" type="button" title="复制地址" aria-label="复制地址" @click="copyAddress(result)"><Copy :size="16" /></button><button class="table-icon-button" type="button" title="使用地址添加设备" aria-label="使用地址添加设备" @click="addDevice(result)"><Plus :size="16" /></button></td></tr></tbody></table></div>
      <EmptyState v-else-if="selected.scan.status === 'SUCCEEDED'" title="未发现在线主机" description="可以调整端口范围或确认总控服务器与目标网段之间的路由。"><Radar :size="1" /></EmptyState>
      <div v-else class="discovery-waiting"><span class="spinner" />正在扫描地址，完成后会显示结果。</div>
    </article>
  </section>
</template>
