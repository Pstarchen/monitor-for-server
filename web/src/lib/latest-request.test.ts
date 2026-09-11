import { describe, expect, it } from 'vitest'
import { createLatestRequest } from './latest-request'

describe('device refresh ordering', () => {
  it('does not apply an older slow response after the newer refresh completed', async () => {
    const requests = createLatestRequest()
    let display = ''
    let releaseOld!: (value: string) => void
    const pending = new Promise<string>((resolve) => { releaseOld = resolve })
    const old = requests.start()
    const first = pending.then((value) => { if (old.isCurrent()) display = value })
    const current = requests.start()
    if (current.isCurrent()) display = 'new measurement'
    releaseOld('old measurement')
    await first
    expect(display).toBe('new measurement')
    expect(old.signal.aborted).toBe(true)
    expect(current.signal.aborted).toBe(false)
  })

  it('invalidates a pending response when leaving the device', () => {
    const requests = createLatestRequest()
    const request = requests.start()
    requests.cancel()
    expect(request.isCurrent()).toBe(false)
    expect(request.signal.aborted).toBe(true)
  })
})
