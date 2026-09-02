<script setup lang="ts">
import { LineChart } from 'echarts/charts'
import { GridComponent, LegendComponent, TooltipComponent } from 'echarts/components'
import { init, use } from 'echarts/core'
import { CanvasRenderer } from 'echarts/renderers'
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'

use([LineChart, GridComponent, LegendComponent, TooltipComponent, CanvasRenderer])

const props = defineProps<{
  labels: string[]
  series: { name: string; data: Array<number | null>; color: string }[]
  unit?: string
  ariaLabel?: string
}>()
const root = ref<HTMLDivElement>()
let chart: ReturnType<typeof init> | null = null
let resizeObserver: ResizeObserver | null = null
let themeObserver: MutationObserver | null = null
let visibilityObserver: IntersectionObserver | null = null
let renderedDark: boolean | null = null
let renderFrame = 0
let visible = false

function renderNow() {
  if (!root.value || root.value.clientWidth === 0 || root.value.clientHeight === 0) return
  if (!chart) chart = init(root.value, undefined, { renderer: 'canvas' })
  const dark = document.documentElement.classList.contains('dark')
  const unit = (props.unit ?? '').trim()
  const suffix = unit && unit !== '%' ? ` ${unit}` : unit
  const formatValue = (value: unknown) => {
    const numeric = Number(value)
    if (!Number.isFinite(numeric)) return '--'
    return `${Math.abs(numeric) >= 100 ? numeric.toFixed(0) : numeric.toFixed(1)}${suffix}`
  }
  chart.setOption({
    animationDuration: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : 240,
    grid: { left: 12, right: 14, top: 34, bottom: 30, containLabel: true },
    tooltip: {
      trigger: 'axis',
      valueFormatter: formatValue,
      backgroundColor: dark ? '#202327' : '#ffffff',
      borderColor: dark ? '#3a3f46' : '#e3e3e3',
      textStyle: { color: dark ? '#f1f1f1' : '#171717' },
      axisPointer: { lineStyle: { color: dark ? '#5d636d' : '#b8bcc3' } },
    },
    legend: { top: 0, right: 8, textStyle: { color: dark ? '#a3a3a3' : '#626262' } },
    xAxis: { type: 'category', data: props.labels, boundaryGap: false, axisLine: { lineStyle: { color: dark ? '#393939' : '#e4e4e4' } }, axisLabel: { color: dark ? '#8d8d8d' : '#767676', hideOverlap: true } },
    yAxis: { type: 'value', axisLabel: { color: dark ? '#8d8d8d' : '#767676', width: 76, overflow: 'truncate', formatter: formatValue }, splitLine: { lineStyle: { color: dark ? '#2b2b2b' : '#eeeeee' } } },
    series: props.series.map((item) => ({ name: item.name, data: item.data, type: 'line', showSymbol: false, sampling: 'lttb', smooth: 0.25, lineStyle: { width: 2, color: item.color }, itemStyle: { color: item.color }, areaStyle: { opacity: 0.04, color: item.color } })),
  }, true)
  renderedDark = dark
}

function scheduleRender() {
  if (!visible || renderFrame) return
  renderFrame = window.requestAnimationFrame(() => {
    renderFrame = 0
    void nextTick(renderNow)
  })
}

function resize() {
  if (!visible) return
  if (!root.value || root.value.clientWidth === 0 || root.value.clientHeight === 0) return
  const dark = document.documentElement.classList.contains('dark')
  if (!chart || dark !== renderedDark) scheduleRender()
  else chart.resize()
}

watch(() => [props.labels, props.series, props.unit], scheduleRender)
onMounted(() => {
  if (typeof IntersectionObserver !== 'undefined' && root.value) {
    visibilityObserver = new IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return
      visible = true
      visibilityObserver?.disconnect()
      visibilityObserver = null
      scheduleRender()
    }, { rootMargin: '240px 0px' })
    visibilityObserver.observe(root.value)
  } else {
    visible = true
    scheduleRender()
  }
  if (root.value && typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(resize)
    resizeObserver.observe(root.value)
  } else {
    window.addEventListener('resize', resize)
  }
  themeObserver = new MutationObserver(scheduleRender)
  themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ['class'] })
})
onBeforeUnmount(() => {
  window.removeEventListener('resize', resize)
  window.cancelAnimationFrame(renderFrame)
  resizeObserver?.disconnect()
  themeObserver?.disconnect()
  visibilityObserver?.disconnect()
  chart?.dispose()
})
</script>

<template><div ref="root" class="metric-chart" role="img" :aria-label="props.ariaLabel ?? '监控指标趋势图'" /></template>
