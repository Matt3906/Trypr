import { config } from '@/config'
import { getDirections } from '@/services/directions'
import { normalizeMapMode, standardRouteColor } from '@/components/map/mapStyles'
import { haversineMeters, pathDistanceMeters, type LL } from './geo'
import { latOf, lonOf, type PointMap, type RouteComputation } from './types'
import { routeViaPortageGraph, routeViaTrailGraph } from './adventureRouting'

const proxyUnavailable = new Set<string>()

function withTimeout<T>(p: Promise<T>, ms: number, fallback: T): Promise<T> {
  return Promise.race([p, new Promise<T>((r) => setTimeout(() => r(fallback), ms))])
}

const isAdventure = (mode: string) => mode === 'hiking' || mode === 'portaging'

function strictError(message: string): never {
  const full = `STRICT_ROUTING_HARD_ERROR ${message}`
  console.error(full)
  throw new Error(full)
}

export function segmentLatLngs(segPoints: PointMap[]): LL[] {
  return segPoints.map((p) => ({ lat: latOf(p), lng: lonOf(p) }))
}

function straightRoute(opts: { path: LL[]; mode: string; color: string; width: number; dashed?: { dash: number; gap: number } | null; geodesic: boolean; instruction?: string; opacity?: number }): RouteComputation {
  return {
    path: opts.path,
    distanceMeters: pathDistanceMeters(opts.path),
    durationSeconds: 0,
    color: opts.color,
    width: opts.width,
    zIndex: isAdventure(opts.mode) ? 16 : 12,
    geodesic: opts.geodesic,
    dashed: opts.dashed ?? null,
    instructions: opts.instruction?.trim() ? [opts.instruction] : [],
    stepDetails: [],
    opacity: opts.opacity,
  }
}
export { straightRoute }

function routingQueryForPoint(point: PointMap): string {
  for (const raw of [point.routing_query, point.display_name, point.formatted_address, point.address, point.vicinity, point.name]) {
    const value = raw == null ? '' : String(raw).trim()
    if (!value) continue
    if (/^point\s+\d+$/i.test(value)) continue
    if (/^-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?$/.test(value)) continue
    return value
  }
  return ''
}

async function routeViaBackendProxy(segPoints: PointMap[], provider: string, profile: string, mode: string): Promise<RouteComputation | null> {
  if (segPoints.length < 2) return null
  const coordinates = segPoints.map((p) => [lonOf(p), latOf(p)])
  const url = config.routingProxyUrl || '/api/route'
  const orsFallback = (reason: string) => (provider === 'ors' ? routeViaDirectOrs(coordinates, profile, mode, reason) : Promise.resolve(null))

  try {
    if (proxyUnavailable.has(url)) return orsFallback('proxy_unavailable')
    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), 8000)
    const resp = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ provider, profile, coordinates }),
      signal: ctrl.signal,
    }).finally(() => clearTimeout(timer))

    if (!resp.ok) {
      const msg = `routeProxy non_200 provider=${provider} profile=${profile} mode=${mode} status=${resp.status}`
      if ([404, 405, 501].includes(resp.status)) proxyUnavailable.add(url)
      if (config.strictRouting) strictError(msg)
      console.debug(msg)
      return await orsFallback(`proxy_status_${resp.status}`)
    }
    const data = await resp.json()
    const path: LL[] = []
    for (const pair of data.path ?? []) {
      if (!Array.isArray(pair) || pair.length < 2) continue
      path.push({ lat: Number(pair[0]), lng: Number(pair[1]) })
    }
    if (path.length < 2) {
      const msg = `routeProxy invalid_geometry provider=${provider} profile=${profile} mode=${mode}`
      if (config.strictRouting) strictError(msg)
      return null
    }
    const instructions: string[] = []
    if (Array.isArray(data.instructions)) for (const i of data.instructions) if (String(i).trim()) instructions.push(String(i).trim())
    return {
      path,
      distanceMeters: Number(data.distanceMeters) || 0,
      durationSeconds: Number(data.durationSeconds) || 0,
      color: standardRouteColor(mode),
      width: isAdventure(mode) ? 6 : 5,
      zIndex: isAdventure(mode) ? 18 : 12,
      instructions,
      stepDetails: [],
    }
  } catch (e) {
    const msg = `routeProxy request_failed provider=${provider} profile=${profile} mode=${mode} err=${e}`
    if (config.strictRouting) strictError(msg)
    console.debug(msg)
    return orsFallback('proxy_request_failed')
  }
}

async function routeViaDirectOrs(coordinates: number[][], profile: string, mode: string, reason: string): Promise<RouteComputation | null> {
  const key = config.openRouteServiceApiKey
  if (!key || coordinates.length < 2) return null
  try {
    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), 10000)
    const resp = await fetch(`https://api.openrouteservice.org/v2/directions/${profile}/geojson`, {
      method: 'POST',
      headers: { Authorization: key, 'Content-Type': 'application/json' },
      body: JSON.stringify({ coordinates }),
      signal: ctrl.signal,
    }).finally(() => clearTimeout(timer))
    if (!resp.ok) {
      console.debug(`routeProxy direct_ors_failed profile=${profile} mode=${mode} status=${resp.status} reason=${reason}`)
      return null
    }
    const data = await resp.json()
    const feature = data.features?.[0]
    if (!feature) return null
    const path: LL[] = []
    for (const pair of feature.geometry?.coordinates ?? []) {
      if (!Array.isArray(pair) || pair.length < 2) continue
      path.push({ lat: Number(pair[1]), lng: Number(pair[0]) })
    }
    if (path.length < 2) return null
    const props = feature.properties ?? {}
    const summary = props.summary ?? {}
    const instructions: string[] = []
    for (const seg of props.segments ?? []) for (const step of seg.steps ?? []) {
      const i = String(step.instruction ?? '').trim()
      if (i) instructions.push(i)
    }
    return {
      path,
      distanceMeters: Number(summary.distance) || 0,
      durationSeconds: Number(summary.duration) || 0,
      color: standardRouteColor(mode),
      width: isAdventure(mode) ? 6 : 5,
      zIndex: isAdventure(mode) ? 18 : 12,
      instructions,
      stepDetails: [],
    }
  } catch (e) {
    console.debug(`routeProxy direct_ors_error profile=${profile} mode=${mode} reason=${reason} err=${e}`)
    return null
  }
}

export const routeViaOpenRouteService = (segPoints: PointMap[], profile: string, mode: string) => routeViaBackendProxy(segPoints, 'ors', profile, mode)
export const routeViaGraphHopperHiking = (segPoints: PointMap[]) => routeViaBackendProxy(segPoints, 'graphhopper', 'hike', 'hiking')

async function routeViaOsrm(segPoints: PointMap[], profile: string, mode: string): Promise<RouteComputation | null> {
  if (config.strictRouting) strictError(`osrm_requested mode=${mode} profile=${profile} segments=${segPoints.length}`)
  if (segPoints.length < 2) return null
  try {
    const coords = segPoints.map((p) => `${lonOf(p)},${latOf(p)}`).join(';')
    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), 10000)
    const resp = await fetch(`https://router.project-osrm.org/route/v1/${profile}/${coords}?overview=full&geometries=geojson`, { signal: ctrl.signal }).finally(() => clearTimeout(timer))
    if (!resp.ok) return null
    const data = await resp.json()
    const r0 = data.routes?.[0]
    const cl: number[][] | undefined = r0?.geometry?.coordinates
    if (!cl || cl.length < 2) return null
    return {
      path: cl.map((c) => ({ lat: c[1], lng: c[0] })),
      distanceMeters: Number(r0.distance) || 0,
      durationSeconds: Number(r0.duration) || 0,
      color: standardRouteColor(mode),
      width: isAdventure(mode) ? 6 : 5,
      zIndex: isAdventure(mode) ? 18 : 12,
      instructions: [],
      stepDetails: [],
    }
  } catch {
    return null
  }
}

async function routeViaGoogleDirections(segPoints: PointMap[], opts: { mode: string; googleMode: string; avoidHighways?: boolean; avoidTolls?: boolean }): Promise<RouteComputation | null> {
  if (segPoints.length < 2) return null
  try {
    const intermediates = segPoints.length > 2 ? segPoints.slice(1, -1) : []
    const waypoints: [number, number][] = intermediates.map((p) => [latOf(p), lonOf(p)])
    const base = {
      originLat: latOf(segPoints[0]), originLng: lonOf(segPoints[0]),
      destLat: latOf(segPoints[segPoints.length - 1]), destLng: lonOf(segPoints[segPoints.length - 1]),
      mode: opts.googleMode, waypoints: waypoints.length ? waypoints : undefined,
      avoidHighways: opts.avoidHighways, avoidTolls: opts.avoidTolls,
    }
    let result = await withTimeout(getDirections(base), 8000, null)
    if (!result) {
      const originQuery = routingQueryForPoint(segPoints[0])
      const destQuery = routingQueryForPoint(segPoints[segPoints.length - 1])
      const waypointQueries = intermediates.map(routingQueryForPoint)
      if (originQuery || destQuery || waypointQueries.some(Boolean)) {
        result = await withTimeout(getDirections({ ...base, originQuery: originQuery || undefined, destQuery: destQuery || undefined, waypointQueries }), 8000, null)
      }
    }
    if (!result || result.polylinePoints.length < 2) return null
    return {
      path: result.polylinePoints.map((p) => ({ lat: p[0], lng: p[1] })),
      distanceMeters: result.distanceMeters,
      durationSeconds: result.durationSeconds,
      color: standardRouteColor(opts.mode),
      width: opts.mode === 'gas_stops' ? 6 : 5,
      zIndex: 12,
      instructions: result.instructions,
      stepDetails: result.stepDetails,
      arrivalStop: result.transitArrivalStop,
    }
  } catch (e) {
    console.debug(`_routeViaGoogleDirections exception mode=${opts.mode}`, e)
    return null
  }
}

async function calculateUncached(segPoints: PointMap[], mode: string, segType: string): Promise<RouteComputation | null> {
  const path = segmentLatLngs(segPoints)
  if (path.length < 2) return null

  if (mode === 'plane') {
    const km = pathDistanceMeters(path) / 1000
    return straightRoute({ path, mode, color: standardRouteColor(mode), width: 4, dashed: { dash: 14, gap: 10 }, geodesic: true, instruction: `Flight distance: ${km.toFixed(1)} km` })
  }
  if (segType === 'direct') {
    return straightRoute({ path, mode, color: standardRouteColor(mode), width: isAdventure(mode) ? 6 : 4, dashed: { dash: 18, gap: 10 }, geodesic: true })
  }

  if (mode === 'car' || mode === 'gas_stops') {
    return (await routeViaGoogleDirections(segPoints, { mode, googleMode: 'driving' })) ?? (await routeViaOsrm(segPoints, 'driving', mode))
  }
  if (mode === 'train') {
    return (
      (await routeViaGoogleDirections(segPoints, { mode, googleMode: 'transit' })) ??
      (await routeViaOpenRouteService(segPoints, 'rail', mode)) ??
      (await routeViaOpenRouteService(segPoints, 'driving-car', mode)) ??
      (await routeViaGoogleDirections(segPoints, { mode: 'car', googleMode: 'driving' }))
    )
  }
  if (mode === 'walk') {
    return (await routeViaGoogleDirections(segPoints, { mode, googleMode: 'walking' })) ?? (await routeViaOpenRouteService(segPoints, 'foot-walking', mode))
  }
  if (mode === 'bike') {
    return (
      (await routeViaGoogleDirections(segPoints, { mode, googleMode: 'bicycling', avoidHighways: true, avoidTolls: true })) ??
      (await routeViaOpenRouteService(segPoints, 'cycling', mode)) ??
      (await routeViaOpenRouteService(segPoints, 'cycling-regular', mode)) ??
      (await routeViaOsrm(segPoints, 'cycling', mode)) ??
      (await routeViaGoogleDirections(segPoints, { mode, googleMode: 'driving', avoidHighways: true, avoidTolls: true }))
    )
  }
  if (mode === 'hiking') {
    // 'trails' prefers the in-app Overpass trail graph so the route snaps to the trails drawn on the map;
    // if the graph can't connect the anchors, fall through to a real foot-routing engine.
    if (segType === 'trails') {
      const trail = await routeViaTrailGraph(segPoints, mode)
      if (trail) return trail
      console.debug(`hikingRoute trail_graph_null falling_back_to_engine points=${segPoints.length}`)
    }
    if (config.openRouteServiceApiKey) {
      const r = (await routeViaOpenRouteService(segPoints, 'foot-hiking', mode)) ?? (await routeViaOpenRouteService(segPoints, 'foot-walking', mode))
      if (r) return r
    }
    if (config.graphHopperApiKey) {
      const r = await routeViaGraphHopperHiking(segPoints)
      if (r) return r
    }
    return routeViaTrailGraph(segPoints, mode)
  }
  if (mode === 'portaging') {
    const network = await routeViaPortageGraph(segPoints)
    if (network) return network
    console.debug(`portageRoute unavailable_after_network_only points=${segPoints.length}`)
    return null
  }
  return routeViaGoogleDirections(segPoints, { mode: 'car', googleMode: 'driving' })
}

// ---- memoization (20 minute TTL, in-flight de-dupe) ----
const ROUTE_TTL_MS = 20 * 60 * 1000
const routeCache = new Map<string, { at: number; route: RouteComputation }>()
const inFlight = new Map<string, Promise<RouteComputation | null>>()

export function normalizeSegmentRoutingTypeFor(raw: string, mode: string): string {
  const m = normalizeMapMode(mode)
  if (raw.trim().toLowerCase() === 'direct') return 'direct'
  if (m === 'hiking') return 'trails'
  if (m === 'portaging') return 'waterway'
  return 'calculated'
}

export function segmentRouteCacheKey(mode: string, segType: string, segPoints: PointMap[]): string {
  return `${normalizeMapMode(mode)}|${segType.trim().toLowerCase()}|${segPoints.map((p) => `${latOf(p).toFixed(6)},${lonOf(p).toFixed(6)};`).join('')}`
}

export async function calculateRouteForSegment(opts: { segmentIndex: number; segPoints: PointMap[]; mode: string; segType: string }): Promise<RouteComputation | null> {
  const mode = normalizeMapMode(opts.mode)
  const segType = normalizeSegmentRoutingTypeFor(opts.segType, mode)
  if (segType === 'direct' || mode === 'plane') return calculateUncached(opts.segPoints, mode, segType)

  const key = `${opts.segmentIndex}|${segmentRouteCacheKey(mode, segType, opts.segPoints)}`
  const cached = routeCache.get(key)
  if (cached && Date.now() - cached.at <= ROUTE_TTL_MS) return cached.route
  const pending = inFlight.get(key)
  if (pending) return pending

  const p = calculateUncached(opts.segPoints, mode, segType)
  inFlight.set(key, p)
  try {
    const route = await p
    if (route) routeCache.set(key, { at: Date.now(), route })
    return route
  } finally {
    if (inFlight.get(key) === p) inFlight.delete(key)
  }
}

export function segmentRouteTimeoutMs(mode: string): number {
  switch (normalizeMapMode(mode)) {
    case 'portaging': return 24000
    case 'hiking': return 22000
    case 'train': return 14000
    case 'walk':
    case 'bike': return 12000
    default: return 18000
  }
}

export { haversineMeters }
