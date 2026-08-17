<script setup lang="ts">
import { Activity, ArrowLeft, MapPinOff } from 'lucide-vue-next'
</script>

<template>
  <main class="not-found-page">
    <RouterLink class="brand not-found-brand" to="/dashboard"><span class="brand-mark"><Activity :size="19" /></span><span><strong>观澜监控</strong><small>PRIVATE OPS</small></span></RouterLink>
    <section class="not-found-content fade-in-up"><span><MapPinOff :size="25" /></span><p class="eyebrow">404 / ROUTE NOT FOUND</p><h1>页面不存在</h1><p>请求的控制台路径无效，或相关模块已被移动。</p><RouterLink class="primary-command" to="/dashboard"><ArrowLeft :size="16" />返回运行总览</RouterLink></section>
  </main>
</template>
