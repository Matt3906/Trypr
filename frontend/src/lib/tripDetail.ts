import { buildRouteCacheKey } from './routeCache'

export interface TransportOption { mode: string; label: string; emoji: string }

export const TRANSPORT_OPTIONS: TransportOption[] = [
  { mode: 'driving', label: 'Car', emoji: '🚗' },
  { mode: 'flying', label: 'Flight', emoji: '✈️' },
  { mode: 'transit', label: 'Train', emoji: '🚆' },
  { mode: 'walking', label: 'Walk', emoji: '🚶' },
  { mode: 'biking', label: 'Bike', emoji: '🚲' },
  { mode: 'portaging', label: 'Portaging', emoji: '🛶' },
  { mode: 'hiking', label: 'Hiking', emoji: '🥾' },
]

export type WP = Record<string, any>

export const isAdventureMode = (mode: string) => ['hiking', 'portaging', 'backpacking', 'bikepacking'].includes(mode.trim().toLowerCase())

export function normalizeDetailMode(raw: string): string {
  let m = raw.trim().toLowerCase()
  if (m === 'car' || m === 'driving') m = 'driving'
  if (['plane', 'flight', 'flying'].includes(m)) m = 'flying'
  if (['train', 'rail', 'public_transit', 'public transit'].includes(m)) m = 'transit'
  if (m === 'walk') m = 'walking'
  if (['bike', 'bicycling', 'cycling', 'bikepacking'].includes(m)) m = 'biking'
  if (m === 'hiking' || m === 'backpacking') m = 'hiking'
  if (['portage', 'portaging', 'canoe', 'canoeing'].includes(m)) m = 'portaging'
  if (['gas_stops', 'gas', 'gas/stops'].includes(m)) m = 'driving'
  return TRANSPORT_OPTIONS.some((o) => o.mode === m) ? m : 'driving'
}

export function coerceSegmentRoutingTypes(raw: unknown[], segmentCount?: number): string[] {
  const out = raw.map((e) => String(e).trim().toLowerCase()).map((v) => (v === 'direct' ? 'direct' : 'calculated'))
  if (segmentCount == null) return out
  if (out.length > segmentCount) return out.slice(0, segmentCount)
  while (out.length < segmentCount) out.push('calculated')
  return out
}

export function coerceSegmentTransportModes(raw: unknown[], segmentCount: number, fallbackMode: string): string[] {
  const fb = normalizeDetailMode(fallbackMode)
  const out = raw.map((e) => normalizeDetailMode(String(e)))
  if (out.length > segmentCount) return out.slice(0, segmentCount)
  while (out.length < segmentCount) out.push(fb)
  return out
}

export const waypointNightCount = (w: WP): number => {
  const raw = w.nights
  if (typeof raw === 'number') return Math.trunc(raw)
  const n = parseInt(String(raw ?? ''), 10)
  return Number.isFinite(n) ? n : 0
}
export const canEditWaypointRole = (i: number, list: WP[]) => i > 0 && i < list.length - 1
export function waypointIsStop(i: number, list: WP[]): boolean {
  if (i < 0 || i >= list.length) return false
  if (!canEditWaypointRole(i, list)) return false
  const raw = list[i].isStop
  if (typeof raw === 'boolean') return raw
  return waypointNightCount(list[i]) > 0
}
export function waypointRoleLabel(i: number, list: WP[]): string {
  if (i <= 0) return 'Start point'
  if (i >= list.length - 1) return 'End point'
  return waypointIsStop(i, list) ? 'Stay stop' : 'Waypoint'
}
export const isWaypointOnly = (i: number, list: WP[]) => canEditWaypointRole(i, list) && !waypointIsStop(i, list)

export function syncedWaypointsForSave(list: WP[]): WP[] {
  return list.map((w, idx) => {
    const wp = { ...w }
    const isStop = waypointIsStop(idx, list)
    wp.isStop = isStop
    wp.nights = isStop ? (waypointNightCount(wp) > 0 ? waypointNightCount(wp) : 1) : 0
    return wp
  })
}

export const requiresGearListForModes = (segmentModes: string[], fallback: string) =>
  segmentModes.some((m) => isAdventureMode(m)) || isAdventureMode(fallback)

export function currentRouteCacheKey(opts: { waypoints: WP[]; transportMode: string; segmentTransportModes: string[]; segmentRoutingTypes: string[]; routeVia: WP[] }) {
  return buildRouteCacheKey({
    waypoints: opts.waypoints, transportMode: opts.transportMode, segmentTransportModes: opts.segmentTransportModes,
    segmentRoutingTypes: opts.segmentRoutingTypes, routeVia: opts.routeVia,
  })
}

export const ownerUidFromTripRefPath = (path: string) => {
  const p = path.split('/')
  return p.length >= 2 && p[0] === 'users' ? p[1] : ''
}

export const toNum = (v: unknown): number => {
  if (typeof v === 'number') return v
  if (typeof v === 'string') return parseFloat(v)
  return NaN
}
export const isValidLatLon = (lat: number, lon: number) =>
  Number.isFinite(lat) && Number.isFinite(lon) && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180

export const mapList = (raw: unknown): Record<string, any>[] =>
  Array.isArray(raw) ? raw.map((e) => (e && typeof e === 'object' ? { ...e } : {})) : []

const normalizedLabel = (raw: string) => raw.trim().toLowerCase().replace(/[^a-z0-9]+/g, ' ').replace(/\s+/g, ' ').trim()
export const labelsMatch = (a: string, b: string) => {
  const na = normalizedLabel(a), nb = normalizedLabel(b)
  return !!na && na === nb
}

export function mapRoutePoints(waypoints: WP[]): WP[] {
  const out: WP[] = []
  waypoints.forEach((w, i) => {
    const lat = toNum(w.lat ?? w.latitude)
    const lon = toNum(w.lon ?? w.longitude ?? w.lng)
    if (!isValidLatLon(lat, lon)) return
    out.push({ lat, lon, name: String(w.name ?? ''), pointType: 'waypoint', waypointIndex: i })
  })
  return out
}

function legacyWaypointMarkers(waypoints: WP[]): WP[] {
  const out: WP[] = []
  waypoints.forEach((w, wIndex) => {
    const accs = Array.isArray(w.accommodations) ? w.accommodations : []
    accs.forEach((acc: any, ai: number) => {
      if (!acc || typeof acc !== 'object') return
      const lat = toNum(acc.lat ?? acc.locationLat)
      const lon = toNum(acc.lon ?? acc.locationLon ?? acc.lng)
      if (!isValidLatLon(lat, lon)) return
      out.push({ lat, lon, kind: 'accommodation', category: 'Accommodation', name: String(acc.name ?? 'Accommodation'), waypointIndex: wIndex, accommodationIndex: ai })
    })
    const itinerary = Array.isArray(w.itinerary) ? w.itinerary : []
    itinerary.forEach((day: any, di: number) => {
      if (!day || typeof day !== 'object') return
      const acts = Array.isArray(day.activities) ? day.activities : []
      acts.forEach((act: any, ai: number) => {
        if (!act || typeof act !== 'object') return
        const lat = toNum(act.locationLat), lon = toNum(act.locationLon)
        if (!isValidLatLon(lat, lon)) return
        out.push({ lat, lon, kind: 'activity', category: String(act.category ?? 'Exploring'), name: String(act.title ?? 'Activity'), waypointIndex: wIndex, dayIndex: di, activityIndex: ai, source: 'waypointItinerary' })
      })
    })
  })
  return out
}

function unifiedItineraryMarkers(candidates: unknown[]): WP[] {
  const out: WP[] = []
  for (const raw of candidates) {
    if (!Array.isArray(raw)) continue
    raw.forEach((day: any, di: number) => {
      if (!day || typeof day !== 'object') return
      const acts = Array.isArray(day.activities) ? day.activities : []
      acts.forEach((act: any, ai: number) => {
        if (!act || typeof act !== 'object') return
        const lat = toNum(act.locationLat), lon = toNum(act.locationLon)
        if (!isValidLatLon(lat, lon)) return
        out.push({ lat, lon, kind: 'activity', category: String(act.category ?? 'Exploring'), name: String(act.title ?? 'Activity'), dayIndex: di, activityIndex: ai, source: 'tripItinerary' })
      })
    })
  }
  return out
}

export function dedupeMarkers(input: WP[]): WP[] {
  const seen = new Set<string>()
  return input.filter((p) => {
    const key = `${toNum(p.lat).toFixed(5)}|${toNum(p.lon).toFixed(5)}|${p.kind ?? ''}|${p.category ?? ''}|${p.name ?? ''}`
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}

export function mapSecondaryPoints(waypoints: WP[], itineraryCandidates: unknown[]): WP[] {
  return dedupeMarkers([...legacyWaypointMarkers(waypoints), ...unifiedItineraryMarkers(itineraryCandidates)])
}

// ----- place insight helpers -----
export const mapPointKind = (p: WP): string => {
  const raw = String(p.kind ?? p.pointType ?? '').trim().toLowerCase()
  if (raw) return raw
  return p.waypointIndex != null ? 'waypoint' : 'location'
}
export function mapPointTitle(p: WP): string {
  const name = String(p.name ?? p.title ?? '').trim()
  if (name) return name
  const wi = typeof p.waypointIndex === 'number' ? p.waypointIndex : null
  return wi != null && wi >= 0 ? `Stop ${wi + 1}` : 'Selected place'
}
export function mapPointSubtitle(p: WP): string {
  const kind = mapPointKind(p)
  const category = String(p.category ?? '').trim()
  const dayIndex = typeof p.dayIndex === 'number' ? p.dayIndex : null
  if (kind === 'activity') return [dayIndex != null && dayIndex >= 0 ? `Day ${dayIndex + 1}` : '', category].filter(Boolean).join(' • ')
  if (kind === 'accommodation') return 'Accommodation'
  const wi = typeof p.waypointIndex === 'number' ? p.waypointIndex : null
  return wi != null && wi >= 0 ? `Stop ${wi + 1}` : 'Map selection'
}
export function vibeForCategory(category: string): string {
  switch (category.trim().toLowerCase()) {
    case 'hiking': case 'walking': case 'adventure': return 'outdoor exploration'
    case 'museum': case 'sightseeing': case 'photography': return 'landmark and culture stops'
    case 'restaurant': return 'local food experiences'
    case 'shopping': return 'city-style wandering'
    default: return 'balanced sightseeing'
  }
}
export function topActivityCategories(activities: WP[], max = 6): string[] {
  const counts = new Map<string, number>()
  for (const a of activities) {
    const raw = String(a.category ?? '').trim()
    if (raw) counts.set(raw, (counts.get(raw) ?? 0) + 1)
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, max).map(([k]) => k)
}
