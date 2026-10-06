export type AnyMap = Record<string, any>

const toNum = (v: unknown): number => {
  if (typeof v === 'number') return v
  if (typeof v === 'string') {
    const n = parseFloat(v)
    return Number.isFinite(n) ? n : 0
  }
  return 0
}

const toFixedNum = (n: number, digits = 6) => parseFloat(n.toFixed(digits))
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v))

export type RouteMode = 'driving' | 'flying' | 'train' | 'walking' | 'biking' | 'hiking' | 'portaging'

export function normalizeRouteMode(raw: string): RouteMode {
  let mode = raw.trim().toLowerCase()
  if (mode === 'car' || mode === 'driving') mode = 'driving'
  if (mode === 'plane' || mode === 'flight' || mode === 'flying') mode = 'flying'
  if (['train', 'rail', 'public_transit', 'public transit', 'transit'].includes(mode)) mode = 'train'
  if (mode === 'walk') mode = 'walking'
  if (['bike', 'biking', 'bicycling', 'cycling', 'bikepacking'].includes(mode)) mode = 'biking'
  if (mode === 'hiking' || mode === 'backpacking') mode = 'hiking'
  if (['portage', 'portaging', 'canoe', 'canoeing'].includes(mode)) mode = 'portaging'
  if (['gas', 'gas_stops', 'gas/stops', 'gas-stops', 'gasstops'].includes(mode)) mode = 'driving'
  switch (mode) {
    case 'driving':
    case 'flying':
    case 'train':
    case 'walking':
    case 'biking':
    case 'hiking':
    case 'portaging':
      return mode
    default:
      return 'driving'
  }
}

export function normalizeSegmentModes(raw: unknown[], segmentCount: number, fallbackMode: string): RouteMode[] {
  const fallback = normalizeRouteMode(fallbackMode)
  const out = raw.map((e) => normalizeRouteMode(String(e)))
  if (out.length > segmentCount) return out.slice(0, segmentCount)
  while (out.length < segmentCount) out.push(fallback)
  return out
}

export function normalizeSegmentRoutingType(raw: string, mode: string): string {
  const normalizedMode = normalizeRouteMode(mode)
  if (raw.trim().toLowerCase() === 'direct') return 'direct'
  switch (normalizedMode) {
    case 'hiking':
      return 'trails'
    case 'portaging':
      return 'waterway'
    default:
      return 'calculated'
  }
}

export function normalizeSegmentRoutingTypes(
  raw: unknown[],
  opts: { segmentCount: number; segmentModes?: unknown[]; fallbackMode: string },
): string[] {
  const modes = normalizeSegmentModes(opts.segmentModes ?? [], opts.segmentCount, opts.fallbackMode)
  return Array.from({ length: opts.segmentCount }, (_, i) =>
    normalizeSegmentRoutingType(i < raw.length ? String(raw[i]) : '', modes[i]),
  )
}

export function normalizeRouteVia(raw: unknown[], segmentCount: number): AnyMap[] {
  const out: AnyMap[] = []
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue
    const it = item as AnyMap
    const after = typeof it.afterIndex === 'number' ? Math.trunc(it.afterIndex) : null
    if (after == null || after < 0 || after >= segmentCount) continue
    const lat = toNum(it.lat)
    const lon = toNum(it.lon ?? it.lng)
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue
    out.push({ afterIndex: after, lat: toFixedNum(lat), lon: toFixedNum(lon) })
  }
  return out
}

export function readRouteGeometry(raw: unknown): { lat: number; lon: number; lng: number }[] {
  if (!Array.isArray(raw)) return []
  const out: { lat: number; lon: number; lng: number }[] = []
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue
    const it = item as AnyMap
    const lat = toNum(it.lat ?? it.latitude ?? it.locationLat)
    const lon = toNum(it.lon ?? it.lng ?? it.longitude ?? it.locationLon)
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue
    out.push({ lat, lon, lng: lon })
  }
  return out
}

export function readRouteInstructions(raw: unknown, maxItems = 8): string[] {
  if (!Array.isArray(raw)) return []
  return raw
    .map((e) => String(e).trim())
    .filter(Boolean)
    .slice(0, maxItems)
}

export function readRouteSegmentDetails(raw: unknown, maxSegments = 24, maxStepsPerSegment = 8): AnyMap[] {
  if (!Array.isArray(raw)) return []
  const out: AnyMap[] = []

  const sanitizeStop = (rawStop: any): AnyMap | null => {
    if (!rawStop || typeof rawStop !== 'object') return null
    const name = String(rawStop.name ?? rawStop.label ?? '').trim()
    const lat = toNum(rawStop.lat)
    const lon = toNum(rawStop.lon ?? rawStop.lng)
    const stop: AnyMap = {}
    if (name) stop.name = name
    if (Number.isFinite(lat) && Number.isFinite(lon)) {
      stop.lat = lat
      stop.lon = lon
      stop.lng = lon
    }
    return Object.keys(stop).length ? stop : null
  }

  for (const item of raw.slice(0, maxSegments)) {
    if (!item || typeof item !== 'object') continue
    const segmentIndex = typeof item.segmentIndex === 'number' ? Math.trunc(item.segmentIndex) : null
    if (segmentIndex == null || segmentIndex < 0) continue

    const mode = normalizeRouteMode(String(item.mode ?? ''))
    const steps: AnyMap[] = []
    if (Array.isArray(item.steps)) {
      for (const step of item.steps.slice(0, maxStepsPerSegment)) {
        if (!step || typeof step !== 'object') continue
        const tabLabel = String(step.tabLabel ?? '').trim()
        const headline = String(step.headline ?? '').trim()
        if (!tabLabel && !headline) continue
        const stepMap: AnyMap = { mode: String(step.mode ?? '').trim().toLowerCase() }
        if (tabLabel) stepMap.tabLabel = tabLabel
        if (headline) stepMap.headline = headline
        const detail = String(step.detail ?? '').trim()
        const caption = String(step.caption ?? '').trim()
        const lineColor = String(step.lineColor ?? '').trim()
        if (detail) stepMap.detail = detail
        if (caption) stepMap.caption = caption
        if (lineColor) stepMap.lineColor = lineColor
        const focusLat = toNum(step.focusLat ?? step.lat)
        const focusLon = toNum(step.focusLon ?? step.lon ?? step.lng)
        if (Number.isFinite(focusLat) && Number.isFinite(focusLon)) {
          stepMap.focusLat = focusLat
          stepMap.focusLon = focusLon
          stepMap.lat = focusLat
          stepMap.lon = focusLon
          stepMap.lng = focusLon
        }
        const focusZoom = toNum(step.focusZoom)
        if (Number.isFinite(focusZoom) && focusZoom > 0) stepMap.focusZoom = clamp(focusZoom, 3, 18)
        const path = readRouteGeometry(step.path)
        if (path.length) stepMap.path = path
        steps.push(stepMap)
      }
    }
    if (!steps.length) continue

    const detail: AnyMap = { segmentIndex, mode, steps }
    const distanceMeters = toNum(item.distanceMeters)
    const durationSeconds = toNum(item.durationSeconds)
    if (distanceMeters > 0) detail.distanceMeters = distanceMeters
    if (durationSeconds > 0) detail.durationSeconds = durationSeconds
    const arrivalStop = sanitizeStop(item.arrivalStop)
    if (arrivalStop) detail.arrivalStop = arrivalStop
    out.push(detail)
  }
  return out
}

export function simplifyRouteGeometry(geometry: AnyMap[], maxPoints = 450): { lat: number; lon: number; lng: number }[] {
  if (geometry.length <= maxPoints) {
    return geometry.map((p) => {
      const lon = toNum(p.lon ?? p.lng)
      return { lat: toNum(p.lat), lon, lng: lon }
    })
  }
  const out: { lat: number; lon: number; lng: number }[] = []
  const lastIndex = geometry.length - 1
  const step = clamp(lastIndex / (maxPoints - 1), 1, geometry.length)
  let nextIndex = 0
  for (let i = 0; i < maxPoints; i++) {
    const index = i === maxPoints - 1 ? lastIndex : Math.min(lastIndex, Math.round(nextIndex))
    const point = geometry[index]
    const lat = toNum(point.lat)
    const lon = toNum(point.lon ?? point.lng)
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
      nextIndex += step
      continue
    }
    const prev = out[out.length - 1]
    if (prev && Math.abs(prev.lat - lat) < 1e-7 && Math.abs(prev.lon - lon) < 1e-7) {
      nextIndex += step
      continue
    }
    out.push({ lat, lon, lng: lon })
    nextIndex += step
  }
  return out
}

export function buildRouteCacheKey(opts: {
  waypoints: AnyMap[]
  transportMode: string
  segmentTransportModes?: unknown[]
  segmentRoutingTypes?: unknown[]
  routeVia?: unknown[]
}): string {
  const segmentCount = Math.max(0, opts.waypoints.length - 1)
  const normalizedWaypoints = opts.waypoints.map((p) => ({
    lat: toFixedNum(toNum(p.lat ?? p.latitude ?? p.locationLat)),
    lon: toFixedNum(toNum(p.lon ?? p.lng ?? p.longitude ?? p.locationLon)),
    name: String(p.name ?? ''),
  }))
  return JSON.stringify({
    mode: normalizeRouteMode(opts.transportMode),
    waypoints: normalizedWaypoints,
    segmentTransportModes: normalizeSegmentModes(opts.segmentTransportModes ?? [], segmentCount, opts.transportMode),
    segmentRoutingTypes: normalizeSegmentRoutingTypes(opts.segmentRoutingTypes ?? [], {
      segmentCount,
      segmentModes: opts.segmentTransportModes,
      fallbackMode: opts.transportMode,
    }),
    routeVia: normalizeRouteVia(opts.routeVia ?? [], segmentCount),
  })
}

const degToRad = (d: number) => d * (Math.PI / 180)

export function haversineMetersBetween(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371000
  const dLat = degToRad(lat2 - lat1)
  const dLon = degToRad(lon2 - lon1)
  const a =
    Math.sin(dLat / 2) ** 2 + Math.cos(degToRad(lat1)) * Math.cos(degToRad(lat2)) * Math.sin(dLon / 2) ** 2
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}

export function normalizeSegmentRoutePoints(raw: unknown): { lat: number; lon: number; lng: number }[] {
  if (!Array.isArray(raw)) return []
  const out: { lat: number; lon: number; lng: number }[] = []
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue
    const lat = toNum((item as AnyMap).lat)
    const lon = toNum((item as AnyMap).lon ?? (item as AnyMap).lng)
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue
    out.push({ lat: toFixedNum(lat), lon: toFixedNum(lon), lng: toFixedNum(lon) })
  }
  return out
}

export function buildSegmentRouteCacheKey(opts: { segmentPoints: AnyMap[]; routingType: string; mode: string }): string {
  return JSON.stringify({
    routingType: normalizeSegmentRoutingType(opts.routingType, normalizeRouteMode(opts.mode)),
    mode: normalizeRouteMode(opts.mode),
    points: opts.segmentPoints.map((p) => ({
      lat: toFixedNum(toNum(p.lat)),
      lon: toFixedNum(toNum(p.lon ?? p.lng)),
    })),
  })
}

export function segmentRoutePointsDriftBeyondTolerance(
  cached: AnyMap[],
  current: AnyMap[],
  toleranceMeters = 100,
): boolean {
  if (cached.length !== current.length) return true
  for (let i = 0; i < cached.length; i++) {
    const drift = haversineMetersBetween(
      toNum(cached[i].lat),
      toNum(cached[i].lon ?? cached[i].lng),
      toNum(current[i].lat),
      toNum(current[i].lon ?? current[i].lng),
    )
    if (drift > toleranceMeters) return true
  }
  return false
}

export function readPersistedSegmentRouteCacheEntry(
  raw: any,
  opts: { currentSegmentPoints: AnyMap[]; mode: string; routingType: string; invalidationMeters?: number },
): AnyMap | null {
  if (!raw || typeof raw !== 'object') return null
  const cachedPoints = normalizeSegmentRoutePoints(raw.segmentPoints)
  if (
    !cachedPoints.length ||
    segmentRoutePointsDriftBeyondTolerance(cachedPoints, opts.currentSegmentPoints, opts.invalidationMeters ?? 100)
  ) {
    return null
  }
  const expectedKey = buildSegmentRouteCacheKey({
    segmentPoints: opts.currentSegmentPoints,
    routingType: opts.routingType,
    mode: opts.mode,
  })
  const storedKey = String(raw.cacheKey ?? '').trim()
  if (storedKey && storedKey !== expectedKey) return null

  const geometry = simplifyRouteGeometry(readRouteGeometry(raw.geometry))
  if (geometry.length < 2) return null

  const out: AnyMap = {
    segmentIndex: typeof raw.segmentIndex === 'number' ? Math.trunc(raw.segmentIndex) : -1,
    cacheKey: expectedKey,
    mode: normalizeRouteMode(String(raw.mode ?? opts.mode)),
    routingType: normalizeSegmentRoutingType(String(raw.routingType ?? opts.routingType), opts.mode),
    segmentPoints: cachedPoints,
    geometry,
    distanceMeters: toNum(raw.distanceMeters),
    durationSeconds: toNum(raw.durationSeconds),
    instructions: readRouteInstructions(raw.instructions),
  }
  if (String(raw.source ?? '').trim()) out.source = String(raw.source).trim()
  if (String(raw.updatedAt ?? '').trim()) out.updatedAt = String(raw.updatedAt).trim()
  return out
}

export function buildPersistedSegmentRouteCacheEntry(opts: {
  segmentIndex: number
  segmentPoints: AnyMap[]
  geometry: AnyMap[]
  mode: string
  routingType: string
  distanceMeters: number
  durationSeconds: number
  instructions?: string[]
  source?: string
}): AnyMap {
  return {
    segmentIndex: opts.segmentIndex,
    cacheKey: buildSegmentRouteCacheKey({ segmentPoints: opts.segmentPoints, routingType: opts.routingType, mode: opts.mode }),
    mode: normalizeRouteMode(opts.mode),
    routingType: normalizeSegmentRoutingType(opts.routingType, opts.mode),
    segmentPoints: normalizeSegmentRoutePoints(opts.segmentPoints),
    geometry: simplifyRouteGeometry(opts.geometry, 160),
    distanceMeters: opts.distanceMeters,
    durationSeconds: opts.durationSeconds,
    instructions: (opts.instructions ?? []).map((l) => l.trim()).filter(Boolean).slice(0, 6),
    source: opts.source ?? 'runtime',
    updatedAt: new Date().toISOString(),
  }
}
