import { describe, expect, it, beforeEach, vi } from 'vitest'

const { get } = vi.hoisted(() => ({ get: vi.fn() }))
vi.mock('./api', () => ({ api: { get } }))

import { brandAssetUrl, loadBranding, siteIconUrl, siteName } from './branding'

describe('branding', () => {
  beforeEach(() => {
    get.mockReset()
    get.mockResolvedValue({ data: { siteName: '星辰监控', siteIconUrl: '/brand-icon.png' } })
    siteName.value = '星辰监控'
    siteIconUrl.value = '/brand-icon.png'
  })

  it('requests a fresh public brand value', async () => {
    await loadBranding(true)

    expect(get).toHaveBeenCalledWith('/settings/public', {
      params: expect.objectContaining({ _branding: expect.any(Number) }),
    })
    expect(siteIconUrl.value).toBe('/brand-icon.png')
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

  it('cache-busts the uploaded icon when branding is refreshed', async () => {
    get.mockResolvedValue({ data: { siteName: '星辰监控', siteIconUrl: '/api/settings/site-icon' } })

    await loadBranding(true)
    const first = siteIconUrl.value
    await loadBranding(true)

    expect(first).toMatch(/^\/api\/settings\/site-icon\?v=\d+$/)
    expect(siteIconUrl.value).toMatch(/^\/api\/settings\/site-icon\?v=\d+$/)
    expect(siteIconUrl.value).not.toBe(first)
  })

  it('does not alter default or external icon URLs', () => {
    expect(brandAssetUrl('/brand-icon.png', 123)).toBe('/brand-icon.png')
    expect(brandAssetUrl('https://example.com/icon.png', 123)).toBe('https://example.com/icon.png')
  })
})
