import { describe, expect, it } from 'vitest'
import {
  XINGCHENYUNXUN_APP_GALLERY_URL,
  createMobileBindingPayload,
  createMobileBindingPayloadV2,
  mobileBindingMetadataFromBootstrap,
  resolveMobileBindingBaseUrl,
} from './mobile-binding'
import type { ClientBootstrap } from './mobile-binding'

const bootstrap: ClientBootstrap = {
  controller: {
    id: '7c9ae80b-5a56-49ef-8448-695888502191',
    name: '华东监控中心',
    canonicalEntry: 'https://monitor.example.com',
    timezone: 'Asia/Shanghai',
  },
  server: {
    version: '2.0.0',
    buildTime: null,
    apiVersion: 2,
    minimumClientApiVersion: 1,
    serverTime: '2026-09-01T08:00:00Z',
  },
  capabilities: ['client-bootstrap-v1', 'mobile-diagnostics-v1', 'alert-cursor-v2', 'realtime-v2'],
  principal: {
    authenticationType: 'SESSION',
    username: 'admin',
    role: 'ADMIN',
  },
}

describe('mobile binding payload', () => {
  it('uses the official AppGallery listing for the HarmonyOS client', () => {
    expect(XINGCHENYUNXUN_APP_GALLERY_URL).toBe(
      'https://appgallery.huawei.com/app/detail?id=cn.xciy.xcyx&channelId=SHARE&source=appshare',
    )
  })

  it('keeps the v1 helper compatible for older clients', () => {
    const payload = JSON.parse(createMobileBindingPayload(
      'https://monitor.example.com',
      'nzp_test-secret',
      ['nezha:inventory:read', 'nezha:server:read'],
    ))

    expect(payload).toEqual({
      type: 'xingchenyunxun-bind',
      baseUrl: 'https://monitor.example.com',
      token: 'nzp_test-secret',
      scopes: ['nezha:inventory:read', 'nezha:server:read'],
    })
  })

  it('prefers the saved public entry point and falls back to the current origin', () => {
    expect(resolveMobileBindingBaseUrl(' https://monitor.example.com/ ', 'http://internal.local')).toBe('https://monitor.example.com/')
    expect(resolveMobileBindingBaseUrl('', 'http://internal.local')).toBe('http://internal.local')
  })

  it('does not claim that manually selected scopes are read-only', () => {
    const payload = JSON.parse(createMobileBindingPayload(
      'https://monitor.example.com',
      'nzp_test-secret',
      ['nezha:server:read', 'nezha:server:write'],
    ))

    expect(payload.scopes).toEqual(['nezha:server:read', 'nezha:server:write'])
  })

  it('creates a schema v2 payload from authoritative bootstrap metadata', () => {
    const metadata = mobileBindingMetadataFromBootstrap(bootstrap)
    const payload = JSON.parse(createMobileBindingPayloadV2(
      bootstrap.controller.canonicalEntry,
      'nzp_test-secret',
      ['nezha:inventory:read', 'nezha:server:read'],
      metadata,
      '2026-12-01T08:00:00Z',
    ))

    expect(payload).toEqual({
      type: 'xingchenyunxun-bind',
      schemaVersion: 2,
      baseUrl: 'https://monitor.example.com',
      token: 'nzp_test-secret',
      scopes: ['nezha:inventory:read', 'nezha:server:read'],
      controllerId: '7c9ae80b-5a56-49ef-8448-695888502191',
      controllerName: '华东监控中心',
      apiVersion: 2,
      capabilities: ['client-bootstrap-v1', 'mobile-diagnostics-v1', 'alert-cursor-v2', 'realtime-v2'],
      tokenExpiresAt: '2026-12-01T08:00:00Z',
    })
  })

  it('uses an empty expiry for a PAT without an expiration date', () => {
    const payload = JSON.parse(createMobileBindingPayloadV2(
      'https://monitor.example.com',
      'nzp_test-secret',
      ['nezha:inventory:read'],
      mobileBindingMetadataFromBootstrap(bootstrap),
      null,
    ))

    expect(payload.tokenExpiresAt).toBe('')
  })

  it('rejects incomplete bootstrap identity instead of inventing metadata', () => {
    expect(() => mobileBindingMetadataFromBootstrap({
      ...bootstrap,
      controller: { ...bootstrap.controller, id: '' },
    })).toThrow('控制器返回了无效的绑定元数据')
  })

  it('rejects malformed bootstrap capabilities', () => {
    expect(() => mobileBindingMetadataFromBootstrap({
      ...bootstrap,
      capabilities: ['realtime'],
    })).toThrow('控制器返回了无效的绑定元数据')
  })
})
