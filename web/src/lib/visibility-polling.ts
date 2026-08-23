import { onBeforeUnmount, onMounted } from 'vue'

export function useVisibilityPolling(callback: () => void | Promise<unknown>, intervalMs = 30_000): void {
  let timer = 0

  const run = () => {
    if (document.visibilityState !== 'visible') return
    void Promise.resolve(callback()).catch(() => {
      // The page owns request error state; polling must not create an unhandled rejection.
    })
  }

  const onVisibilityChange = () => {
    if (document.visibilityState === 'visible') run()
  }

  onMounted(() => {
    timer = window.setInterval(run, intervalMs)
    document.addEventListener('visibilitychange', onVisibilityChange)
  })

  onBeforeUnmount(() => {
    window.clearInterval(timer)
    document.removeEventListener('visibilitychange', onVisibilityChange)
  })
}
