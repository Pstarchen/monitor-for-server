<script setup lang="ts">
import * as echarts from 'echarts'
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'

const props = defineProps<{
  labels: string[]
  series: { name: string; data: number[]; color: string }[]
  unit?: string
}>()
const root = ref<HTMLDivElement>()
let chart: echarts.ECharts | null = null

function render() {
  if (!root.value) return
  if (!chart) chart = echarts.init(root.value)
  const dark = document.documentElement.classList.contains('dark')
  chart.setOption({
    animationDuration: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : 420,
    grid: { left: 42, right: 14, top: 24, bottom: 30 },
    tooltip: { trigger: 'axis', valueFormatter: (value: unknown) => `${Number(value).toFixed(1)}${props.unit ?? ''}` },
    legend: { top: 0, right: 8, textStyle: { color: dark ? '#a3a3a3' : '#626262' } },
    xAxis: { type: 'category', data: props.labels, boundaryGap: false, axisLine: { lineStyle: { color: dark ? '#393939' : '#e4e4e4' } }, axisLabel: { color: dark ? '#8d8d8d' : '#767676', hideOverlap: true } },
    yAxis: { type: 'value', axisLabel: { color: dark ? '#8d8d8d' : '#767676', formatter: `{value}${props.unit ?? ''}` }, splitLine: { lineStyle: { color: dark ? '#2b2b2b' : '#eeeeee' } } },
    series: props.series.map((item) => ({ name: item.name, data: item.data, type: 'line', showSymbol: false, smooth: 0.25, lineStyle: { width: 2, color: item.color }, itemStyle: { color: item.color }, areaStyle: { opacity: 0.04, color: item.color } })),
  }, true)
}

function resize() { chart?.resize() }
watch(() => [props.labels, props.series], () => nextTick(render), { deep: true })
onMounted(() => { render(); window.addEventListener('resize', resize) })
onBeforeUnmount(() => { window.removeEventListener('resize', resize); chart?.dispose() })
</script>

<template><div ref="root" class="metric-chart" role="img" aria-label="监控指标趋势图" /></template>

