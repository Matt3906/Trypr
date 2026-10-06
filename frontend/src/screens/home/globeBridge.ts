/** Helpers for the embedded 3D globe (/earth) iframe postMessage protocol. */
import { config } from '@/config'

export type StopPoint = { lat: number; lon: number; name: string; [k: string]: any }

export function earthAssetUrl(): string {
  const cb = Date.now()
  const key = config.googleMapsApiKey
  return key
    ? `/earth/index.html?embed=true&gmapsKey=${encodeURIComponent(key)}&cb=${cb}`
    : `/earth/index.html?embed=true&cb=${cb}`
}

export function messageType(data: unknown): string | null {
  if (!data) return null
  if (typeof data === 'object') {
    const t = (data as any).type
    return t != null ? String(t) : null
  }
  if (typeof data === 'string') {
    try {
      const decoded = JSON.parse(data)
      return decoded?.type != null ? String(decoded.type) : null
    } catch {
      return null
    }
  }
  return null
}

const toNum = (v: unknown): number => {
  if (typeof v === 'number') return v
  if (typeof v === 'string') return parseFloat(v)
  return NaN
}

export function normalizedWaypointsFromTrip(trip: Record<string, any> | null): StopPoint[] {
  const raw = trip?.waypoints
  if (!Array.isArray(raw)) return []
  const out: StopPoint[] = []
  for (const e of raw) {
    if (!e || typeof e !== 'object') continue
    const m: Record<string, any> = { ...e }
    const lat = toNum(m.lat ?? m.latitude)
    const lon = toNum(m.lon ?? m.lng ?? m.longitude)
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue
    m.lat = lat
    m.lon = lon
    m.name = String(m.name ?? m.title ?? '')
    out.push(m as StopPoint)
  }
  return out
}

export function overviewCameraForTrip(waypoints: StopPoint[]) {
  let minLat = waypoints[0].lat, maxLat = minLat, minLon = waypoints[0].lon, maxLon = minLon
  for (const p of waypoints) {
    minLat = Math.min(minLat, p.lat)
    maxLat = Math.max(maxLat, p.lat)
    minLon = Math.min(minLon, p.lon)
    maxLon = Math.max(maxLon, p.lon)
  }
  const spread = Math.max(Math.abs(maxLat - minLat), Math.abs(maxLon - minLon))
  const normalized = spread < 0.45 ? 0.45 : spread
  const range = Math.min(2200000, Math.max(80000, normalized * 111000 * 3))
  return { lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2, range }
}

export function bearingDegrees(fromLat: number, fromLon: number, toLat: number, toLon: number): number {
  const rad = Math.PI / 180
  const phi1 = fromLat * rad
  const phi2 = toLat * rad
  const dl = (toLon - fromLon) * rad
  const y = Math.sin(dl) * Math.cos(phi2)
  const x = Math.cos(phi1) * Math.sin(phi2) - Math.sin(phi1) * Math.cos(phi2) * Math.cos(dl)
  return ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360
}
