import { config } from '@/config'

/** Error with a Firebase-style `code` ('permission-denied', 'unauthenticated', ...) so call sites keep working. */
export class BackendError extends Error {
  code: string
  status: number
  constructor(code: string, message: string, status = 0) {
    super(message)
    this.name = 'BackendError'
    this.code = code
    this.status = status
  }
}

const STATUS_CODES: Record<number, string> = {
  400: 'invalid-argument', 401: 'unauthenticated', 403: 'permission-denied', 404: 'not-found',
  409: 'already-exists', 412: 'failed-precondition', 413: 'invalid-argument', 422: 'invalid-argument',
  429: 'resource-exhausted',
}

/** Absolute URL for an API path. Falls back to the page origin so URLs we store in documents are never relative. */
export function apiUrl(path: string): string {
  return `${config.apiBaseUrl || window.location.origin}${path}`
}

type UnauthHandler = () => void
let onUnauthenticated: UnauthHandler | null = null
export function setUnauthenticatedHandler(fn: UnauthHandler | null) {
  onUnauthenticated = fn
}

export async function apiFetch<T = any>(
  path: string,
  opts: { method?: string; json?: unknown; form?: FormData; signal?: AbortSignal } = {},
): Promise<T> {
  const init: RequestInit = {
    method: opts.method ?? (opts.json !== undefined || opts.form ? 'POST' : 'GET'),
    credentials: 'include',
    signal: opts.signal,
  }
  if (opts.form) init.body = opts.form
  else if (opts.json !== undefined) {
    init.body = JSON.stringify(opts.json)
    init.headers = { 'Content-Type': 'application/json' }
  }

  let res: Response
  try {
    res = await fetch(`${config.apiBaseUrl}${path}`, init)
  } catch (e: any) {
    if (e?.name === 'AbortError') throw e
    throw new BackendError('unavailable', 'Could not reach the server. Check your connection and try again.')
  }

  let body: any = null
  const text = await res.text()
  if (text) {
    try { body = JSON.parse(text) } catch { /* non-JSON error page */ }
  }
  if (!res.ok) {
    const message = String(body?.message ?? body?.detail ?? res.statusText ?? 'Request failed')
    const code = String(body?.code ?? STATUS_CODES[res.status] ?? (res.status >= 500 ? 'internal' : 'unknown'))
    if (res.status === 401 && !path.startsWith('/api/auth/')) onUnauthenticated?.()
    throw new BackendError(code, message, res.status)
  }
  return body as T
}
