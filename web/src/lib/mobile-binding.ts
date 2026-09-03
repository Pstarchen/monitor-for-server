import QRCode from 'qrcode'

export const XINGCHENYUNXUN_APP_GALLERY_URL = 'https://appgallery.huawei.com/app/detail?id=cn.xciy.xcyx&channelId=SHARE&source=appshare'

const CONTROLLER_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{5,127}$/
const CAPABILITY_PATTERN = /^[a-z][a-z0-9-]*-v[0-9]+$/

export interface MobileBindingPayload {
  type: 'xingchenyunxun-bind'
  baseUrl: string
  token: string
  scopes: string[]
}

export interface ClientBootstrapController {
  id: string
  name: string
  canonicalEntry: string
  timezone: string
}

export interface ClientBootstrapServer {
  version: string
  buildTime: string | null
  apiVersion: number
  minimumClientApiVersion: number
  serverTime: string
}

export interface ClientBootstrapPrincipal {
  authenticationType: string
  username: string
  role: string
  tokenId?: number | null
  tokenPrefix?: string | null
  scopes?: string[]
  serverIds?: string[]
  expiresAt?: string | null
}

export interface ClientBootstrap {
  controller: ClientBootstrapController
  server: ClientBootstrapServer
  capabilities: string[]
  principal: ClientBootstrapPrincipal
}

export interface MobileBindingBootstrapMetadata {
  controllerId: string
  controllerName: string
  apiVersion: number
  capabilities: string[]
}

export interface MobileBindingPayloadV2 extends MobileBindingPayload, MobileBindingBootstrapMetadata {
  schemaVersion: 2
  tokenExpiresAt: string
}

export function resolveMobileBindingBaseUrl(configuredBaseUrl: string | null | undefined, origin: string): string {
  const configured = configuredBaseUrl?.trim()
  return configured || origin
}

export function createMobileBindingPayload(baseUrl: string, token: string, scopes: readonly string[]): string {
  const payload: MobileBindingPayload = {
    type: 'xingchenyunxun-bind',
    baseUrl,
    token,
    scopes: [...scopes],
  }
  return JSON.stringify(payload)
}

export function mobileBindingMetadataFromBootstrap(bootstrap: ClientBootstrap): MobileBindingBootstrapMetadata {
  const controllerId = bootstrap.controller.id.trim()
  const controllerName = bootstrap.controller.name.trim()
  const capabilities = bootstrap.capabilities.map((capability) => capability.trim())
  if (
    !CONTROLLER_ID_PATTERN.test(controllerId)
    || !controllerName
    || controllerName.length > 128
    || !Number.isInteger(bootstrap.server.apiVersion)
    || bootstrap.server.apiVersion < 1
    || capabilities.some((capability) => !CAPABILITY_PATTERN.test(capability))
  ) {
    throw new Error('控制器返回了无效的绑定元数据')
  }
  return {
    controllerId,
    controllerName,
    apiVersion: bootstrap.server.apiVersion,
    capabilities,
  }
}

export function createMobileBindingPayloadV2(
  baseUrl: string,
  token: string,
  scopes: readonly string[],
  metadata: MobileBindingBootstrapMetadata,
  tokenExpiresAt?: string | null,
): string {
  const payload: MobileBindingPayloadV2 = {
    type: 'xingchenyunxun-bind',
    schemaVersion: 2,
    baseUrl,
    token,
    scopes: [...scopes],
    controllerId: metadata.controllerId,
    controllerName: metadata.controllerName,
    apiVersion: metadata.apiVersion,
    capabilities: [...metadata.capabilities],
    tokenExpiresAt: tokenExpiresAt ?? '',
  }
  return JSON.stringify(payload)
}

export function createMobileBindingQrCode(baseUrl: string, token: string, scopes: readonly string[]): Promise<string> {
  return QRCode.toDataURL(createMobileBindingPayload(baseUrl, token, scopes), {
    width: 320,
    margin: 2,
    color: { dark: '#181818', light: '#FFFFFF' },
  })
}

export function createMobileBindingQrCodeV2(
  baseUrl: string,
  token: string,
  scopes: readonly string[],
  metadata: MobileBindingBootstrapMetadata,
  tokenExpiresAt?: string | null,
): Promise<string> {
  return QRCode.toDataURL(createMobileBindingPayloadV2(baseUrl, token, scopes, metadata, tokenExpiresAt), {
    width: 320,
    margin: 2,
    color: { dark: '#181818', light: '#FFFFFF' },
  })
}
