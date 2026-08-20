import { ref } from 'vue'
import { api } from './api'
import type { PublicBrand } from '@/types'

export const siteName = ref('观澜监控')
let pending: Promise<void> | undefined

export function loadBranding(): Promise<void> {
  if (pending) return pending
  pending = api.get<PublicBrand>('/settings/public')
    .then(({ data }) => {
      const value = data.siteName?.trim()
      if (value) siteName.value = value
    })
    .catch(() => undefined)
    .finally(() => { pending = undefined })
  return pending
}
