import { standardRouteColor } from '@/components/map/mapStyles'
import {
  diversifyTrailCandidatesByComponent, graphComponents, graphForLines, nearestTrailCandidatesAdaptive, reconstructNodePath,
  selectGraphLinesForAnchors, shortestTrailPath, shortestTrailTreeFromSource, type TrailCandidate,
} from './graph'
import { haversineMeters, pathSignature, type LL } from './geo'
import { boundsAround, loadHikingArea, type HikingOverlayEntry } from './overlayData'
import { latOf, lonOf, type PointMap, type RouteComputation } from './types'

export function anchorConnectorLimitMeters(mode: string): number {
  switch (mode) {
    case 'portaging': return 320
    case 'hiking': return 900
    case 'walk': return 700
    default: return 800
  }
}

export function waypointShouldUseAnchor(opts: { anchorIndex: number; anchorCount: number; connectorLimitMeters: number; startConnectors: number[]; endConnectors: number[] }): boolean {
  const { anchorIndex, anchorCount, connectorLimitMeters, startConnectors, endConnectors } = opts
  if (anchorCount <= 0) return false
  if (anchorIndex <= 0) return startConnectors.length > 0 && startConnectors[0] <= connectorLimitMeters
  if (anchorIndex >= anchorCount - 1) return endConnectors.length > 0 && endConnectors[endConnectors.length - 1] <= connectorLimitMeters
  const prev = anchorIndex - 1, next = anchorIndex
  if (prev < 0 || prev >= endConnectors.length || next < 0 || next >= startConnectors.length) return false
  return endConnectors[prev] <= connectorLimitMeters && startConnectors[next] <= connectorLimitMeters
}

interface LegSolution {
  start: LL; end: LL; startCandidate: TrailCandidate; endCandidate: TrailCandidate; nodePath: number[]; graphMeters: number
}

/**
 * Off-trail meters (stop to trail) count this many times trail meters when choosing where a leg joins the
 * network, so it walks the trail to the point nearest the stop instead of cutting through the bush to save distance.
 */
const OFF_TRAIL_WEIGHT = 3

function solveWithEntry(anchors: LL[], mode: string, entry: HikingOverlayEntry): RouteComputation | null {
  if (!entry.trailLines.length) return null
  const routeTrailLines = selectGraphLinesForAnchors(entry.trailLines, anchors, {
    maxLines: mode === 'portaging' ? 900 : 700, bboxPadDegrees: mode === 'portaging' ? 0.06 : 0.04, debugLabel: 'trailRoute',
  })
  if (!routeTrailLines.length) return null
  // The selection depends on the stops only when the area has more trails than the graph takes.
  const selection = routeTrailLines.length === entry.trailLines.length ? 'all' : pathSignature(anchors, anchors.length)
  const graphCacheKey = `trail_route:${mode}:${entry.key}:${selection}`

  const graph = graphForLines(routeTrailLines, { cacheKey: graphCacheKey, bridgeToleranceMeters: mode === 'portaging' ? 280 : 180 })
  const { nodes, adjacency, spatialIndex } = graph
  if (nodes.length < 2) return null
  if (nodes.length > 26000) {
    console.debug(`trailRoute skipped_too_large nodes=${nodes.length}`)
    return null
  }
  const comps = graphComponents(adjacency)
  const connectorLimit = anchorConnectorLimitMeters(mode)
  const radii = mode === 'portaging' ? [4000, 8000, 14000, 25000] : [3000, 6000, 10000, 18000]
  const expandedRadii = mode === 'portaging' ? [5000, 9000, 16000, 26000, 36000] : [4000, 8000, 14000, 22000, 30000]
  const globalCap = mode === 'portaging' ? 13000 : 9000
  const expandedGlobalCap = mode === 'portaging' ? 22000 : 16000
  const detourRetry = mode === 'portaging' ? 7.5 : 5
  const nearbyComp = mode === 'portaging' ? 4200 : 2600
  const expandedNearbyComp = mode === 'portaging' ? 7000 : 4500

  const legs: LegSolution[] = []
  for (let leg = 0; leg + 1 < anchors.length; leg++) {
    const start = anchors[leg], end = anchors[leg + 1]
    const candidatesFor = (target: LL, limit: number, rad: number[], cap: number, nearby: number, maxNew?: number) =>
      diversifyTrailCandidatesByComponent({
        anchor: target,
        baseCandidates: nearestTrailCandidatesAdaptive(target, nodes, { spatialIndex, limit, radiiMeters: rad, maxGlobalFallbackMeters: cap }),
        nodes, spatialIndex, componentIds: comps.componentIds, componentSizes: comps.componentSizes, limit, nearbyRadiusMeters: nearby, maxNewComponents: maxNew,
      })
    const startC = candidatesFor(start, 6, radii, globalCap, nearbyComp)
    const endC = candidatesFor(end, 6, radii, globalCap, nearbyComp)
    if (!startC.length || !endC.length) return null

    let bestPath: { nodePath: number[]; meters: number } | null = null
    let bestStart: TrailCandidate | null = null
    let bestEnd: TrailCandidate | null = null
    let bestScore = Infinity
    let bestMeters = Infinity
    const treeCache = new Map<number, { dist: number[]; prev: number[] }>()
    const consider = (starts: TrailCandidate[], ends: TrailCandidate[]) => {
      if (!starts.length || !ends.length) return
      for (const s of starts) {
        let tree = treeCache.get(s.index)
        if (!tree) treeCache.set(s.index, (tree = shortestTrailTreeFromSource(s.index, adjacency)))
        for (const e of ends) {
          const gm = tree.dist[e.index]
          if (!Number.isFinite(gm)) continue
          const nodePath = reconstructNodePath(s.index, e.index, tree.prev)
          if (!nodePath || !nodePath.length) continue
          const score = (s.meters + e.meters) * OFF_TRAIL_WEIGHT + gm
          if (score < bestScore) {
            bestScore = score
            bestMeters = s.meters + gm + e.meters
            bestPath = { nodePath, meters: gm }
            bestStart = s
            bestEnd = e
          }
        }
      }
    }
    consider(startC, endC)
    const directMeters = haversineMeters(start, end)
    if (!bestPath || (directMeters > 1200 && bestMeters > directMeters * detourRetry)) {
      const es = candidatesFor(start, 14, expandedRadii, expandedGlobalCap, expandedNearbyComp, 5)
      const ee = candidatesFor(end, 14, expandedRadii, expandedGlobalCap, expandedNearbyComp, 5)
      if (es.length && ee.length) consider(es, ee)
    }
    if (!bestPath || !bestStart || !bestEnd) return null
    legs.push({ start, end, startCandidate: bestStart, endCandidate: bestEnd, nodePath: (bestPath as any).nodePath, graphMeters: (bestPath as any).meters })
  }
  if (!legs.length) return null

  const startConnectors = legs.map((l) => l.startCandidate.meters)
  const endConnectors = legs.map((l) => l.endCandidate.meters)
  const path: LL[] = []
  const add = (p: LL) => {
    const last = path[path.length - 1]
    if (last && Math.abs(last.lat - p.lat) < 1e-7 && Math.abs(last.lng - p.lng) < 1e-7) return
    path.push(p)
  }
  let totalMeters = 0
  for (let li = 0; li < legs.length; li++) {
    const leg = legs[li]
    const includeStart = waypointShouldUseAnchor({ anchorIndex: li, anchorCount: anchors.length, connectorLimitMeters: connectorLimit, startConnectors, endConnectors })
    const includeEnd = waypointShouldUseAnchor({ anchorIndex: li + 1, anchorCount: anchors.length, connectorLimitMeters: connectorLimit, startConnectors, endConnectors })
    if (li === 0) {
      add(includeStart ? leg.start : nodes[leg.startCandidate.index])
    } else {
      const prevEnd = legs[li - 1].endCandidate.index
      const curStart = leg.startCandidate.index
      if (includeStart) add(leg.start)
      else if (prevEnd !== curStart) {
        const bridge = shortestTrailPath(prevEnd, curStart, adjacency)
        if (!bridge || !bridge.nodePath.length) return null
        for (const idx of bridge.nodePath) add(nodes[idx])
        totalMeters += bridge.meters
      } else add(nodes[curStart])
    }
    if (includeStart) totalMeters += leg.startCandidate.meters
    for (const idx of leg.nodePath) add(nodes[idx])
    totalMeters += leg.graphMeters
    if (includeEnd) {
      add(leg.end)
      totalMeters += leg.endCandidate.meters
    }
  }
  if (path.length < 2) return null
  const label = mode === 'portaging' ? 'Portage-trail route' : 'Trail-network route'
  return {
    path, distanceMeters: totalMeters, durationSeconds: totalMeters / 1.2, color: standardRouteColor(mode), width: 6, zIndex: 26,
    instructions: [`${label} (${(totalMeters / 1000).toFixed(1)} km)`], stepDetails: [],
  }
}

/** Pads (degrees) around a leg's stops for the trails it may use; the wider one is tried when the closer trails don't connect. */
const TRAIL_ROUTE_PADS = [0.04, 0.12]

export async function routeViaTrailGraph(segPoints: PointMap[], modeContext = 'hiking'): Promise<RouteComputation | null> {
  if (segPoints.length < 2) return null
  const anchors: LL[] = segPoints.map((p) => ({ lat: latOf(p), lng: lonOf(p) }))
  const mode = modeContext === 'portaging' ? 'portaging' : 'hiking'
  let triedKey = ''
  for (const pad of TRAIL_ROUTE_PADS) {
    const entry = await loadHikingArea(boundsAround(anchors, pad)!)
    if (!entry || entry.key === triedKey) continue
    triedKey = entry.key
    const solved = solveWithEntry(anchors, mode, entry)
    if (solved) return solved
    console.debug(`trailRoute unsolved mode=${mode} pad=${pad} tiles=${entry.key} missing=${entry.missingTiles}`)
  }
  return null
}
