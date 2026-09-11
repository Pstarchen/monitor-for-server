/** Ignore both late successes and late failures after another refresh begins. */
export function createLatestRequest() {
  let controller: AbortController | null = null
  let generation = 0
  return {
    start() {
      controller?.abort()
      controller = new AbortController()
      const current = ++generation
      return { signal: controller.signal, isCurrent: () => generation === current }
    },
    cancel() {
      generation += 1
      controller?.abort()
    },
  }
}
