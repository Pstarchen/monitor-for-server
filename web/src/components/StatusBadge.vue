<script setup lang="ts">
const props = defineProps<{ status: string }>()
const labels: Record<string, string> = {
  ONLINE: '在线', OFFLINE: '离线', PENDING: '待接入', OPEN: '待处理', ACKNOWLEDGED: '已确认', RESOLVED: '已恢复',
  CRITICAL: '严重', WARNING: '警告', INFO: '提示', running: '运行中', stopped: '已停止', not_found: '未找到',
  QUEUED: '排队中', RUNNING: '执行中', SUCCEEDED: '成功', FAILED: '失败', TIMED_OUT: '超时', CANCELED: '已取消',
  ACTIVE: '生效中', SCHEDULED: '待执行', ENDED: '已结束', DISABLED: '已停用',
}
function tone(status: string) {
  if (['ONLINE', 'RESOLVED', 'running', 'SUCCEEDED', 'ACTIVE'].includes(status)) return 'success'
  if (['OFFLINE', 'OPEN', 'CRITICAL', 'stopped', 'FAILED', 'TIMED_OUT'].includes(status)) return 'danger'
  if (['PENDING', 'ACKNOWLEDGED', 'WARNING', 'QUEUED', 'RUNNING', 'SCHEDULED'].includes(status)) return 'warning'
  return 'info'
}
</script>

<template><span class="status-badge" :data-tone="tone(props.status)"><i />{{ labels[props.status] ?? props.status }}</span></template>
