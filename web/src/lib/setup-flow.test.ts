import { describe, expect, it } from 'vitest'
import { setupIsReady, setupRouteRedirect } from './setup-flow'
import type { SetupStatus } from '@/types'

function status(configured: boolean, state: SetupStatus['state']): SetupStatus {
  return { configured, state }
}

describe('setup flow', () => {
  it('keeps an unconfigured installation on setup', () => {
    const value = status(false, 'ready')
    expect(setupRouteRedirect(value, 'setup')).toBeNull()
    expect(setupRouteRedirect(value, 'login')).toBe('setup')
  })

  it('never exposes setup after configuration was submitted', () => {
    expect(setupRouteRedirect(status(true, 'applying'), 'setup')).toBe('login')
    expect(setupRouteRedirect(status(true, 'configured'), 'setup')).toBe('login')
    expect(setupRouteRedirect(status(true, 'error'), 'setup')).toBeNull()
    expect(setupRouteRedirect(status(true, 'error'), 'login')).toBe('setup')
  })

  it('keeps users on login while production services are starting', () => {
    const value = status(true, 'applying')
    expect(setupRouteRedirect(value, 'login')).toBeNull()
    expect(setupRouteRedirect(value, 'dashboard')).toBe('login')
    expect(setupIsReady(value)).toBe(false)
    expect(setupIsReady(status(true, 'configured'))).toBe(true)
  })

  it('keeps the public status page reachable while setup is unavailable', () => {
    expect(setupRouteRedirect(status(false, 'ready'), 'public-status', true)).toBeNull()
    expect(setupRouteRedirect(status(true, 'applying'), 'public-status', true)).toBeNull()
    expect(setupRouteRedirect(status(true, 'error'), 'public-status', true)).toBeNull()
  })
})
