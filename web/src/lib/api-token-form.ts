import { defaultApiTokenScopes } from './api-token-scopes'

export interface ApiTokenFormState {
  name: string
  scopes: string[]
  serverIds: string
  expiresInDays: number
}

export function createDefaultApiTokenForm(): ApiTokenFormState {
  return { name: '', scopes: [...defaultApiTokenScopes], serverIds: '', expiresInDays: 90 }
}

export function parseServerIds(input: string): string[] {
  return [...new Set(input.split(/[\s,，]+/).map((value) => value.trim()).filter(Boolean))]
}
