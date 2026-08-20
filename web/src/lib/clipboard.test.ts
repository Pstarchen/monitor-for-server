import { describe, expect, it, vi } from 'vitest'
import { copyText } from './clipboard'

describe('copyText', () => {
  it('uses the document fallback when the async clipboard API is unavailable', async () => {
    const textarea = {
      value: '',
      style: {} as CSSStyleDeclaration,
      setAttribute: vi.fn(),
      focus: vi.fn(),
      select: vi.fn(),
      setSelectionRange: vi.fn(),
      remove: vi.fn(),
    }
    const documentStub = {
      createElement: vi.fn(() => textarea),
      body: { appendChild: vi.fn() },
      execCommand: vi.fn(() => true),
    }
    vi.stubGlobal('navigator', { clipboard: undefined })
    vi.stubGlobal('document', documentStub)

    await copyText('install command')

    expect(documentStub.execCommand).toHaveBeenCalledWith('copy')
    expect(textarea.value).toBe('install command')
    expect(textarea.remove).toHaveBeenCalled()
  })
})
