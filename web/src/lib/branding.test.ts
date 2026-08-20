import { describe, expect, it, beforeEach, vi } from 'vitest'

const { get } = vi.hoisted(() => ({ get: vi.fn() }))
vi.mock('./api', () => ({ api: { get } }))

import { loadBranding, siteName } from './branding'

describe('branding', () => {
  beforeEach(() => {
    get.mockReset()
    get.mockResolvedValue({ data: { siteName: '星辰云巡' } })
    siteName.value = '星辰云巡'
  })

  it('requests a fresh public brand value', async () => {
    await loadBranding(true)

    expect(get).toHaveBeenCalledWith('/settings/public', {
      params: expect.objectContaining({ _branding: expect.any(Number) }),
    })
  })

  it('can refresh after a previous request has completed', async () => {
    get.mockResolvedValueOnce({ data: { siteName: '旧名称' } })
    get.mockResolvedValueOnce({ data: { siteName: '新名称' } })

    await loadBranding(true)
    await loadBranding(true)

    expect(siteName.value).toBe('新名称')
    expect(get).toHaveBeenCalledTimes(2)
  })
})
