<script setup lang="ts">
import { computed } from 'vue'
import { QrCode, ShieldCheck, TriangleAlert } from 'lucide-vue-next'

const props = defineProps<{
  baseUrl: string
  qrCode: string
  scopes: readonly string[]
  error?: string
}>()

const scopeCount = computed(() => props.scopes.length)
</script>

<template>
  <section class="mobile-binding-panel fade-in-up" aria-labelledby="mobile-binding-title">
    <header class="mobile-binding-head">
      <span class="mobile-binding-icon"><QrCode :size="20" /></span>
      <div class="mobile-binding-copy">
        <p>移动端同步</p>
        <h3 id="mobile-binding-title">扫码连接鸿蒙 App</h3>
      </div>
      <span class="mobile-binding-badge"><ShieldCheck :size="14" />一次性凭据</span>
    </header>

    <div class="mobile-binding-stage">
      <div class="mobile-binding-qr-column">
        <div class="mobile-binding-qr" :data-state="qrCode ? 'ready' : 'error'">
          <img v-if="qrCode" :src="qrCode" alt="星辰监控鸿蒙 App 绑定二维码" />
          <div v-else class="mobile-binding-fallback" role="alert">
            <TriangleAlert :size="24" />
            <strong>二维码暂不可用</strong>
            <p>{{ error || '请使用下方 Token 完成手动绑定。' }}</p>
          </div>
        </div>
        <span class="mobile-binding-qr-caption"><QrCode :size="14" />鸿蒙 App</span>
      </div>
      <div class="mobile-binding-details">
        <div class="mobile-binding-scope">
          <span><ShieldCheck :size="17" /></span>
          <div><small>当前授权范围</small><strong>{{ scopeCount }} 项权限</strong></div>
        </div>
        <dl class="mobile-binding-meta">
          <div><dt>服务入口</dt><dd class="mono-value">{{ baseUrl }}</dd></div>
          <div><dt>凭据状态</dt><dd>仅本次显示</dd></div>
        </dl>
      </div>
    </div>

    <footer class="mobile-binding-security"><ShieldCheck :size="16" /><span>二维码与下方 Token 拥有相同权限，请勿转发或截图保存。</span></footer>
  </section>
</template>
