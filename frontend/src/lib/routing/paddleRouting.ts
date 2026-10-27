import { PORTAGE_CARRY_COLOR, standardRouteColor } from '@/components/map/mapStyles'
import { PADDLE_KMH } from '@/lib/tripBuilder'
import type { StepDetail } from '@/services/directions'
import { lerpLL, type LL } from './geo'
import { cachedPortagingEntries, getPortagingOverlayEntry, portagingFocusCacheKey, type Bounds, type PortagingOverlayEntry } from './overlayData'
import { latOf, lonOf, type PointMap, type RouteComputation } from './types'
import { routeOverWater, waterRouteBounds, type WaterRun } from './waterRouter'

/**
 * Same pad as the map's beginner overlay fetch around a stop, so a leg starting at the active stop reuses the
 * overlay's entry (and the backend's Overpass cache) instead of costing a new upstream query.
 */
const FETCH_PAD_DEGREES = 0.14
const MAX_FETCHES = 3
/** Legs mostly over unmapped land mean the water data has a hole; the drawn line is more honest than a bushwhack. */
const MAX_CARRY_SHARE = 0.5

const inside = (b: Bounds, p: LL, margin = 0) =>
  p.lat >= b.south + margin && p.lat <= b.north - margin && p.lng >= b.west + margin && p.lng <= b.east - margin
const overlaps = (a: Bounds, b: Bounds) => a.north >= b.south && a.south <= b.north && a.east >= b.west && a.west <= b.east

/**
 * Only the stops and bend points must sit inside fetched data: each fetch spans ~30 km around its focus, so the
 * water between covered points is nearly always loaded too. Asking for more would hold the route hostage to
 * Overpass, whose mirrors can take a minute to fail.
 */
async function waterEntriesFor(points: LL[]): Promise<PortagingOverlayEntry[]> {
  const covered = (p: LL) => cachedPortagingEntries().some((e) => inside(e.bounds!, p, 0.01))
  for (let fetches = 0; fetches < MAX_FETCHES; fetches++) {
    const missing = points.filter((p) => !covered(p))
    if (!missing.length) break
    // Prefer a stop as the fetch focus (it matches the overlay's own fetches); take whichever covers the most.
    const candidates = [...points, lerpLL(points[0], points[points.length - 1], 0.5)]
    const reach = (c: LL) => missing.filter((p) => Math.abs(p.lat - c.lat) < FETCH_PAD_DEGREES - 0.01 && Math.abs(p.lng - c.lng) < FETCH_PAD_DEGREES - 0.01).length
    const focus = candidates.reduce((best, c) => (reach(c) > reach(best) ? c : best), missing[0])
    const entry = await getPortagingOverlayEntry({ cacheKey: portagingFocusCacheKey(focus, FETCH_PAD_DEGREES), anchors: [focus], focusPoint: focus, padDegrees: FETCH_PAD_DEGREES })
    if (!entry) break
  }
  const area = waterRouteBounds(points)
  return cachedPortagingEntries().filter((e) => overlaps(e.bounds!, area))
}

const formatMeters = (m: number) => (m >= 1000 ? `${(m / 1000).toFixed(1)} km` : `${Math.max(10, Math.round(m / 10) * 10)} m`)

function runLabel(run: WaterRun): { tab: string; headline: string } {
  if (run.kind === 'paddle') return { tab: 'Paddle', headline: `Paddle ${formatMeters(run.meters)}` }
  if (run.kind === 'portage') return { tab: 'Portage', headline: `Portage ${formatMeters(run.meters)}` }
  return { tab: 'Carry', headline: `Carry ${formatMeters(run.meters)} (no mapped portage)` }
}

/** Paddle route along mapped lakes, rivers and portages; null when there is no usable water data for the leg. */
export async function routeViaWaterNetwork(segPoints: PointMap[]): Promise<RouteComputation | null> {
  const points = segPoints.map((p) => ({ lat: latOf(p), lng: lonOf(p) })).filter((p) => Number.isFinite(p.lat) && Number.isFinite(p.lng))
  if (points.length < 2) return null
  const entries = await waterEntriesFor(points)
  const started = performance.now()
  const route = routeOverWater(points, entries)
  if (!route) {
    console.debug(`paddleRoute no_water_data points=${points.length} entries=${entries.length}`)
    return null
  }
  const carry = route.runs.filter((r) => r.kind === 'carry').reduce((t, r) => t + r.meters, 0)
  console.debug(`paddleRoute ok km=${(route.meters / 1000).toFixed(2)} runs=${route.runs.length} carry_m=${Math.round(carry)} entries=${entries.length} ms=${Math.round(performance.now() - started)}`)
  if (carry > route.meters * MAX_CARRY_SHARE) return null

  const paddleColor = standardRouteColor('portaging')
  const steps: StepDetail[] = route.runs.map((run) => {
    const { tab, headline } = runLabel(run)
    const mid = run.path[Math.floor(run.path.length / 2)]
    return {
      mode: run.kind, tabLabel: tab, headline, lineColor: run.kind === 'paddle' ? paddleColor : PORTAGE_CARRY_COLOR,
      focusLat: mid.lat, focusLon: mid.lng, focusZoom: run.kind === 'paddle' ? 13 : 15,
    }
  })
  return {
    path: route.path,
    distanceMeters: route.meters,
    durationSeconds: (route.meters / 1000 / PADDLE_KMH) * 3600,
    color: paddleColor,
    width: 5,
    zIndex: 18,
    styledSegments: route.runs.map((run) => ({
      path: run.path,
      color: run.kind === 'paddle' ? paddleColor : PORTAGE_CARRY_COLOR,
      width: run.kind === 'paddle' ? 5 : 6,
      zIndex: run.kind === 'paddle' ? 18 : 19,
    })),
    instructions: steps.map((s) => s.headline),
    stepDetails: steps,
  }
}
