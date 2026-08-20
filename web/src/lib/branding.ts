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

export function loadBranding(): Promise<void> {
  if (pending) return pending
  pending = api.get<PublicBrand>('/settings/public')
    .then(({ data }) => {
      const value = data.siteName?.trim()
      if (value) {
        siteName.value = value
        syncDocumentTitle()
      }
    })
    .catch(() => undefined)
    .finally(() => { pending = undefined })
  return pending
}
