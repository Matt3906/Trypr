import { fetchOverpassData, hasAvailableOverpassEndpoint } from './overpass'
import { OVERLAY_CACHE_TTL_MS, isFresh, latLngMergeKey } from './graph'
import { ceilToStep, floorToStep, haversineMeters, pathSignature, roundToStep, samplePath, type LL } from './geo'

export type AnyMap = Record<string, any>

export interface HikingOverlayEntry {
  fetchedAt: number
  trailLines: LL[][]
  campsites: AnyMap[]
  trailheads: AnyMap[]
}

export interface PortagingOverlayEntry {
  fetchedAt: number
  waterLines: LL[][]
  waterPolygons: LL[][]
  portageLines: LL[][]
  campsites: AnyMap[]
  accessPoints: AnyMap[]
}

const hikingCache = new Map<string, HikingOverlayEntry>()
const portagingCache = new Map<string, PortagingOverlayEntry>()
const hikingInFlight = new Map<string, Promise<HikingOverlayEntry | null>>()
const portagingInFlight = new Map<string, Promise<PortagingOverlayEntry | null>>()

/** Last portage overlay shown on the map; reused by the router when a fresh fetch fails. */
export const portageState: { lastVisible: PortagingOverlayEntry | null } = { lastVisible: null }
export const portagingCacheRef = portagingCache

// ---------- cache key helpers ----------
export function hikingCacheKey(routePath: LL[], padDegrees = 0.08): string {
  let minLat = Infinity, maxLat = -Infinity, minLon = Infinity, maxLon = -Infinity
  for (const p of routePath) {
    minLat = Math.min(minLat, p.lat); maxLat = Math.max(maxLat, p.lat)
    minLon = Math.min(minLon, p.lng); maxLon = Math.max(maxLon, p.lng)
  }
  const bucket = Math.max(0.02, padDegrees / 2)
  const south = floorToStep(minLat - padDegrees, bucket)
  const west = floorToStep(minLon - padDegrees, bucket)
  const north = ceilToStep(maxLat + padDegrees, bucket)
  const east = ceilToStep(maxLon + padDegrees, bucket)
  return `${south.toFixed(3)},${west.toFixed(3)},${north.toFixed(3)},${east.toFixed(3)}`
}
export const portagingRouteCacheKey = (anchors: LL[]) => `route:${hikingCacheKey(anchors)}:portaging`
export { roundToStep as roundToStepExport }
export const quantizedOverlayPadDegrees = (pad: number) => roundToStep(Math.min(0.24, Math.max(0.04, pad)), 0.02)
export function portagingFocusCacheKey(focus: LL, padDegrees = 0.18): string {
  const q = quantizedOverlayPadDegrees(padDegrees)
  const bucket = Math.max(0.02, q / 4)
  return `focus:${roundToStep(focus.lat, bucket).toFixed(3)},${roundToStep(focus.lng, bucket).toFixed(3)}:${q.toFixed(2)}`
}

export function adaptivePortageRoutePadDegrees(anchors: LL[]): number {
  if (!anchors.length) return 0.04
  let minLat = Infinity, maxLat = -Infinity, minLon = Infinity, maxLon = -Infinity
  for (const p of anchors) {
    minLat = Math.min(minLat, p.lat); maxLat = Math.max(maxLat, p.lat)
    minLon = Math.min(minLon, p.lng); maxLon = Math.max(maxLon, p.lng)
  }
  const span = Math.max(maxLat - minLat, maxLon - minLon)
  return Math.min(0.12, Math.max(0.05, 0.03 + span * 0.22))
}

export function routeBoundsCenter(anchors: LL[]): LL {
  if (!anchors.length) return { lat: 0, lng: 0 }
  let minLat = Infinity, maxLat = -Infinity, minLon = Infinity, maxLon = -Infinity
  for (const p of anchors) {
    minLat = Math.min(minLat, p.lat); maxLat = Math.max(maxLat, p.lat)
    minLon = Math.min(minLon, p.lng); maxLon = Math.max(maxLon, p.lng)
  }
  return { lat: (minLat + maxLat) / 2, lng: (minLon + maxLon) / 2 }
}

export function routeFocusPadDegrees(anchors: LL[], opts: { minPad: number; maxPad: number; edgePadding: number }): number {
  if (!anchors.length) return opts.minPad
  let minLat = Infinity, maxLat = -Infinity, minLon = Infinity, maxLon = -Infinity
  for (const p of anchors) {
    minLat = Math.min(minLat, p.lat); maxLat = Math.max(maxLat, p.lat)
    minLon = Math.min(minLon, p.lng); maxLon = Math.max(maxLon, p.lng)
  }
  const span = Math.max(maxLat - minLat, maxLon - minLon)
  return Math.min(opts.maxPad, Math.max(opts.minPad, opts.edgePadding + span / 2))
}

export function trailRoutePadDegreesForMode(mode: string, expanded = false): number {
  if (mode === 'portaging') return expanded ? 0.16 : 0.1
  return expanded ? 0.14 : 0.08
}

// ---------- geometry parsing helpers ----------
const geometryToLine = (geom: any[]): LL[] => {
  const line: LL[] = []
  for (const g of geom ?? []) {
    if (typeof g?.lat !== 'number' || typeof g?.lon !== 'number') continue
    line.push({ lat: g.lat, lng: g.lon })
  }
  return line
}
const centroid = (line: LL[]): LL | null => {
  if (!line.length) return null
  let la = 0, lo = 0
  for (const p of line) { la += p.lat; lo += p.lng }
  return { lat: la / line.length, lng: lo / line.length }
}
const centroidFromMembers = (members: any[]): LL | null => {
  let la = 0, lo = 0, n = 0
  for (const m of members ?? []) for (const g of m?.geometry ?? []) {
    if (typeof g?.lat !== 'number' || typeof g?.lon !== 'number') continue
    la += g.lat; lo += g.lon; n++
  }
  return n ? { lat: la / n, lng: lo / n } : null
}
const lower = (v: unknown) => String(v ?? '').toLowerCase()
const isCampTags = (t: AnyMap) => ['camp_site', 'camp_pitch'].includes(lower(t.tourism))

function campFrom(name: string, lat: number, lon: number, tags: AnyMap, sourceType: string): AnyMap {
  const camp: AnyMap = { name, lat, lon, sourceType }
  const copy = (src: string, dst: string) => {
    const v = String(tags[src] ?? '').trim()
    if (v) camp[dst] = v
  }
  copy('operator', 'operator'); copy('access', 'access'); copy('capacity', 'capacity'); copy('description', 'description')
  copy('website', 'website'); copy('url', 'website'); copy('park', 'park'); copy('park:name', 'park')
  copy('addr:place', 'lakeName'); copy('loc_name', 'lakeName')
  return camp
}

// ---------- hiking ----------
async function fetchHikingOverlayData(routePath: LL[], padDegrees = 0.08): Promise<HikingOverlayEntry | null> {
  if (!routePath.length) return null
  let minLat = Infinity, maxLat = -Infinity, minLon = Infinity, maxLon = -Infinity
  for (const p of routePath) {
    minLat = Math.min(minLat, p.lat); maxLat = Math.max(maxLat, p.lat)
    minLon = Math.min(minLon, p.lng); maxLon = Math.max(maxLon, p.lng)
  }
  const south = minLat - padDegrees, west = minLon - padDegrees, north = maxLat + padDegrees, east = maxLon + padDegrees
  const bb = `${south},${west},${north},${east}`
  const query = `[out:json][timeout:25];
(
  way["highway"="path"](${bb});
  way["highway"="footway"](${bb});
  way["route"="hiking"](${bb});
  relation["route"="hiking"](${bb});
  node["tourism"~"camp_site|camp_pitch"](${bb});
  way["tourism"~"camp_site|camp_pitch"](${bb});
  relation["tourism"~"camp_site|camp_pitch"](${bb});
  node["tourism"="information"]["information"~"trailhead|guidepost"](${bb});
  way["tourism"="information"]["information"~"trailhead|guidepost"](${bb});
  relation["tourism"="information"]["information"~"trailhead|guidepost"](${bb});
  node["trailhead"="yes"](${bb});
  way["trailhead"="yes"](${bb});
  relation["trailhead"="yes"](${bb});
);
out body geom;`
  const data = await fetchOverpassData({ query, logPrefix: 'hikingOverpass', requestTimeoutMs: 11000 })
  if (!data) return null

  const trails: LL[][] = []
  const campsites: AnyMap[] = []
  const trailheads: AnyMap[] = []
  const seenCamp = new Set<string>()
  const seenHead = new Set<string>()
  const isTrailhead = (t: AnyMap) => lower(t.trailhead) === 'yes' || (lower(t.tourism) === 'information' && ['trailhead', 'guidepost'].includes(lower(t.information)))
  const isTrail = (t: AnyMap) => ['path', 'footway'].includes(lower(t.highway)) || lower(t.route) === 'hiking'
  const addCamp = (name: string, lat: number, lon: number, tags: AnyMap, sourceType: string) => {
    const key = `${lat.toFixed(5)},${lon.toFixed(5)}`
    if (seenCamp.has(key)) return
    seenCamp.add(key)
    campsites.push(campFrom(name, lat, lon, tags, sourceType))
  }
  const addHead = (name: string, lat: number, lon: number) => {
    const key = `${lat.toFixed(5)},${lon.toFixed(5)}`
    if (seenHead.has(key)) return
    seenHead.add(key)
    trailheads.push({ name, lat, lon })
  }

  for (const m of data.elements ?? []) {
    const type = String(m.type ?? '')
    const tags: AnyMap = m.tags ?? {}
    if (type === 'way') {
      const line = geometryToLine(m.geometry)
      if (line.length >= 2 && isTrail(tags)) trails.push(line)
      const c = centroid(line)
      if (c && isCampTags(tags)) addCamp(String(tags.name ?? 'Campsite'), c.lat, c.lng, tags, type)
      if (c && isTrailhead(tags)) addHead(String(tags.name ?? 'Trailhead'), c.lat, c.lng)
    } else if (type === 'relation') {
      const members = m.members ?? []
      if (isTrail(tags)) for (const mem of members) {
        const line = geometryToLine(mem.geometry)
        if (line.length >= 2) trails.push(line)
      }
      const c = centroidFromMembers(members)
      if (c && isCampTags(tags)) addCamp(String(tags.name ?? 'Campsite'), c.lat, c.lng, tags, type)
      if (c && isTrailhead(tags)) addHead(String(tags.name ?? 'Trailhead'), c.lat, c.lng)
    } else if (type === 'node') {
      if (typeof m.lat !== 'number' || typeof m.lon !== 'number') continue
      if (isCampTags(tags)) addCamp(String(tags.name ?? 'Campsite'), m.lat, m.lon, tags, type)
      else if (isTrailhead(tags)) addHead(String(tags.name ?? 'Trailhead'), m.lat, m.lon)
    }
  }
  console.debug(`hikingOverpass converted trails=${trails.length} campsites=${campsites.length} trailheads=${trailheads.length}`)
  return { fetchedAt: Date.now(), trailLines: trails, campsites, trailheads }
}

export async function getHikingOverlayEntry(opts: { cacheKey: string; routePath: LL[]; padDegrees?: number }): Promise<HikingOverlayEntry | null> {
  const cached = hikingCache.get(opts.cacheKey)
  if (cached && isFresh(cached.fetchedAt, OVERLAY_CACHE_TTL_MS)) return cached
  const pending = hikingInFlight.get(opts.cacheKey)
  if (pending) return cached ?? pending
  const p = fetchHikingOverlayData(opts.routePath, opts.padDegrees)
  hikingInFlight.set(opts.cacheKey, p)
  try {
    const entry = await p
    if (entry) {
      hikingCache.set(opts.cacheKey, entry)
      return entry
    }
    return cached ?? null
  } finally {
    if (hikingInFlight.get(opts.cacheKey) === p) hikingInFlight.delete(opts.cacheKey)
  }
}
export const peekHikingCache = (key: string) => hikingCache.get(key)

// ---------- portaging ----------
const ACCESS_NAME_RE = 'access point|put[ -]?in|take[ -]?out|boat launch|canoe launch|landing'

async function fetchPortagingOverlayData(opts: { anchors: LL[]; focusPoint?: LL | null; padDegrees?: number; includeCampsites?: boolean }): Promise<PortagingOverlayEntry | null> {
  const { anchors, focusPoint } = opts
  const padDegrees = opts.padDegrees ?? 0.18
  const includeCampsites = opts.includeCampsites ?? true
  if (!anchors.length && !focusPoint) return null

  let south: number, west: number, north: number, east: number
  if (focusPoint) {
    south = focusPoint.lat - padDegrees; west = focusPoint.lng - padDegrees
    north = focusPoint.lat + padDegrees; east = focusPoint.lng + padDegrees
  } else {
    let minLat = Infinity, maxLat = -Infinity, minLon = Infinity, maxLon = -Infinity
    for (const p of anchors) {
      minLat = Math.min(minLat, p.lat); maxLat = Math.max(maxLat, p.lat)
      minLon = Math.min(minLon, p.lng); maxLon = Math.max(maxLon, p.lng)
    }
    south = minLat - padDegrees; west = minLon - padDegrees; north = maxLat + padDegrees; east = maxLon + padDegrees
  }
  const bb = `${south},${west},${north},${east}`
  const campsiteQuery = includeCampsites ? `
  node["tourism"~"camp_site|camp_pitch"](${bb});
  way["tourism"~"camp_site|camp_pitch"](${bb});
  relation["tourism"~"camp_site|camp_pitch"](${bb});` : ''
  const query = `[out:json][timeout:25];
(
  way["waterway"~"river|stream|canal|drain|ditch"](${bb});
  way["natural"="water"](${bb});
  way["route"="canoe"](${bb});
  relation["natural"="water"](${bb});
  relation["route"="canoe"](${bb});
  way["highway"~"path|footway|track"]["canoe"~"portage|yes"](${bb});
  way["portage"~"yes|designated|official"](${bb});
  way["canoe"="portage"](${bb});${campsiteQuery}
  node["canoe"~"put_in|take_out|yes"](${bb});
  way["canoe"~"put_in|take_out|yes"](${bb});
  node["portage"~"yes|put_in|take_out"](${bb});
  way["portage"~"yes|put_in|take_out"](${bb});
  node["amenity"="boat_ramp"](${bb});
  way["amenity"="boat_ramp"](${bb});
  node["leisure"="slipway"](${bb});
  way["leisure"="slipway"](${bb});
  node["name"~"${ACCESS_NAME_RE}",i](${bb});
  way["name"~"${ACCESS_NAME_RE}",i](${bb});
  relation["canoe"~"put_in|take_out|yes"](${bb});
  relation["portage"~"yes|put_in|take_out"](${bb});
  relation["name"~"${ACCESS_NAME_RE}",i](${bb});
);
out body geom;`

  let data = await fetchOverpassData({ query, logPrefix: 'portagingOverpass', requestTimeoutMs: 12000 })
  if (!data && focusPoint) {
    if (!hasAvailableOverpassEndpoint()) {
      console.debug('portagingOverpassLite skip_focus_retry all_endpoints_blocked')
    } else {
      const lp = Math.min(padDegrees, 0.12)
      const lbb = `${focusPoint.lat - lp},${focusPoint.lng - lp},${focusPoint.lat + lp},${focusPoint.lng + lp}`
      const liteCamp = includeCampsites ? `\n  node["tourism"~"camp_site|camp_pitch"](${lbb});` : ''
      const lite = `[out:json][timeout:18];
(
  way["waterway"~"river|stream|canal|drain|ditch"](${lbb});
  way["natural"="water"](${lbb});
  way["route"="canoe"](${lbb});
  way["highway"~"path|footway|track"]["canoe"~"portage|yes"](${lbb});
  way["portage"~"yes|designated|official"](${lbb});
  way["canoe"="portage"](${lbb});${liteCamp}
  node["canoe"~"put_in|take_out|yes"](${lbb});
  way["canoe"~"put_in|take_out|yes"](${lbb});
  node["portage"~"yes|put_in|take_out"](${lbb});
  way["portage"~"yes|put_in|take_out"](${lbb});
  node["amenity"="boat_ramp"](${lbb});
  way["amenity"="boat_ramp"](${lbb});
  node["leisure"="slipway"](${lbb});
  way["leisure"="slipway"](${lbb});
  node["name"~"${ACCESS_NAME_RE}",i](${lbb});
  way["name"~"${ACCESS_NAME_RE}",i](${lbb});
);
out body geom;`
      data = await fetchOverpassData({ query: lite, logPrefix: 'portagingOverpassLite', requestTimeoutMs: 8000 })
    }
  }
  if (!data) return null

  const waterLines: LL[][] = []
  const waterPolygons: LL[][] = []
  const portageLines: LL[][] = []
  const campsites: AnyMap[] = []
  const accessPoints: AnyMap[] = []
  const seenCamp = new Set<string>(), seenAccess = new Set<string>(), seenPoly = new Set<string>()

  const isPortageTags = (t: AnyMap) => {
    const portage = lower(t.portage), canoe = lower(t.canoe), route = lower(t.route), highway = lower(t.highway)
    if (['yes', 'designated', 'official'].includes(portage)) return true
    if (canoe === 'portage' || route === 'portage') return true
    return ['path', 'footway', 'track'].includes(highway) && (!!canoe || !!portage)
  }
  const isWaterTags = (t: AnyMap) => !!lower(t.waterway) || lower(t.route) === 'canoe' || lower(t.natural) === 'water' || lower(t.canoe) === 'yes'
  const isNaturalWater = (t: AnyMap) => lower(t.natural) === 'water'
  const isAccessTags = (t: AnyMap) => {
    const canoe = lower(t.canoe), portage = lower(t.portage), amenity = lower(t.amenity), leisure = lower(t.leisure), name = lower(t.name)
    if (['put_in', 'take_out', 'yes'].includes(canoe)) return true
    if (['put_in', 'take_out', 'yes'].includes(portage)) return true
    if (amenity === 'boat_ramp' || leisure === 'slipway') return true
    return ['access point', 'put in', 'put-in', 'take out', 'take-out', 'boat launch', 'canoe launch', 'landing'].some((s) => name.includes(s))
  }
  const normalizeRing = (ring: LL[]): LL[] | null => {
    if (ring.length < 4) return null
    const closeMeters = haversineMeters(ring[0], ring[ring.length - 1])
    if (!Number.isFinite(closeMeters) || closeMeters > 45) return null
    const out = [...ring]
    if (closeMeters > 2) out.push(ring[0])
    if (out.length < 4) return null
    const key = out.map((p) => `${p.lat.toFixed(4)},${p.lng.toFixed(4)}`).join(';')
    if (seenPoly.has(key)) return null
    seenPoly.add(key)
    return out
  }
  const addCamp = (name: string, lat: number, lon: number, tags: AnyMap, st: string) => {
    const key = `${lat.toFixed(5)},${lon.toFixed(5)}`
    if (seenCamp.has(key)) return
    seenCamp.add(key)
    campsites.push(campFrom(name, lat, lon, tags, st))
  }
  const addAccess = (name: string, lat: number, lon: number) => {
    const key = `${lat.toFixed(5)},${lon.toFixed(5)}`
    if (seenAccess.has(key)) return
    seenAccess.add(key)
    accessPoints.push({ name, lat, lon })
  }

  for (const m of data.elements ?? []) {
    const type = String(m.type ?? '')
    const tags: AnyMap = m.tags ?? {}
    if (type === 'way') {
      const line = geometryToLine(m.geometry)
      if (line.length < 2) continue
      if (isWaterTags(tags)) waterLines.push(line)
      if (isNaturalWater(tags)) {
        const ring = normalizeRing(line)
        if (ring) waterPolygons.push(ring)
      }
      if (isPortageTags(tags)) portageLines.push(line)
      const c = centroid(line)
      if (c && isCampTags(tags)) addCamp(String(tags.name ?? 'Campsite'), c.lat, c.lng, tags, type)
      if (c && isAccessTags(tags)) addAccess(String(tags.name ?? 'Portage access'), c.lat, c.lng)
    } else if (type === 'relation') {
      const natural = lower(tags.natural), route = lower(tags.route)
      const members = m.members ?? []
      if (natural === 'water') {
        for (const mem of members) {
          const line = geometryToLine(mem.geometry)
          if (line.length >= 2) waterLines.push(line)
          const ring = normalizeRing(line)
          if (ring) waterPolygons.push(ring)
        }
      }
      if (route === 'canoe') {
        for (const mem of members) {
          const line = geometryToLine(mem.geometry)
          if (line.length >= 2) waterLines.push(line)
        }
      }
      const c = centroidFromMembers(members)
      if (c && isCampTags(tags)) addCamp(String(tags.name ?? 'Campsite'), c.lat, c.lng, tags, type)
      if (c && isAccessTags(tags)) addAccess(String(tags.name ?? 'Portage access'), c.lat, c.lng)
    } else if (type === 'node') {
      if (typeof m.lat !== 'number' || typeof m.lon !== 'number') continue
      if (isCampTags(tags)) addCamp(String(tags.name ?? 'Campsite'), m.lat, m.lon, tags, type)
      if (isAccessTags(tags)) addAccess(String(tags.name ?? 'Portage access'), m.lat, m.lon)
    }
  }
  console.debug(`portagingOverpass converted water=${waterLines.length} polygons=${waterPolygons.length} portage=${portageLines.length} campsites=${campsites.length} access=${accessPoints.length}`)
  return { fetchedAt: Date.now(), waterLines, waterPolygons, portageLines, campsites, accessPoints }
}

export async function getPortagingOverlayEntry(opts: { cacheKey: string; anchors: LL[]; focusPoint?: LL | null; padDegrees: number; includeCampsites?: boolean }): Promise<PortagingOverlayEntry | null> {
  const cached = portagingCache.get(opts.cacheKey)
  if (cached && isFresh(cached.fetchedAt, OVERLAY_CACHE_TTL_MS)) return cached
  const pending = portagingInFlight.get(opts.cacheKey)
  if (pending) return cached ?? pending
  const p = fetchPortagingOverlayData(opts)
  portagingInFlight.set(opts.cacheKey, p)
  try {
    const entry = await p
    if (entry) {
      portagingCache.set(opts.cacheKey, entry)
      return entry
    }
    return cached ?? null
  } finally {
    if (portagingInFlight.get(opts.cacheKey) === p) portagingInFlight.delete(opts.cacheKey)
  }
}

const lineMergeKey = (line: LL[], sample = 12) => {
  if (!line.length) return ''
  const fwd = pathSignature(line, sample)
  const rev = pathSignature([...line].reverse(), sample)
  return fwd <= rev ? fwd : rev
}

export function portagingOverlayFocusPoints(opts: { routePath: LL[]; modeAnchors: LL[]; focusPoint?: LL | null; maxPoints?: number }): LL[] {
  const maxPoints = opts.maxPoints ?? 5
  if (maxPoints <= 0) return []
  const source = opts.routePath.length >= 2 ? opts.routePath : opts.modeAnchors
  const out: LL[] = []
  const seen = new Set<string>()
  const add = (p: LL) => {
    const key = latLngMergeKey(p, 3)
    if (!seen.has(key)) {
      seen.add(key)
      out.push(p)
    }
  }
  if (opts.focusPoint) add(opts.focusPoint)
  if (source.length) {
    add(source[0])
    if (source.length > 2) add(source[Math.floor(source.length / 2)])
    for (const p of samplePath(source, maxPoints)) {
      add(p)
      if (out.length >= maxPoints) break
    }
    add(source[source.length - 1])
  }
  if (out.length <= maxPoints) return out
  const trimmed: LL[] = []
  const tseen = new Set<string>()
  const keep = (p: LL) => {
    const key = latLngMergeKey(p, 3)
    if (tseen.has(key)) return
    tseen.add(key)
    if (trimmed.length < maxPoints) trimmed.push(p)
  }
  if (opts.focusPoint) keep(opts.focusPoint)
  if (source.length) {
    for (const p of samplePath(source, maxPoints)) keep(p)
    keep(source[source.length - 1])
  }
  return trimmed
}

export function mergePortagingOverlayEntries(entries: PortagingOverlayEntry[]): PortagingOverlayEntry {
  if (!entries.length) return { fetchedAt: Date.now(), waterLines: [], waterPolygons: [], portageLines: [], campsites: [], accessPoints: [] }
  const waterLines: LL[][] = [], waterPolygons: LL[][] = [], portageLines: LL[][] = []
  const campsites: AnyMap[] = [], accessPoints: AnyMap[] = []
  const sw = new Set<string>(), sp = new Set<string>(), sg = new Set<string>(), sc = new Set<string>(), sa = new Set<string>()
  let newest = entries[0].fetchedAt
  for (const e of entries) {
    newest = Math.max(newest, e.fetchedAt)
    for (const line of e.waterLines) { const k = lineMergeKey(line, 10); if (k && !sw.has(k)) { sw.add(k); waterLines.push(line) } }
    for (const poly of e.waterPolygons) { const k = lineMergeKey(poly, 10); if (k && !sp.has(k)) { sp.add(k); waterPolygons.push(poly) } }
    for (const line of e.portageLines) { const k = lineMergeKey(line, 10); if (k && !sg.has(k)) { sg.add(k); portageLines.push(line) } }
    for (const c of e.campsites) { const k = `${Number(c.lat).toFixed(5)},${Number(c.lon).toFixed(5)}`; if (!sc.has(k)) { sc.add(k); campsites.push({ ...c }) } }
    for (const a of e.accessPoints) { const k = `${Number(a.lat).toFixed(5)},${Number(a.lon).toFixed(5)}`; if (!sa.has(k)) { sa.add(k); accessPoints.push({ ...a }) } }
  }
  return { fetchedAt: newest, waterLines, waterPolygons, portageLines, campsites, accessPoints }
}

export async function loadSegmentedPortagingOverlayEntry(opts: {
  routePath: LL[]; modeAnchors: LL[]; focusPoint: LL; padDegrees: number; includeCampsites?: boolean; maxFocusQueries?: number; logPrefix: string
}): Promise<PortagingOverlayEntry | null> {
  const focusPoints = portagingOverlayFocusPoints({ routePath: opts.routePath, modeAnchors: opts.modeAnchors, focusPoint: opts.focusPoint, maxPoints: opts.maxFocusQueries ?? 4 })
  if (!focusPoints.length) return null
  const entries: PortagingOverlayEntry[] = []
  for (const point of focusPoints) {
    const entry = await getPortagingOverlayEntry({
      cacheKey: portagingFocusCacheKey(point, opts.padDegrees), anchors: [point], focusPoint: point, padDegrees: opts.padDegrees, includeCampsites: opts.includeCampsites ?? true,
    })
    if (entry) entries.push(entry)
  }
  if (!entries.length) return null
  if (entries.length === 1) return entries[0]
  const merged = mergePortagingOverlayEntries(entries)
  console.debug(`${opts.logPrefix} segmented_focus_merged samples=${entries.length} water=${merged.waterLines.length} portage=${merged.portageLines.length}`)
  return merged
}

export function nearestCachedPortagingFocusEntry(focus: LL, maxDegreesDelta = 0.22): PortagingOverlayEntry | null {
  let best: PortagingOverlayEntry | null = null
  let bestDistance = Infinity
  let bestFresh = false
  for (const [rawKey, value] of portagingCache) {
    const key = rawKey.trim()
    if (!key.startsWith('focus:')) continue
    if (!value.waterLines.length && !value.portageLines.length) continue
    const parts = key.split(':')
    if (parts.length < 3) continue
    const ll = parts[1].split(',')
    if (ll.length !== 2) continue
    const lat = parseFloat(ll[0]), lon = parseFloat(ll[1])
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue
    const dLat = Math.abs(focus.lat - lat), dLon = Math.abs(focus.lng - lon)
    if (dLat > maxDegreesDelta || dLon > maxDegreesDelta) continue
    const distance = dLat + dLon
    const fresh = isFresh(value.fetchedAt, OVERLAY_CACHE_TTL_MS)
    if (!best || (fresh && !bestFresh) || (fresh === bestFresh && distance < bestDistance)) {
      best = value
      bestDistance = distance
      bestFresh = fresh
    }
  }
  return best
}
