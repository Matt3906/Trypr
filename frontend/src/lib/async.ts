export async function withTimeout<T>(opts: {
  operation: () => Promise<T>
  timeoutMs: number
  fallback: () => T
  operationName?: string
}): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      opts.operation(),
      new Promise<T>((resolve) => {
        timer = setTimeout(() => {
          console.debug(`${opts.operationName ?? 'operation'} timed out after ${opts.timeoutMs}ms`)
          resolve(opts.fallback())
        }, opts.timeoutMs)
      }),
    ])
  } catch {
    return opts.fallback()
  } finally {
    if (timer) clearTimeout(timer)
  }
}

export const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))

export function debounce<A extends unknown[]>(fn: (...a: A) => void, ms: number) {
  let t: ReturnType<typeof setTimeout> | undefined
  const d = (...a: A) => {
    if (t) clearTimeout(t)
    t = setTimeout(() => fn(...a), ms)
  }
  d.cancel = () => { if (t) clearTimeout(t) }
  return d
}
