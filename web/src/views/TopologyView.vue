<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { CircleAlert, ExternalLink, GitBranch, RefreshCw, Server, Waypoints } from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import EmptyState from '@/components/EmptyState.vue'
import LoadingState from '@/components/LoadingState.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import { api, errorMessage } from '@/lib/api'
import { percent } from '@/lib/format'
import type { Topology, TopologyEdge, TopologyNode } from '@/types'

const topology = ref<Topology | null>(null)
const loading = ref(true)
const error = ref('')
const selectedNodeId = ref('')

const selectedNode = computed(() => topology.value?.nodes.find((node) => node.id === selectedNodeId.value) ?? null)
const visibleEdges = computed(() => topology.value?.edges.filter((edge) => !selectedNodeId.value || edge.source === selectedNodeId.value || edge.target === selectedNodeId.value) ?? [])
const deviceNodes = computed(() => topology.value?.nodes.filter((node) => node.kind === 'DEVICE') ?? [])

async function load() {
  loading.value = true
  error.value = ''
  try {
    topology.value = (await api.get<Topology>('/topology')).data
    if (!selectedNodeId.value || !topology.value.nodes.some((node) => node.id === selectedNodeId.value)) selectedNodeId.value = ''
  } catch (cause) {
    error.value = errorMessage(cause)
  } finally {
    loading.value = false
  }
}

function nodeLabel(node: TopologyNode) {
  return node.kind === 'CONTROLLER' ? '总控' : node.kind === 'EXTERNAL' ? '外部目标' : '监控节点'
}

function edgeLabel(edge: TopologyEdge) {
  if (edge.status === 'UP') return edge.latencyMs == null ? '正常' : `${edge.latencyMs} ms`
  if (edge.status === 'DOWN') return '异常'
  if (edge.status === 'DISABLED') return '已停用'
  return '等待数据'
}

function nodeStatus(node: TopologyNode) {
  if (node.kind === 'EXTERNAL') return 'PENDING'
  return node.status
}

function nodeTone(node: TopologyNode) {
  if (node.kind === 'CONTROLLER') return 'controller'
  if (node.kind === 'EXTERNAL') return 'external'
  return node.status.toLowerCase()
}

function resetSelection() {
  selectedNodeId.value = ''
}

onMounted(load)
</script>

<template>
  <section>
    <PageHeader eyebrow="TOPOLOGY" title="网络拓扑" description="从服务探测目标推断总控、监控节点与外部服务的关系，帮助快速定位影响范围。">
      <template #actions><el-button @click="load"><RefreshCw :size="16" />刷新</el-button></template>
    </PageHeader>

    <LoadingState v-if="loading && !topology" />
    <div v-else-if="error && !topology" class="panel state-panel"><EmptyState title="拓扑加载失败" :description="error"><el-button @click="load">重新加载</el-button></EmptyState></div>
    <template v-else-if="topology">
      <div class="topology-summary">
        <div><span><Waypoints :size="16" />节点</span><strong>{{ topology.nodes.length }}</strong></div>
        <div><span><GitBranch :size="16" />服务关系</span><strong>{{ topology.monitoredServices }}</strong></div>
        <div><span><CircleAlert :size="16" />未解析目标</span><strong>{{ topology.unresolvedServices }}</strong></div>
      </div>
      <div v-if="error" class="topology-notice" role="alert"><CircleAlert :size="16" />{{ error }}<el-button text @click="load">重试</el-button></div>
      <div v-if="topology.nodes.length > 1" class="topology-workspace">
        <article class="panel topology-canvas-panel">
          <header class="panel-head"><div><h2>关系图</h2><p>点击节点筛选相关探测关系</p></div><button v-if="selectedNodeId" type="button" class="table-icon-button" title="清除节点筛选" aria-label="清除节点筛选" @click="resetSelection">×</button></header>
          <div class="topology-canvas" role="list" aria-label="网络拓扑节点">
            <div class="topology-column topology-controller-column"><button v-for="node in topology.nodes.filter((item) => item.kind === 'CONTROLLER')" :key="node.id" type="button" class="topology-node" :class="[nodeTone(node), { selected: selectedNodeId === node.id }]" @click="selectedNodeId = node.id"><span class="topology-node-icon"><Server :size="20" /></span><span><strong>{{ node.label }}</strong><small>{{ nodeLabel(node) }}</small></span><StatusBadge :status="nodeStatus(node)" /></button></div>
            <div class="topology-connections" aria-hidden="true"><span v-for="edge in visibleEdges" :key="`line-${edge.id}`" class="topology-connection" :data-status="edge.status"><i /><small>{{ edge.label }}</small><b>{{ edgeLabel(edge) }}</b></span></div>
            <div class="topology-column topology-target-column"><button v-for="node in topology.nodes.filter((item) => item.kind !== 'CONTROLLER')" :key="node.id" type="button" class="topology-node" :class="[nodeTone(node), { selected: selectedNodeId === node.id }]" @click="selectedNodeId = node.id"><span class="topology-node-icon"><ExternalLink v-if="node.kind === 'EXTERNAL'" :size="20" /><Server v-else :size="20" /></span><span><strong>{{ node.label }}</strong><small>{{ node.address || nodeLabel(node) }}</small></span><StatusBadge :status="nodeStatus(node)" /><em v-if="node.serviceCount">{{ node.serviceCount }} 项服务</em></button></div>
          </div>
        </article>
        <aside class="panel topology-detail-panel"><header class="panel-head"><div><h2>节点详情</h2><p>{{ selectedNode ? selectedNode.label : '选择一个节点查看关系' }}</p></div></header><div v-if="selectedNode" class="topology-detail"><div class="topology-detail-title"><span class="topology-node-icon"><Server v-if="selectedNode.kind !== 'EXTERNAL'" :size="18" /><ExternalLink v-else :size="18" /></span><div><strong>{{ selectedNode.label }}</strong><small>{{ nodeLabel(selectedNode) }}</small></div><StatusBadge :status="nodeStatus(selectedNode)" /></div><dl><div><dt>地址</dt><dd>{{ selectedNode.address || '--' }}</dd></div><div><dt>主机名</dt><dd>{{ selectedNode.hostname || '--' }}</dd></div><div><dt>服务数</dt><dd>{{ selectedNode.serviceCount }}</dd></div><div v-if="selectedNode.kind === 'DEVICE'"><dt>CPU / 内存 / 磁盘</dt><dd>{{ selectedNode.cpuUsage == null ? '--' : `${percent(selectedNode.cpuUsage)} / ${percent(selectedNode.memoryUsage)} / ${percent(selectedNode.diskUsage)}` }}</dd></div></dl><div class="topology-related-list"><strong>相关探测</strong><p v-if="!visibleEdges.length">暂无关系</p><button v-for="edge in visibleEdges" :key="edge.id" type="button" @click="selectedNodeId = edge.target"><span>{{ edge.label }}</span><StatusBadge :status="edge.status" /><small>{{ edge.targetHost || '外部目标' }}</small></button></div></div><EmptyState v-else title="暂无节点选择" description="点击左侧关系图中的节点，查看服务探测、地址和资源摘要。"><Waypoints :size="1" /></EmptyState></aside>
      </div>
      <div v-else class="panel"><EmptyState title="暂无拓扑关系" description="创建服务监控并填写可解析的目标地址后，拓扑会自动生成节点关系。"><GitBranch :size="1" /></EmptyState></div>
      <section v-if="deviceNodes.length" class="panel topology-mobile-list"><header class="panel-head"><div><h2>节点列表</h2><p>移动端使用列表查看节点与关系</p></div></header><div class="topology-node-list"><button v-for="node in deviceNodes" :key="node.id" type="button" @click="selectedNodeId = node.id"><span><strong>{{ node.label }}</strong><small>{{ node.address || node.hostname || '--' }}</small></span><StatusBadge :status="nodeStatus(node)" /><b>{{ node.serviceCount }} 项服务</b></button></div></section>
    </template>
  </section>
</template>
