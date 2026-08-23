import QRCode from 'qrcode'

export interface MobileBindingPayload {
  type: 'xingchenyunxun-bind'
  baseUrl: string
  token: string
  scopes: string[]
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

export function createMobileBindingQrCode(baseUrl: string, token: string, scopes: readonly string[]): Promise<string> {
  return QRCode.toDataURL(createMobileBindingPayload(baseUrl, token, scopes), {
    width: 320,
    margin: 2,
    color: { dark: '#181818', light: '#FFFFFF' },
  })
}
