import { standardRouteColor } from '@/components/map/mapStyles'
import {
  diversifyTrailCandidatesByComponent, graphComponents, graphForLines, nearestProjectionOnLine, nearestTrailCandidatesAdaptive,
  reconstructNodePath, selectGraphLinesForAnchors, shortestTrailPath, shortestTrailTreeFromSource, sliceLineBetweenProjections,
  type TrailCandidate,
} from './graph'
import { distanceLineToPathMeters, haversineMeters, pathDistanceMeters, type LL } from './geo'
import { getHikingOverlayEntry, hikingCacheKey, routeBoundsCenter, routeFocusPadDegrees, trailRoutePadDegreesForMode, type HikingOverlayEntry } from './overlayData'
import { latOf, lonOf, type PointMap, type RouteComputation } from './types'

export function fastTrailRouteAlongSameLine(opts: {
  start: LL; end: LL; trailLines: LL[][]; maxAnchorMeters?: number; maxLineDistanceMeters?: number; maxTotalMeters?: number
}): { path: LL[]; distanceMeters: number } | null {
  const maxAnchor = opts.maxAnchorMeters ?? 1200
  const maxLineDist = opts.maxLineDistanceMeters ?? 1600
  const maxTotal = opts.maxTotalMeters ?? 36000
  const direct = haversineMeters(opts.start, opts.end)
  if (!Number.isFinite(direct) || direct <= 0) return null

  let best: { path: LL[]; distanceMeters: number } | null = null
  for (const line of opts.trailLines) {
    if (line.length < 2) continue
    const lineDistance = distanceLineToPathMeters(line, [opts.start, opts.end], 8)
    if (!Number.isFinite(lineDistance) || lineDistance > maxLineDist) continue
    const sp = nearestProjectionOnLine(opts.start, line, maxAnchor)
    if (!sp) continue
    const ep = nearestProjectionOnLine(opts.end, line, maxAnchor)
    if (!ep) continue
    const linePath = sliceLineBetweenProjections(line, sp, ep)
    if (linePath.length < 2) continue

    const full: LL[] = []
    const add = (p: LL) => {
      const last = full[full.length - 1]
      if (last && Math.abs(last.lat - p.lat) < 1e-7 && Math.abs(last.lng - p.lng) < 1e-7) return
      full.push(p)
    }
    add(opts.start)
    linePath.forEach(add)
    add(opts.end)
    const total = pathDistanceMeters(full)
    if (!Number.isFinite(total) || total <= 0) continue
    if (total > maxTotal) continue
    if (total > Math.max(direct * 4.5, direct + 5000)) continue
    if (!best || total < best.distanceMeters) best = { path: full, distanceMeters: total }
  }
  return best
}

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

function solveWithEntry(anchors: LL[], mode: string, entry: HikingOverlayEntry, graphCacheKey: string): RouteComputation | null {
  if (!entry.trailLines.length) return null
  const routeTrailLines = selectGraphLinesForAnchors(entry.trailLines, anchors, {
    maxLines: mode === 'portaging' ? 900 : 700, bboxPadDegrees: mode === 'portaging' ? 0.06 : 0.04, debugLabel: 'trailRoute',
  })
  if (!routeTrailLines.length) return null

  if (anchors.length === 2) {
    const same = fastTrailRouteAlongSameLine({
      start: anchors[0], end: anchors[1], trailLines: routeTrailLines,
      maxAnchorMeters: mode === 'portaging' ? 1600 : 1200, maxLineDistanceMeters: mode === 'portaging' ? 2200 : 1600, maxTotalMeters: mode === 'portaging' ? 42000 : 36000,
    })
    if (same) {
      return {
        path: same.path, distanceMeters: same.distanceMeters, durationSeconds: same.distanceMeters / 1.2, color: standardRouteColor(mode),
        width: 6, zIndex: 26, instructions: [`Trail-aligned route (${(same.distanceMeters / 1000).toFixed(1)} km)`], stepDetails: [],
      }
    }
  }

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
          const score = s.meters + gm + e.meters
          if (score < bestScore) {
            bestScore = score
            bestPath = { nodePath, meters: gm }
            bestStart = s
            bestEnd = e
          }
        }
      }
    }
    consider(startC, endC)
    const directMeters = haversineMeters(start, end)
    if (!bestPath || (directMeters > 1200 && bestScore > directMeters * detourRetry)) {
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

export async function routeViaTrailGraph(segPoints: PointMap[], modeContext = 'hiking'): Promise<RouteComputation | null> {
  if (segPoints.length < 2) return null
  const anchors: LL[] = segPoints.map((p) => ({ lat: latOf(p), lng: lonOf(p) }))
  const mode = modeContext === 'portaging' ? 'portaging' : 'hiking'

  const attempted = new Set<string>()
  const pads = [trailRoutePadDegreesForMode(mode), trailRoutePadDegreesForMode(mode, true)]
  for (let i = 0; i < pads.length; i++) {
    const pad = pads[i]
    const cacheKey = hikingCacheKey(anchors, pad)
    if (!attempted.add(cacheKey)) continue
    const entry = await getHikingOverlayEntry({ cacheKey, routePath: anchors, padDegrees: pad })
    const solved = entry ? solveWithEntry(anchors, mode, entry, `trail_route:${mode}:${cacheKey}:pad=${pad.toFixed(2)}`) : null
    if (solved) {
      if (i > 0) console.debug(`trailRoute expanded_bbox_success mode=${mode} pad=${pad.toFixed(2)}`)
      return solved
    }
  }

  const focusPad = routeFocusPadDegrees(anchors, {
    minPad: mode === 'portaging' ? 0.12 : 0.1, maxPad: mode === 'portaging' ? 0.24 : 0.2, edgePadding: mode === 'portaging' ? 0.08 : 0.06,
  })
  const attemptedFocus = new Set<string>()
  for (const focus of [routeBoundsCenter(anchors), anchors[anchors.length - 1], anchors[0]]) {
    const cacheKey = hikingCacheKey([focus], focusPad)
    if (!attemptedFocus.add(cacheKey)) continue
    const entry = await getHikingOverlayEntry({ cacheKey, routePath: [focus], padDegrees: focusPad })
    const solved = entry ? solveWithEntry(anchors, mode, entry, `trail_route:${mode}:${cacheKey}:focus=${focusPad.toFixed(2)}`) : null
    if (solved) {
      console.debug(`trailRoute focus_bbox_success mode=${mode}`)
      return solved
    }
  }
  return null
}
