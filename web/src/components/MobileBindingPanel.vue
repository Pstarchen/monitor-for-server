<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { Download, ExternalLink, QrCode, RefreshCw, ShieldCheck, TriangleAlert } from 'lucide-vue-next'
import { api, errorMessage } from '@/lib/api'
import {
  createMobileBindingQrCodeV2,
  mobileBindingMetadataFromBootstrap,
  resolveMobileBindingBaseUrl,
  XINGCHENYUNXUN_APP_GALLERY_URL,
} from '@/lib/mobile-binding'
import type { ClientBootstrap } from '@/lib/mobile-binding'

const props = defineProps<{
  baseUrl: string
  token: string
  scopes: readonly string[]
  tokenExpiresAt?: string | null
}>()

const scopeCount = computed(() => props.scopes.length)
const qrCode = ref('')
const error = ref('')
const loading = ref(true)
const controllerName = ref('')
const apiVersion = ref<number | null>(null)
const bindingBaseUrl = ref(props.baseUrl)
let requestGeneration = 0

async function loadBindingQrCode() {
  const generation = ++requestGeneration
  loading.value = true
  qrCode.value = ''
  error.value = ''
  controllerName.value = ''
  apiVersion.value = null
  bindingBaseUrl.value = props.baseUrl
  try {
    const bootstrap = (await api.get<ClientBootstrap>('/client/bootstrap')).data
    const metadata = mobileBindingMetadataFromBootstrap(bootstrap)
    const baseUrl = resolveMobileBindingBaseUrl(bootstrap.controller.canonicalEntry, props.baseUrl)
    const generatedQrCode = await createMobileBindingQrCodeV2(
      baseUrl,
      props.token,
      props.scopes,
      metadata,
      props.tokenExpiresAt,
    )
    if (generation !== requestGeneration) return
    qrCode.value = generatedQrCode
    controllerName.value = metadata.controllerName
    apiVersion.value = metadata.apiVersion
    bindingBaseUrl.value = baseUrl
  } catch (cause) {
    if (generation !== requestGeneration) return
    error.value = `无法读取控制器绑定信息：${errorMessage(cause)}`
  } finally {
    if (generation === requestGeneration) loading.value = false
  }
}

watch(
  () => [props.baseUrl, props.token, props.tokenExpiresAt ?? '', ...props.scopes],
  loadBindingQrCode,
  { immediate: true },
)

onBeforeUnmount(() => {
  requestGeneration += 1
})
</script>

<template>
  <section class="mobile-binding-panel fade-in-up" aria-labelledby="mobile-binding-title">
    <header class="mobile-binding-head">
      <span class="mobile-binding-icon"><QrCode :size="20" /></span>
      <div class="mobile-binding-copy">
        <p>移动端同步</p>
        <h3 id="mobile-binding-title">扫码连接鸿蒙 App</h3>
      </div>
      <span class="mobile-binding-badge"><ShieldCheck :size="14" />可撤销 PAT</span>
    </header>

    <div class="mobile-binding-stage">
      <div class="mobile-binding-qr-column">
        <div class="mobile-binding-qr" :data-state="loading ? 'loading' : qrCode ? 'ready' : 'error'">
          <img v-if="qrCode" :src="qrCode" alt="星辰监控鸿蒙 App 绑定二维码" />
          <div v-else-if="loading" class="mobile-binding-loading" role="status">
            <span class="spinner" />
            <strong>正在读取控制器信息</strong>
            <p>取得可信元数据后生成二维码。</p>
          </div>
          <div v-else class="mobile-binding-fallback" role="alert">
            <TriangleAlert :size="24" />
            <strong>二维码暂不可用</strong>
            <p>{{ error || '请使用下方 Token 完成手动绑定。' }}</p>
          </div>
        </div>
        <button v-if="error" class="mobile-binding-retry" type="button" @click="loadBindingQrCode"><RefreshCw :size="14" />重新读取控制器信息</button>
        <span v-else class="mobile-binding-qr-caption"><QrCode :size="14" />鸿蒙 App</span>
      </div>
      <div class="mobile-binding-details">
        <div class="mobile-binding-app-download">
          <span><Download :size="17" /></span>
          <div>
            <small>还没有鸿蒙客户端？</small>
            <strong>先安装星辰云巡，再扫描二维码</strong>
          </div>
          <a
            :href="XINGCHENYUNXUN_APP_GALLERY_URL"
            target="_blank"
            rel="noopener noreferrer"
            aria-label="在华为应用市场下载星辰云巡（新窗口打开）"
          >华为应用市场<ExternalLink :size="14" /></a>
        </div>
        <div class="mobile-binding-scope">
          <span><ShieldCheck :size="17" /></span>
          <div><small>当前授权范围</small><strong>{{ scopeCount }} 项权限</strong></div>
        </div>
        <dl class="mobile-binding-meta">
          <div v-if="controllerName"><dt>控制器</dt><dd>{{ controllerName }} · API v{{ apiVersion }}</dd></div>
          <div><dt>服务入口</dt><dd class="mono-value">{{ bindingBaseUrl }}</dd></div>
          <div><dt>凭据状态</dt><dd>可重复使用，直至到期或吊销</dd></div>
        </dl>
      </div>
    </div>

    <footer class="mobile-binding-security"><ShieldCheck :size="16" /><span>PAT 明文只在创建时显示一次，但凭据并非一次性使用。二维码与下方 Token 拥有相同权限，请勿转发或截图保存，完成绑定后可在此吊销。</span></footer>
  </section>
</template>
