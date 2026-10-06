import { config } from '@/config'

interface EndpointConfig {
  endpoint: string
  isProxy: boolean
}

const unavailable = new Set<string>()
const cooldownUntil = new Map<string, number>()

function shouldUseRelativeProxy(endpoint: string): boolean {
  const trimmed = endpoint.trim()
  if (!trimmed.startsWith('/')) return true
  // The Vite dev server proxies /api to the FastAPI backend (see vite.config.ts), so the relative proxy is usable.
  return true
}

export function overpassEndpointConfigs(): EndpointConfig[] {
  const proxy = config.overpassProxyUrl || '/api/overpass'
  return [
    ...(proxy.trim() && shouldUseRelativeProxy(proxy) ? [{ endpoint: proxy, isProxy: true }] : []),
    { endpoint: 'https://overpass-api.de/api/interpreter', isProxy: false },
    { endpoint: 'https://lz4.overpass-api.de/api/interpreter', isProxy: false },
    { endpoint: 'https://overpass.private.coffee/api/interpreter', isProxy: false },
    { endpoint: 'https://overpass.kumi.systems/api/interpreter', isProxy: false },
  ]
}

const blocked = (endpoint: string) => {
  const until = cooldownUntil.get(endpoint)
  if (until == null) return false
  if (Date.now() > until) {
    cooldownUntil.delete(endpoint)
    return false
  }
  return true
}

export function hasAvailableOverpassEndpoint(ignoreCooldown = false): boolean {
  for (const c of overpassEndpointConfigs()) {
    const e = c.endpoint.trim()
    if (!e || unavailable.has(e)) continue
    if (!ignoreCooldown && blocked(e)) continue
    return true
  }
  return false
}

const markUnavailable = (e: string) => {
  unavailable.add(e)
  cooldownUntil.delete(e)
}
const coolDown = (e: string, ms: number) => {
  if (unavailable.has(e) || ms <= 0) return
  const next = Date.now() + ms
  const existing = cooldownUntil.get(e)
  if (existing == null || existing < next) cooldownUntil.set(e, next)
}

function cooldownForStatus(endpoint: string, status: number, isProxy: boolean): number {
  if (isProxy && (status === 404 || status === 405)) {
    markUnavailable(endpoint)
    return 0
  }
  if (endpoint.toLowerCase().includes('maps.mail.ru') && status === 403) {
    markUnavailable(endpoint)
    return 0
  }
  if (status === 429) return 3 * 60_000
  if (status === 408 || status === 504) return 2 * 60_000
  if (status >= 500) return 60_000
  if (status === 403) return 30 * 60_000
  return 45_000
}

function cooldownForError(endpoint: string, err: unknown, isProxy: boolean): number {
  const text = String(err)
  if (text.includes('AbortError') || text.includes('Timeout')) return 2 * 60_000
  if (text.includes('Failed to fetch') || text.includes('NetworkError')) {
    if (isProxy) {
      markUnavailable(endpoint)
      return 0
    }
    return 10 * 60_000
  }
  return 60_000
}

export async function fetchOverpassData(opts: { query: string; logPrefix: string; requestTimeoutMs?: number; ignoreCooldown?: boolean }): Promise<any | null> {
  const requestTimeout = opts.requestTimeoutMs ?? 9000
  const deadline = Date.now() + Math.max(requestTimeout + 4000, 14000)
  let attemptedAny = false

  for (const c of overpassEndpointConfigs()) {
    const endpoint = c.endpoint.trim()
    if (!endpoint) continue
    if (unavailable.has(endpoint)) continue
    if (!opts.ignoreCooldown && blocked(endpoint)) continue
    const remaining = deadline - Date.now()
    if (remaining <= 250) break

    attemptedAny = true
    const timeout = Math.min(remaining, requestTimeout)
    const started = Date.now()
    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), timeout)
    try {
      const resp = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': c.isProxy ? 'application/json' : 'application/x-www-form-urlencoded' },
        body: c.isProxy ? JSON.stringify({ query: opts.query }) : `data=${encodeURIComponent(opts.query)}`,
        signal: ctrl.signal,
      })
      if (!resp.ok) {
        coolDown(endpoint, cooldownForStatus(endpoint, resp.status, c.isProxy))
        console.debug(`${opts.logPrefix} endpoint_failed endpoint=${endpoint} status=${resp.status} elapsed_ms=${Date.now() - started}`)
        continue
      }
      const decoded = await resp.json()
      if (decoded && typeof decoded === 'object') {
        console.debug(`${opts.logPrefix} endpoint_ok endpoint=${endpoint} elapsed_ms=${Date.now() - started}`)
        return decoded
      }
    } catch (e) {
      coolDown(endpoint, cooldownForError(endpoint, e, c.isProxy))
      console.debug(`${opts.logPrefix} endpoint_error endpoint=${endpoint} err=${e}`)
    } finally {
      clearTimeout(timer)
    }
  }
  console.debug(attemptedAny ? `${opts.logPrefix} all_endpoints_failed` : `${opts.logPrefix} all_endpoints_unavailable`)
  return null
}
