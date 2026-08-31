<script setup lang="ts">
import { ref, watch } from 'vue'
import { Activity } from 'lucide-vue-next'
import { siteIconUrl } from '@/lib/branding'

const failed = ref(false)

watch(siteIconUrl, () => {
  failed.value = false
})
</script>

<template>
  <span class="brand-mark" aria-hidden="true">
    <img v-if="siteIconUrl && !failed" :src="siteIconUrl" alt="" @error="failed = true" />
    <Activity v-else :size="19" />
  </span>
</template>
