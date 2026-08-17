<script setup lang="ts">
defineProps<{ label: string; value: string | number; hint?: string; tone?: 'neutral' | 'success' | 'warning' | 'danger' | 'info' }>()
</script>

<template>
  <article class="metric-card hover-lift" :data-tone="tone ?? 'neutral'">
    <div class="metric-card-head"><span class="metric-icon"><slot name="icon" /></span><span class="metric-label">{{ label }}</span></div>
    <strong class="metric-value">{{ value }}</strong>
    <p v-if="hint" class="metric-hint">{{ hint }}</p>
  </article>
</template>

