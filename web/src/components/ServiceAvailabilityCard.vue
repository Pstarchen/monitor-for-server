<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { Activity, CheckCircle2, Clock3, CircleAlert } from 'lucide-vue-next'
import { dateTime, relativeTime } from '@/lib/format'

type AvailabilityRecord = {
  checkedAt: string
  success: boolean
  latencyMs: number
  statusCode?: number | null
  certificateExpiresAt?: string | null
  error?: string | null
}

const props = withDefaults(defineProps<{
  name: string
  typeLabel: string
  subtitle?: string
  latest: AvailabilityRecord | null
  history: AvailabilityRecord[]
  availabilityPercent?: number | null
  latencyThresholdMs?: number
  refreshIntervalSeconds?: number
}>(), {
  subtitle: '',
  availabilityPercent: null,
  latencyThresholdMs: 0,
  refreshIntervalSeconds: 30,
})

const refreshCountdown = ref(props.refreshIntervalSeconds)
let countdownTimer = 0

const records = computed(() => {
  const history = Array.isArray(props.history) ? props.history : []
  return history.length ? history.slice(-60) : props.latest ? [props.latest] : []
})

const barSlots = computed(() => {
  const source = records.value
  return Array.from({ length: 60 }, (_, index) => source[index - (60 - source.length)] ?? null)
})

const availability = computed(() => {
  if (typeof props.availabilityPercent === 'number' && Number.isFinite(props.availabilityPercent)) return props.availabilityPercent
  if (!records.value.length) return null
  return records.value.filter((record) => record.success).length / records.value.length * 100
})

const scoreTone = computed(() => {
  if (availability.value === null) return 'empty'
  if (availability.value >= 90) return 'success'
  if (availability.value >= 75) return 'warning'
  return 'danger'
})

const displayScore = computed(() => availability.value === null ? '--.--' : availability.value.toFixed(2))

function barState(record: AvailabilityRecord | null) {
  if (!record) return 'empty'
  if (!record.success) return 'danger'
  const threshold = props.latencyThresholdMs > 0 ? props.latencyThresholdMs : 1000
  return record.latencyMs >= threshold ? 'warning' : 'success'
}

function barHeight(record: AvailabilityRecord | null) {
  if (!record) return '20%'
  return `${Math.max(42, 100 - Math.min(58, record.latencyMs / 35))}%`
}

function recordLabel(record: AvailabilityRecord | null) {
  if (!record) return '尚无探测记录'
  const status = record.success ? '正常' : '异常'
  const latency = Number.isFinite(record.latencyMs) ? ` · ${record.latencyMs} ms` : ''
  const code = record.statusCode ? ` · ${record.statusCode}` : ''
  return `${dateTime(record.checkedAt)} · ${status}${latency}${code}${record.error ? ` · ${record.error}` : ''}`
}

function resetCountdown() {
  refreshCountdown.value = props.refreshIntervalSeconds
}

function tickCountdown() {
  if (refreshCountdown.value <= 0) resetCountdown()
  else refreshCountdown.value -= 1
}

watch(() => [props.latest?.checkedAt, Array.isArray(props.history) ? props.history.length : 0], resetCountdown)
onMounted(() => {
  countdownTimer = window.setInterval(tickCountdown, 1000)
})
onBeforeUnmount(() => window.clearInterval(countdownTimer))
</script>

<template>
  <article class="availability-card" :data-tone="scoreTone">
    <header class="availability-head">
      <div class="availability-heading">
        <div class="availability-title-row">
          <span class="availability-icon"><Activity :size="15" /></span>
          <h3>{{ name }}</h3>
          <slot name="actions" />
        </div>
        <p>{{ typeLabel }}<template v-if="subtitle"> · {{ subtitle }}</template></p>
      </div>
      <div class="availability-score" :aria-label="availability === null ? '暂无可用性数据' : `7 天可用性 ${displayScore}%`">
        <strong>{{ displayScore }}<small>%</small></strong>
        <span>可用性 · 7 天</span>
      </div>
    </header>

    <div class="availability-rule" />
    <div class="availability-meta"><span>近 {{ records.length || 0 }} 次记录</span><span>{{ refreshCountdown }}s 后刷新</span></div>
    <div class="availability-bars" role="img" :aria-label="`${name} 最近 ${records.length || 0} 次探测记录`">
      <span v-for="(record, index) in barSlots" :key="`${record?.checkedAt || 'empty'}-${index}`" class="availability-bar" :data-state="barState(record)" :style="{ height: barHeight(record) }" :title="recordLabel(record)" :aria-label="recordLabel(record)" />
    </div>
    <div class="availability-axis"><span>过去</span><span>现在</span></div>
    <div v-if="$slots.details" class="availability-details"><slot name="details" /></div>
    <footer class="availability-foot">
      <span :data-state="latest ? barState(latest) : 'empty'"><CheckCircle2 v-if="latest?.success" :size="13" /><CircleAlert v-else-if="latest" :size="13" /><Clock3 v-else :size="13" />{{ latest ? (latest.success ? '最新正常' : '最新异常') : '等待首次探测' }}</span>
      <small v-if="latest">{{ relativeTime(latest.checkedAt) }} · {{ latest.latencyMs }} ms</small>
    </footer>
  </article>
</template>
