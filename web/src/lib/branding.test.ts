import { describe, expect, it, beforeEach, vi } from 'vitest'

const { get } = vi.hoisted(() => ({ get: vi.fn() }))
vi.mock('./api', () => ({ api: { get } }))

import { loadBranding, siteIconUrl, siteName } from './branding'

describe('branding', () => {
  beforeEach(() => {
    get.mockReset()
    get.mockResolvedValue({ data: { siteName: '星辰云巡', siteIconUrl: '/favicon.svg' } })
    siteName.value = '星辰云巡'
    siteIconUrl.value = '/favicon.svg'
  })

  it('requests a fresh public brand value', async () => {
    await loadBranding(true)

    expect(get).toHaveBeenCalledWith('/settings/public', {
      params: expect.objectContaining({ _branding: expect.any(Number) }),
    })
    expect(siteIconUrl.value).toBe('/favicon.svg')
  })

  it('can refresh after a previous request has completed', async () => {
    get.mockResolvedValueOnce({ data: { siteName: '旧名称', siteIconUrl: '/old.svg' } })
    get.mockResolvedValueOnce({ data: { siteName: '新名称', siteIconUrl: 'https://example.com/icon.svg' } })

    await loadBranding(true)
    await loadBranding(true)

    expect(siteName.value).toBe('新名称')
    expect(siteIconUrl.value).toBe('https://example.com/icon.svg')
    expect(get).toHaveBeenCalledTimes(2)
  })
})
