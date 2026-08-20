import { ref } from 'vue'
import { api } from './api'
import type { PublicBrand } from '@/types'

export const siteName = ref('星辰云巡')
let pending: Promise<void> | undefined

function syncDocumentTitle(): void {
  if (typeof document !== 'undefined') {
    document.title = siteName.value
  }
}

syncDocumentTitle()

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
        syncDocumentTitle()
      }
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
