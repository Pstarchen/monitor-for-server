import { ref } from 'vue'
import { api } from './api'
import type { PublicBrand } from '@/types'

export const siteName = ref('星辰云巡')
export const siteIconUrl = ref('/favicon.svg')
let pending: Promise<void> | undefined

function syncDocumentBranding(): void {
  if (typeof document !== 'undefined') {
    document.title = siteName.value
    const icon = document.querySelector<HTMLLinkElement>('link[data-guanlan-site-icon]') ?? document.createElement('link')
    const href = siteIconUrl.value || '/favicon.svg'
    icon.rel = 'icon'
    if (href.split(/[?#]/, 1)[0].toLowerCase().endsWith('.svg')) icon.type = 'image/svg+xml'
    else icon.removeAttribute('type')
    icon.href = href
    icon.dataset.guanlanSiteIcon = ''
    if (!icon.parentNode) document.head.appendChild(icon)
  }
}

syncDocumentBranding()

export function loadBranding(force = false): Promise<void> {
  if (pending && !force) return pending
  const previous = pending
  const request = (async () => {
    if (previous) await previous
    try {
      const { data } = await api.get<PublicBrand>('/settings/public', { params: { _branding: Date.now() } })
      const value = data.siteName?.trim()
      if (value) {
        siteName.value = value
      }
      siteIconUrl.value = data.siteIconUrl?.trim() || '/favicon.svg'
      syncDocumentBranding()
    } catch {
      // Keep the last known brand when the public endpoint is temporarily unavailable.
    }
  })()
  const tracked = request.finally(() => {
    if (pending === tracked) pending = undefined
  })
  pending = tracked
  return tracked
}
