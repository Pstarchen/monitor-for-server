export async function copyText(value: string): Promise<void> {
  if (!value) throw new Error('Nothing to copy')
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(value)
      return
    } catch {
      // Fall through for HTTP pages and browsers that deny the async API.
    }
  }

  const textarea = document.createElement('textarea')
  textarea.value = value
  textarea.setAttribute('readonly', '')
  textarea.setAttribute('aria-hidden', 'true')
  textarea.style.position = 'fixed'
  textarea.style.top = '0'
  textarea.style.left = '-9999px'
  textarea.style.opacity = '0'
  textarea.style.pointerEvents = 'none'
  document.body.appendChild(textarea)
  textarea.focus({ preventScroll: true })
  textarea.select()
  textarea.setSelectionRange(0, value.length)
  const copied = document.execCommand('copy')
  textarea.remove()
  if (!copied) throw new Error('Clipboard copy was rejected')
}
