import { beforeEach, describe, expect, it, vi } from 'vitest'
import { api, getSetupStatus, invalidateSetupStatusCache } from './api'
import type { SetupStatus } from '@/types'

describe('setup status cache', () => {
  beforeEach(() => {
    invalidateSetupStatusCache()
    vi.restoreAllMocks()
  })

  it('keeps the configured result for route changes in the same app session', async () => {
    const status: SetupStatus = { configured: true, state: 'configured', message: 'ready' }
    const request = vi.spyOn(api, 'get').mockResolvedValue({ data: status })

    await expect(getSetupStatus()).resolves.toEqual(status)
    await expect(getSetupStatus()).resolves.toEqual(status)

    expect(request).toHaveBeenCalledTimes(1)
  })

  it('allows readiness polling to force a fresh result', async () => {
    const starting: SetupStatus = { configured: false, state: 'applying', message: 'starting' }
    const ready: SetupStatus = { configured: true, state: 'configured', message: 'ready' }
    const request = vi.spyOn(api, 'get')
      .mockResolvedValueOnce({ data: starting })
      .mockResolvedValueOnce({ data: ready })

    await expect(getSetupStatus()).resolves.toEqual(starting)
    await expect(getSetupStatus(true)).resolves.toEqual(ready)

    expect(request).toHaveBeenCalledTimes(2)
  })
})
