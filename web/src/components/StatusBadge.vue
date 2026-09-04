<script setup lang="ts">
const props = defineProps<{ status: string; label?: string }>()
const labels: Record<string, string> = {
  ONLINE: '在线', OFFLINE: '离线', PENDING: '待接入', OPEN: '待处理', ACKNOWLEDGED: '已确认', RESOLVED: '已恢复',
  CRITICAL: '严重', WARNING: '警告', INFO: '提示', running: '运行中', stopped: '已停止', not_found: '未找到',
  QUEUED: '排队中', RUNNING: '执行中', SUCCEEDED: '成功', FAILED: '失败', TIMED_OUT: '超时', CANCELED: '已取消',
  ACTIVE: '生效中', SCHEDULED: '待执行', ENDED: '已结束', DISABLED: '已停用',
  DRAFT: '草稿', PAUSED: '已暂停', ROLLING_BACK: '回滚中', ROLLED_BACK: '已回滚',
  ACCEPTED: '等待确认', CONFIRMED: '已确认', ROLLBACK_PENDING: '待回滚', ROLLBACK_QUEUED: '回滚排队中',
  ROLLBACK_ACCEPTED: '等待回滚确认', ROLLBACK_CONFIRMED: '回滚已确认', ROLLBACK_FAILED: '回滚失败',
}
function tone(status: string) {
  if (['ONLINE', 'RESOLVED', 'running', 'SUCCEEDED', 'ACTIVE', 'CONFIRMED', 'ROLLED_BACK', 'ROLLBACK_CONFIRMED'].includes(status)) return 'success'
  if (['OFFLINE', 'OPEN', 'CRITICAL', 'stopped', 'FAILED', 'TIMED_OUT', 'ROLLBACK_FAILED'].includes(status)) return 'danger'
  if (['PENDING', 'ACKNOWLEDGED', 'WARNING', 'QUEUED', 'RUNNING', 'SCHEDULED', 'PAUSED', 'ACCEPTED', 'ROLLING_BACK', 'ROLLBACK_PENDING', 'ROLLBACK_QUEUED', 'ROLLBACK_ACCEPTED'].includes(status)) return 'warning'
  return 'info'
}
</script>

<template><span class="status-badge" :data-tone="tone(props.status)"><i />{{ props.label ?? labels[props.status] ?? props.status }}</span></template>
