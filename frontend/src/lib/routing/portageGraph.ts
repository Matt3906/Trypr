import { PORTAGE_CARRY_COLOR, standardRouteColor } from '@/components/map/mapStyles'
import {
  distanceLineToPathMeters, distanceMetersToPath, downsampleLine, haversineMeters, lerpLL, pathDistanceMeters, pointInPolygon, projectOnSegment, type LL,
} from './geo'
import {
  graphComponents, graphForLines, nearestProjectionOnLine, nearestTrailCandidatesAdaptive, reconstructNodePath, selectGraphLinesForAnchors,
  shortestTrailTreeFromSource, sliceLineBetweenProjections, trailNodeKey, TrailSpatialIndex, type TrailEdge,
} from './graph'
import { hasAvailableOverpassEndpoint } from './overpass'
import {
  adaptivePortageRoutePadDegrees, getPortagingOverlayEntry, portageState, portagingCacheRef, portagingFocusCacheKey, portagingOverlayFocusPoints,
  portagingRouteCacheKey, routeBoundsCenter, routeFocusPadDegrees, type PortagingOverlayEntry,
} from './overlayData'
import { latOf, lonOf, type PointMap, type RouteComputation, type StyledRouteSegment } from './types'

// ---------------- water predicates ----------------
function nearestDistanceToLinesMeters(point: LL, lines: LL[][]): number {
  if (!lines.length) return Infinity
  let best = Infinity
  for (const line of lines) {
    if (!line.length) continue
    const m = distanceMetersToPath(point, line)
    if (m < best) best = m
    if (best <= 1) break
  }
  return best
}

export function isLikelyWaterPoint(point: LL, entry: PortagingOverlayEntry, lineThresholdMeters = 140): boolean {
  for (const poly of entry.waterPolygons) if (pointInPolygon(point, poly)) return true
  if (nearestDistanceToLinesMeters(point, entry.waterLines) <= lineThresholdMeters) return true
  return nearestDistanceToLinesMeters(point, entry.portageLines) <= 40
}

function isOpenWaterLandingPoint(point: LL, entry: PortagingOverlayEntry, lineThresholdMeters = 90): boolean {
  for (const poly of entry.waterPolygons) if (pointInPolygon(point, poly)) return true
  return nearestDistanceToLinesMeters(point, entry.waterLines) <= lineThresholdMeters
}

export function isWaterSafeDirectSegment(from: LL, to: LL, entry: PortagingOverlayEntry, maxSamples = 40): boolean {
  const direct = haversineMeters(from, to)
  if (!Number.isFinite(direct) || direct <= 1) return true
  if (!isLikelyWaterPoint(from, entry, 170)) return false
  const sampleCount = Math.max(6, Math.min(maxSamples, Math.round(direct / 120)))
  for (let i = 0; i <= sampleCount; i++) {
    const p = lerpLL(from, to, i / sampleCount)
    if (!isLikelyWaterPoint(p, entry, i === sampleCount ? 230 : 145)) return false
  }
  return true
}

function isValidPortageConnectorToGraphAnchor(opts: { anchor: LL; graphAnchor: LL; entry: PortagingOverlayEntry; allowAccessStraightToWater: boolean }): boolean {
  const { anchor, graphAnchor, entry } = opts
  const meters = haversineMeters(anchor, graphAnchor)
  if (!Number.isFinite(meters) || meters < 0) return false
  if (meters <= 6) return true
  if (isLikelyWaterPoint(anchor, entry, 120)) return isWaterSafeDirectSegment(anchor, graphAnchor, entry, 18)
  if (!opts.allowAccessStraightToWater && isLikelyWaterPoint(graphAnchor, entry, 90) && meters <= 80) return true
  if (!opts.allowAccessStraightToWater) return false
  if (!isOpenWaterLandingPoint(graphAnchor, entry)) return false
  return meters <= 1200
}

const isLikelyWaterEndpointForPortage = (point: LL, entry: PortagingOverlayEntry) => {
  for (const poly of entry.waterPolygons) if (pointInPolygon(point, poly)) return true
  return nearestDistanceToLinesMeters(point, entry.waterLines) <= 240
}

function trimPortagingPathToWaterOffRamp(opts: { path: LL[]; destination: LL; entry: PortagingOverlayEntry }): { path: LL[]; distanceMeters: number } | null {
  const { path, destination, entry } = opts
  if (path.length < 2) return null
  const original = pathDistanceMeters(path)
  if (!Number.isFinite(original) || original <= 0) return null

  let traversed = 0
  let bestSeg = -1
  let bestOff: LL | null = null
  let bestOffToDest = Infinity
  let bestPrefix = -Infinity
  for (let i = 0; i + 1 < path.length; i++) {
    const a = path[i], b = path[i + 1]
    const segMeters = haversineMeters(a, b)
    if (!Number.isFinite(segMeters) || segMeters <= 0.1) continue
    const off = projectOnSegment(destination, a, b)
    const offToDest = haversineMeters(off, destination)
    const prefix = traversed + haversineMeters(a, off)
    const remaining = original - prefix
    traversed += segMeters
    if (remaining < 50) continue
    if (!isWaterSafeDirectSegment(off, destination, entry)) continue
    const better = offToDest + 0.5 < bestOffToDest || (Math.abs(offToDest - bestOffToDest) <= 0.5 && prefix > bestPrefix)
    if (!better) continue
    bestSeg = i; bestOff = off; bestOffToDest = offToDest; bestPrefix = prefix
  }
  if (bestSeg < 0 || !bestOff) return null

  const trimmed: LL[] = []
  const add = (p: LL) => {
    const last = trimmed[trimmed.length - 1]
    if (last && Math.abs(last.lat - p.lat) < 1e-7 && Math.abs(last.lng - p.lng) < 1e-7) return
    trimmed.push(p)
  }
  for (let i = 0; i <= bestSeg; i++) add(path[i])
  add(bestOff)
  add(destination)
  const trimmedMeters = pathDistanceMeters(trimmed)
  if (!Number.isFinite(trimmedMeters) || trimmedMeters <= 0) return null
  if (original - trimmedMeters < 80) return null
  return { path: trimmed, distanceMeters: trimmedMeters }
}

// ---------------- same-line + candidates ----------------
function fastPortageRouteAlongSameLine(opts: {
  start: LL; end: LL; waterLines: LL[][]; portageLines: LL[][]; entry: PortagingOverlayEntry
  maxAnchorMeters?: number; maxLineDistanceMeters?: number; maxTotalMeters?: number
}): { path: LL[]; distanceMeters: number; lineKind: string } | null {
  const maxAnchor = opts.maxAnchorMeters ?? 2200
  const maxLineDist = opts.maxLineDistanceMeters ?? 2800
  const maxTotal = opts.maxTotalMeters ?? 42000
  const direct = haversineMeters(opts.start, opts.end)
  if (!Number.isFinite(direct) || direct <= 0) return null

  let best: { path: LL[]; distanceMeters: number; lineKind: string } | null = null
  for (const source of [{ kind: 'water', lines: opts.waterLines }, { kind: 'portage', lines: opts.portageLines }]) {
    for (const line of source.lines) {
      if (line.length < 2) continue
      const ld = distanceLineToPathMeters(line, [opts.start, opts.end], 8)
      if (!Number.isFinite(ld) || ld > maxLineDist) continue
      const sp = nearestProjectionOnLine(opts.start, line, maxAnchor)
      if (!sp) continue
      const ep = nearestProjectionOnLine(opts.end, line, maxAnchor)
      if (!ep) continue
      if (sp.anchorMeters > 40 && !isWaterSafeDirectSegment(opts.start, sp.point, opts.entry, 14)) continue
      if (ep.anchorMeters > 40 && !isWaterSafeDirectSegment(ep.point, opts.end, opts.entry, 14)) continue
      const linePath = sliceLineBetweenProjections(line, sp, ep)
      if (linePath.length < 2) continue
      const full: LL[] = []
      const add = (p: LL) => {
        const last = full[full.length - 1]
        if (last && Math.abs(last.lat - p.lat) < 1e-7 && Math.abs(last.lng - p.lng) < 1e-7) return
        full.push(p)
      }
      add(opts.start); linePath.forEach(add); add(opts.end)
      const total = pathDistanceMeters(full)
      if (!Number.isFinite(total) || total <= 0 || total > maxTotal) continue
      if (total > Math.max(direct * 4, direct + 6000)) continue
      if (!best || total < best.distanceMeters) best = { path: full, distanceMeters: total, lineKind: source.kind }
    }
  }
  return best
}

interface PortageCandidate { index: number; searchMeters: number; connectorMeters: number; graphAnchor: LL; usedAccess: boolean }
const totalConnector = (c: PortageCandidate) => c.connectorMeters + c.searchMeters
interface ResolvedAnchor { graphAnchor: LL; connectorMeters: number; usedAccess: boolean }

function portageConnectorScore(m: number): number {
  if (!Number.isFinite(m) || m < 0) return Infinity
  if (m <= 80) return m
  if (m <= 200) return m * 1.3
  if (m <= 400) return m * 2.4
  if (m <= 800) return m * 4.5
  return m * 8
}

const comparePortageCandidates = (a: PortageCandidate, b: PortageCandidate): number => {
  const t = totalConnector(a) - totalConnector(b)
  if (t) return t
  const c = a.connectorMeters - b.connectorMeters
  if (c) return c
  const s = a.searchMeters - b.searchMeters
  if (s) return s
  if (a.usedAccess !== b.usedAccess) return a.usedAccess ? 1 : -1
  return a.index - b.index
}

function mergeCandidateGroups(groups: PortageCandidate[][], softLimit = 12): PortageCandidate[] {
  const byIndex = new Map<number, PortageCandidate>()
  for (const g of groups) for (const c of g) {
    const ex = byIndex.get(c.index)
    if (!ex || comparePortageCandidates(c, ex) < 0) byIndex.set(c.index, c)
  }
  const merged = [...byIndex.values()].sort(comparePortageCandidates)
  return softLimit > 0 && merged.length > softLimit ? merged.slice(0, softLimit) : merged
}

function snapPortageCandidatesToSegments(opts: {
  anchor: LL; lines: LL[][]; nodeIndexByKey: Map<string, number>; entry: PortagingOverlayEntry; limit: number
  maxAnchorMeters?: number; maxLineDistanceMeters?: number; maxAlongSegmentMeters?: number; maxSegmentsToScan?: number; deadline?: number; debugLabel?: string
  resolvedAnchor?: ResolvedAnchor
}): PortageCandidate[] {
  const { anchor, lines, nodeIndexByKey, entry, limit } = opts
  if (!lines.length || !nodeIndexByKey.size || limit <= 0) return []
  const maxAnchor = opts.maxAnchorMeters ?? 12000
  const maxLineDist = opts.maxLineDistanceMeters ?? 14000
  const maxAlong = opts.maxAlongSegmentMeters ?? 22000
  const byIndex = new Map<number, PortageCandidate>()
  let scanned = 0
  let timedOut = false

  const scanSource = (source: LL, baseConnector: number, usedAccess: boolean) => {
    const shortlisted: { line: LL[]; distance: number }[] = []
    for (const line of lines) {
      if (line.length < 2) continue
      const d = distanceMetersToPath(source, line)
      if (!Number.isFinite(d) || d > maxLineDist) continue
      shortlisted.push({ line, distance: d })
    }
    shortlisted.sort((a, b) => a.distance - b.distance)
    const lineCap = Math.min(shortlisted.length, Math.max(limit * 2, 12))
    for (let li = 0; li < shortlisted.length && li < lineCap; li++) {
      if (opts.deadline != null && (li & 3) === 0 && Date.now() > opts.deadline) { timedOut = true; break }
      const line = shortlisted[li].line
      for (let i = 0; i + 1 < line.length; i++) {
        scanned++
        if (opts.maxSegmentsToScan != null && scanned > opts.maxSegmentsToScan) { timedOut = true; break }
        if (opts.deadline != null && (scanned & 127) === 0 && Date.now() > opts.deadline) { timedOut = true; break }
        const a = line[i], b = line[i + 1]
        const si = nodeIndexByKey.get(trailNodeKey(a))
        const ei = nodeIndexByKey.get(trailNodeKey(b))
        if (si == null || ei == null) continue
        const projected = projectOnSegment(source, a, b)
        const toProjected = haversineMeters(source, projected)
        if (!Number.isFinite(toProjected) || toProjected > maxAnchor) continue
        if (!isValidPortageConnectorToGraphAnchor({ anchor: source, graphAnchor: projected, entry, allowAccessStraightToWater: usedAccess })) continue
        const toStart = haversineMeters(projected, a)
        if (Number.isFinite(toStart) && toStart <= maxAlong) {
          const cand: PortageCandidate = { index: si, searchMeters: toStart, connectorMeters: baseConnector + toProjected, graphAnchor: projected, usedAccess }
          const ex = byIndex.get(si)
          if (!ex || comparePortageCandidates(cand, ex) < 0) byIndex.set(si, cand)
        }
        const toEnd = haversineMeters(projected, b)
        if (Number.isFinite(toEnd) && toEnd <= maxAlong) {
          const cand: PortageCandidate = { index: ei, searchMeters: toEnd, connectorMeters: baseConnector + toProjected, graphAnchor: projected, usedAccess }
          const ex = byIndex.get(ei)
          if (!ex || comparePortageCandidates(cand, ex) < 0) byIndex.set(ei, cand)
        }
      }
      if (timedOut) break
    }
  }

  scanSource(anchor, 0, false)
  if (opts.resolvedAnchor?.usedAccess) scanSource(opts.resolvedAnchor.graphAnchor, opts.resolvedAnchor.connectorMeters, true)
  if (timedOut && opts.debugLabel) console.debug(`${opts.debugLabel} partial_results candidates=${byIndex.size} segments_scanned=${scanned}`)
  const merged = [...byIndex.values()].sort(comparePortageCandidates)
  const soft = Math.max(limit * 2, limit + 4)
  return merged.length > soft ? merged.slice(0, soft) : merged
}

function nearestPortageAccessPoint(target: LL, accessPoints: LL[], maxMeters = 12000): LL | null {
  let best: LL | null = null
  let bestM = Infinity
  for (const p of accessPoints) {
    const m = haversineMeters(target, p)
    if (m > maxMeters) continue
    if (m < bestM) { bestM = m; best = p }
  }
  return best
}

function resolvePortagingGraphAnchor(anchor: LL, nodes: LL[], spatialIndex: TrailSpatialIndex, accessPoints: LL[]): ResolvedAnchor {
  const direct = nearestTrailCandidatesAdaptive(anchor, nodes, { spatialIndex, limit: 1, radiiMeters: [4000, 8000, 15000], maxGlobalFallbackMeters: 12000 })
  const directMeters = direct.length ? direct[0].meters : Infinity
  const access = nearestPortageAccessPoint(anchor, accessPoints, 12000)
  if (!access) return { graphAnchor: anchor, connectorMeters: 0, usedAccess: false }
  const accessMeters = haversineMeters(anchor, access)
  const directLooksGood = Number.isFinite(directMeters) && directMeters <= 220
  const shouldUse = !Number.isFinite(directMeters) || accessMeters <= directMeters * 0.95 || (!directLooksGood && accessMeters <= directMeters * 1.35) || directMeters > 900
  if (!shouldUse) return { graphAnchor: anchor, connectorMeters: 0, usedAccess: false }
  return { graphAnchor: access, connectorMeters: accessMeters, usedAccess: true }
}

function portageGraphCandidatesForAnchor(opts: {
  anchor: LL; nodes: LL[]; spatialIndex: TrailSpatialIndex; accessPoints: LL[]; entry: PortagingOverlayEntry; limit: number; radiiMeters: number[]
  maxGlobalFallbackMeters?: number; componentIds?: number[]; componentSizes?: number[]; diversifyNearbyMeters?: number
}): PortageCandidate[] {
  const { anchor, nodes, spatialIndex, accessPoints, entry, limit, radiiMeters } = opts
  if (!nodes.length || limit <= 0) return []
  const byIndex = new Map<number, PortageCandidate>()
  const mergeCands = (cands: { index: number; meters: number }[], connectorMeters: number, graphAnchor: LL, usedAccess: boolean) => {
    for (const c of cands) {
      const next: PortageCandidate = { index: c.index, searchMeters: c.meters, connectorMeters, graphAnchor, usedAccess }
      const ex = byIndex.get(c.index)
      if (!ex || totalConnector(next) < totalConnector(ex) - 1e-6 || (Math.abs(totalConnector(next) - totalConnector(ex)) <= 1e-6 && !next.usedAccess && ex.usedAccess)) {
        byIndex.set(c.index, next)
      }
    }
  }

  if (isLikelyWaterPoint(anchor, entry, 120)) {
    mergeCands(
      nearestTrailCandidatesAdaptive(anchor, nodes, { spatialIndex, limit: Math.max(limit, 6), radiiMeters, maxGlobalFallbackMeters: opts.maxGlobalFallbackMeters }),
      0, anchor, false,
    )
  }
  const accessAnchor = resolvePortagingGraphAnchor(anchor, nodes, spatialIndex, accessPoints)
  if (accessAnchor.usedAccess && isLikelyWaterPoint(accessAnchor.graphAnchor, entry, 120)) {
    mergeCands(
      nearestTrailCandidatesAdaptive(accessAnchor.graphAnchor, nodes, { spatialIndex, limit: Math.max(limit, 6), radiiMeters, maxGlobalFallbackMeters: opts.maxGlobalFallbackMeters }),
      accessAnchor.connectorMeters, accessAnchor.graphAnchor, true,
    )
  }
  if (!byIndex.size) return []

  const sorter = (a: PortageCandidate, b: PortageCandidate) => {
    const t = totalConnector(a) - totalConnector(b)
    if (t) return t
    if (a.usedAccess !== b.usedAccess) return a.usedAccess ? 1 : -1
    return a.index - b.index
  }
  const merged = [...byIndex.values()].sort(sorter)

  const { componentIds, componentSizes } = opts
  const diversify = opts.diversifyNearbyMeters ?? 0
  if (componentIds && componentSizes && componentIds.length === nodes.length && diversify > 0) {
    const seen = new Set(merged.filter((c) => c.index >= 0 && c.index < componentIds.length).map((c) => componentIds[c.index]))
    const bestByComp = new Map<number, PortageCandidate>()
    for (let i = 0; i < nodes.length; i++) {
      const cid = componentIds[i]
      if (seen.has(cid)) continue
      const m = haversineMeters(anchor, nodes[i])
      if (!Number.isFinite(m) || m > diversify) continue
      const cand: PortageCandidate = { index: i, searchMeters: m, connectorMeters: 0, graphAnchor: anchor, usedAccess: false }
      const ex = bestByComp.get(cid)
      if (!ex || totalConnector(cand) < totalConnector(ex)) bestByComp.set(cid, cand)
    }
    if (bestByComp.size) {
      const largest = [...bestByComp.keys()].sort((a, b) => componentSizes[b] - componentSizes[a] || totalConnector(bestByComp.get(a)!) - totalConnector(bestByComp.get(b)!))
      for (const cid of largest) {
        if (merged.length >= limit + 4) break
        const c = bestByComp.get(cid)
        if (!c) continue
        merged.push(c)
        seen.add(cid)
        if (seen.size >= 3) break
      }
      const nearest = [...bestByComp.keys()].sort((a, b) => totalConnector(bestByComp.get(a)!) - totalConnector(bestByComp.get(b)!))
      for (const cid of nearest) {
        if (merged.length >= limit + 4) break
        if (seen.has(cid)) continue
        const c = bestByComp.get(cid)
        if (!c) continue
        merged.push(c)
        seen.add(cid)
      }
      merged.sort(sorter)
    }
  }
  const finalLimit = Math.max(limit, limit + 4)
  return merged.length > finalLimit ? merged.slice(0, finalLimit) : merged
}

function augmentPortageCandidatesViaOpenWater(opts: {
  anchor: LL; resolvedAnchor: ResolvedAnchor; baseCandidates: PortageCandidate[]; nodes: LL[]; spatialIndex: TrailSpatialIndex; entry: PortagingOverlayEntry
  maxExtraCandidates: number; maxReachMeters: number; componentIds?: number[]; componentSizes?: number[]
}): PortageCandidate[] {
  const { anchor, resolvedAnchor, baseCandidates, nodes, spatialIndex, entry, componentIds, componentSizes } = opts
  if (!nodes.length || opts.maxExtraCandidates <= 0 || opts.maxReachMeters <= 0) return baseCandidates
  if (!isLikelyWaterPoint(anchor, entry, 190) && !resolvedAnchor.usedAccess) return baseCandidates

  const byIndex = new Map<number, PortageCandidate>(baseCandidates.map((c) => [c.index, c]))
  const baseIdx = new Set(byIndex.keys())
  const hasComps = !!componentIds && !!componentSizes && componentIds.length === nodes.length
  const represented = hasComps ? new Set(baseCandidates.filter((c) => c.index >= 0 && c.index < componentIds!.length).map((c) => componentIds![c.index])) : new Set<number>()
  const safetyCache = new Map<string, boolean>()

  const compare = (a: PortageCandidate, b: PortageCandidate) => {
    if (hasComps && a.index >= 0 && a.index < componentIds!.length && b.index >= 0 && b.index < componentIds!.length) {
      const sc = componentSizes![componentIds![b.index]] - componentSizes![componentIds![a.index]]
      if (sc) return sc
    }
    const t = totalConnector(a) - totalConnector(b)
    if (t) return t
    if (a.usedAccess !== b.usedAccess) return a.usedAccess ? 1 : -1
    return a.index - b.index
  }
  const isSafeDirect = (from: LL, to: LL) => {
    const key = `${from.lat.toFixed(6)},${from.lng.toFixed(6)}->${to.lat.toFixed(6)},${to.lng.toFixed(6)}`
    let v = safetyCache.get(key)
    if (v === undefined) safetyCache.set(key, (v = isWaterSafeDirectSegment(from, to, entry)))
    return v
  }

  const sources: { point: LL; connectorMeters: number; usedAccess: boolean }[] = [{ point: anchor, connectorMeters: 0, usedAccess: false }]
  if (resolvedAnchor.usedAccess) sources.push({ point: resolvedAnchor.graphAnchor, connectorMeters: resolvedAnchor.connectorMeters, usedAccess: true })

  for (const source of sources) {
    if (!isLikelyWaterPoint(source.point, entry, 190)) continue
    for (const i of spatialIndex.indicesWithinRadius(source.point, opts.maxReachMeters)) {
      const node = nodes[i]
      const m = haversineMeters(source.point, node)
      if (!Number.isFinite(m) || m <= 120 || m > opts.maxReachMeters) continue
      if (!isSafeDirect(source.point, node)) continue
      const next: PortageCandidate = { index: i, searchMeters: m, connectorMeters: source.connectorMeters, graphAnchor: source.point, usedAccess: source.usedAccess }
      const ex = byIndex.get(i)
      if (!ex || totalConnector(next) < totalConnector(ex) - 1e-6 || (Math.abs(totalConnector(next) - totalConnector(ex)) <= 1e-6 && !next.usedAccess && ex.usedAccess)) byIndex.set(i, next)
    }
  }

  const extras = [...byIndex.values()].filter((c) => !baseIdx.has(c.index)).sort(compare)
  if (!extras.length) return baseCandidates
  const chosen: PortageCandidate[] = []
  if (hasComps) {
    const bestNew = new Map<number, PortageCandidate>()
    for (const c of extras) {
      const cid = componentIds![c.index]
      if (represented.has(cid)) continue
      const ex = bestNew.get(cid)
      if (!ex || compare(c, ex) < 0) bestNew.set(cid, c)
    }
    for (const c of [...bestNew.values()].sort(compare)) {
      if (chosen.length >= opts.maxExtraCandidates) break
      chosen.push(c)
      represented.add(componentIds![c.index])
    }
  }
  for (const c of extras) {
    if (chosen.length >= opts.maxExtraCandidates) break
    if (chosen.some((s) => s.index === c.index)) continue
    chosen.push(c)
  }
  if (!chosen.length) return baseCandidates
  const merged = [...baseCandidates, ...chosen].sort(compare)
  const maxTotal = Math.max(baseCandidates.length, Math.min(nodes.length, baseCandidates.length + opts.maxExtraCandidates))
  return merged.length > maxTotal ? merged.slice(0, maxTotal) : merged
}

// ---------------- water-first leg solver ----------------
function simplifyRoutingGraphLine(line: LL[], maxPoints: number, minSegmentMeters: number): LL[] {
  if (line.length <= 2) return line
  const sampled = downsampleLine(line, Math.max(2, maxPoints))
  if (sampled.length <= 2 || minSegmentMeters <= 0) return sampled
  const simplified = [sampled[0]]
  for (let i = 1; i + 1 < sampled.length; i++) {
    if (haversineMeters(simplified[simplified.length - 1], sampled[i]) >= minSegmentMeters) simplified.push(sampled[i])
  }
  const tail = sampled[sampled.length - 1]
  const lastKept = simplified[simplified.length - 1]
  if (Math.abs(lastKept.lat - tail.lat) > 1e-8 || Math.abs(lastKept.lng - tail.lng) > 1e-8) simplified.push(tail)
  return simplified.length >= 2 ? simplified : [line[0], line[line.length - 1]]
}
const graphVertexCount = (lines: LL[][]) => lines.reduce((n, l) => n + l.length, 0)

function waterEntryCandidatesForAnchor(opts: { anchor: LL; destination: LL; waterLines: LL[][]; entry: PortagingOverlayEntry; maxCandidates?: number; maxAnchorMeters?: number; maxLineDistanceMeters?: number }): { point: LL; connectorMeters: number }[] {
  const maxCandidates = opts.maxCandidates ?? 8
  const maxAnchor = opts.maxAnchorMeters ?? 6500
  const maxLineDist = opts.maxLineDistanceMeters ?? 9000
  const byKey = new Map<string, { point: LL; connectorMeters: number }>()
  const add = (point: LL, meters: number) => {
    if (!Number.isFinite(meters) || meters < 0 || meters > maxAnchor) return
    const key = `${point.lat.toFixed(5)},${point.lng.toFixed(5)}`
    const ex = byKey.get(key)
    if (!ex || meters < ex.connectorMeters) byKey.set(key, { point, connectorMeters: meters })
  }
  if (isLikelyWaterPoint(opts.anchor, opts.entry, 180)) add(opts.anchor, 0)
  const shortlisted: { line: LL[]; distance: number }[] = []
  for (const line of opts.waterLines) {
    if (line.length < 2) continue
    const d = distanceMetersToPath(opts.anchor, line)
    if (!Number.isFinite(d) || d > maxLineDist) continue
    shortlisted.push({ line, distance: d })
  }
  shortlisted.sort((a, b) => a.distance - b.distance)
  const cap = Math.max(maxCandidates * 2, 12)
  for (let i = 0; i < shortlisted.length && i < cap; i++) {
    const proj = nearestProjectionOnLine(opts.anchor, shortlisted[i].line, maxAnchor)
    if (proj) add(proj.point, proj.anchorMeters)
  }
  const out = [...byKey.values()].sort((a, b) => a.connectorMeters + haversineMeters(a.point, opts.destination) * 0.08 - (b.connectorMeters + haversineMeters(b.point, opts.destination) * 0.08))
  return out.length > maxCandidates ? out.slice(0, maxCandidates) : out
}

interface WaterFirstLeg { path: LL[]; distanceMeters: number }

function solveWaterFirstPortageLeg(opts: { start: LL; end: LL; waterLines: LL[][]; portageLines: LL[][]; entry: PortagingOverlayEntry }): WaterFirstLeg | null {
  const { start, end, entry } = opts
  const legStartedAt = Date.now()
  const maxLegSolveMs = 5000
  const direct = haversineMeters(start, end)
  if (!Number.isFinite(direct) || direct <= 0) return null

  const filteredWater = opts.waterLines.filter((l) => l.length >= 2)
  const filteredPortage = opts.portageLines.filter((l) => l.length >= 2 && isLikelyWaterEndpointForPortage(l[0], entry) && isLikelyWaterEndpointForPortage(l[l.length - 1], entry))

  const sameLineFallback = (): WaterFirstLeg | null => {
    const r = fastPortageRouteAlongSameLine({
      start, end, waterLines: filteredWater, portageLines: filteredPortage, entry, maxAnchorMeters: 3200, maxLineDistanceMeters: 3600, maxTotalMeters: Math.max(direct * 4, direct + 7000),
    })
    return r ? { path: r.path, distanceMeters: r.distanceMeters } : null
  }
  const budgetExceeded = (stage: string) => {
    const elapsed = Date.now() - legStartedAt
    if (elapsed <= maxLegSolveMs) return false
    console.debug(`portageLeg abort_budget stage=${stage} elapsed_ms=${elapsed}`)
    return true
  }

  let graphWater = filteredWater
  let graphPortage = filteredPortage
  const rawVertexCount = graphVertexCount(filteredWater) + graphVertexCount(filteredPortage)
  if (rawVertexCount > 4200) {
    const waterMax = Math.max(18, Math.min(42, Math.floor(3600 / Math.max(1, filteredWater.length))))
    const portageMax = Math.max(24, Math.min(72, Math.floor(1200 / Math.max(1, filteredPortage.length))))
    graphWater = filteredWater.map((l) => simplifyRoutingGraphLine(l, waterMax, direct <= 8000 ? 42 : 58))
    graphPortage = filteredPortage.map((l) => simplifyRoutingGraphLine(l, portageMax, 18))
  }

  const startWaterEntries = waterEntryCandidatesForAnchor({ anchor: start, destination: end, waterLines: graphWater, entry })
  const endWaterEntries = waterEntryCandidatesForAnchor({ anchor: end, destination: start, waterLines: graphWater, entry })
  const directWaterOk = () => startWaterEntries.length > 0 && endWaterEntries.length > 0 && isWaterSafeDirectSegment(start, end, entry, 18)

  const networkLines = [...graphWater, ...graphPortage]
  if (!networkLines.length) return directWaterOk() ? { path: [start, end], distanceMeters: direct } : null
  if (budgetExceeded('network_ready')) return sameLineFallback()

  const nodes: LL[] = []
  const nodeIndexByKey = new Map<string, number>()
  const typedAdj: { to: number; meters: number; isCarry: boolean }[][] = []
  const ensureNode = (p: LL) => {
    const key = trailNodeKey(p)
    const ex = nodeIndexByKey.get(key)
    if (ex != null) return ex
    const idx = nodes.length
    nodes.push(p)
    nodeIndexByKey.set(key, idx)
    typedAdj.push([])
    return idx
  }
  const addBi = (a: LL, b: LL, isCarry: boolean) => {
    const from = ensureNode(a), to = ensureNode(b)
    if (from === to) return
    const meters = haversineMeters(a, b)
    if (!Number.isFinite(meters) || meters <= 0.5) return
    typedAdj[from].push({ to, meters, isCarry })
    typedAdj[to].push({ to: from, meters, isCarry })
  }
  for (const line of graphWater) {
    let prev = line[0]
    ensureNode(prev)
    for (let i = 1; i < line.length; i++) { addBi(prev, line[i], false); prev = line[i] }
  }
  for (const line of graphPortage) {
    let prev = line[0]
    ensureNode(prev)
    for (let i = 1; i < line.length; i++) { addBi(prev, line[i], true); prev = line[i] }
  }

  if (nodes.length < 2) return filteredPortage.length === 0 && directWaterOk() ? { path: [start, end], distanceMeters: direct } : null
  if (nodes.length > 4200) {
    console.debug(`portageLeg skip_oversized_graph nodes=${nodes.length}`)
    return sameLineFallback()
  }
  if (budgetExceeded('graph_built')) return sameLineFallback()

  const weighted: TrailEdge[][] = typedAdj.map((edges) => edges.map((e) => ({ to: e.to, meters: e.isCarry ? e.meters * 1.55 + 120 : e.meters })))
  const spatialIndex = TrailSpatialIndex.fromNodes(nodes)
  const accessCoords: LL[] = entry.accessPoints.filter((a) => typeof a.lat === 'number' && typeof a.lon === 'number').map((a) => ({ lat: a.lat, lng: a.lon }))
  const startAnchor = resolvePortagingGraphAnchor(start, nodes, spatialIndex, accessCoords)
  const endAnchor = resolvePortagingGraphAnchor(end, nodes, spatialIndex, accessCoords)
  const heavy = rawVertexCount > 4200 || nodes.length > 2400 || graphWater.length > 90
  const candidateLimit = heavy ? 3 : 5
  const softLimit = heavy ? 6 : 10
  const perSnapBudgetMs = heavy ? 1300 : 2000
  const snapMaxSegments = heavy ? 650 : 1800
  const snapLineDist = heavy ? 7000 : 10000
  const snapAlong = heavy ? 12000 : 20000
  const candidateRadii = [2500, 5000, 9000, 15000]

  const buildCandidates = (anchor: LL, resolved: ResolvedAnchor, label: string) => {
    const base = heavy
      ? []
      : portageGraphCandidatesForAnchor({ anchor, nodes, spatialIndex, accessPoints: accessCoords, entry, limit: candidateLimit, radiiMeters: candidateRadii, maxGlobalFallbackMeters: 10000 })
    const deadline = Date.now() + perSnapBudgetMs
    return mergeCandidateGroups(
      [base, snapPortageCandidatesToSegments({
        anchor, lines: networkLines, nodeIndexByKey, entry, limit: candidateLimit, maxAnchorMeters: 9500, maxLineDistanceMeters: snapLineDist,
        maxAlongSegmentMeters: snapAlong, maxSegmentsToScan: snapMaxSegments, deadline, debugLabel: label, resolvedAnchor: resolved,
      })],
      softLimit,
    )
  }
  const startCandidates = buildCandidates(start, startAnchor, 'portageLegStartSnap')
  const endCandidates = buildCandidates(end, endAnchor, 'portageLegEndSnap')
  if (budgetExceeded('candidates_ready')) return sameLineFallback()

  if (!startCandidates.length || !endCandidates.length) {
    const same = sameLineFallback()
    if (same) return same
    return filteredPortage.length === 0 && directWaterOk() ? { path: [start, end], distanceMeters: direct } : null
  }

  let bestPrev: number[] | null = null
  let bestStartC: PortageCandidate | null = null
  let bestEndC: PortageCandidate | null = null
  let bestStartNode = -1
  let bestEndNode = -1
  let bestScore = Infinity
  const endNodeSet = new Set(endCandidates.map((c) => c.index))
  const searchDeadline = legStartedAt + maxLegSolveMs
  for (const sc of startCandidates) {
    const tree = shortestTrailTreeFromSource(sc.index, weighted, { stopNodes: endNodeSet, deadline: searchDeadline, debugLabel: 'portageLegSearch' })
    for (const ec of endCandidates) {
      const wm = tree.dist[ec.index]
      if (!Number.isFinite(wm)) continue
      const score = totalConnector(sc) + wm + totalConnector(ec)
      if (score < bestScore) {
        bestScore = score; bestPrev = tree.prev; bestStartC = sc; bestEndC = ec; bestStartNode = sc.index; bestEndNode = ec.index
      }
    }
    if (Date.now() > searchDeadline) break
  }

  if (!bestPrev || !bestStartC || !bestEndC || bestStartNode < 0 || bestEndNode < 0) {
    const same = sameLineFallback()
    if (same) return same
    return filteredPortage.length === 0 && directWaterOk() ? { path: [start, end], distanceMeters: direct } : null
  }
  if (
    !isValidPortageConnectorToGraphAnchor({ anchor: start, graphAnchor: bestStartC.graphAnchor, entry, allowAccessStraightToWater: bestStartC.usedAccess }) ||
    !isValidPortageConnectorToGraphAnchor({ anchor: end, graphAnchor: bestEndC.graphAnchor, entry, allowAccessStraightToWater: bestEndC.usedAccess })
  ) return null

  const nodePath = reconstructNodePath(bestStartNode, bestEndNode, bestPrev)
  if (!nodePath || !nodePath.length) return null
  const graphPath = nodePath.map((i) => nodes[i])
  const graphMeters = pathDistanceMeters(graphPath)
  if (!Number.isFinite(graphMeters) || graphMeters <= 0) return null

  const path: LL[] = []
  const add = (p: LL) => {
    const last = path[path.length - 1]
    if (last && Math.abs(last.lat - p.lat) < 1e-7 && Math.abs(last.lng - p.lng) < 1e-7) return
    path.push(p)
  }
  add(start)
  if (haversineMeters(start, bestStartC.graphAnchor) > 5) add(bestStartC.graphAnchor)
  graphPath.forEach(add)
  if (haversineMeters(bestEndC.graphAnchor, end) > 5) add(bestEndC.graphAnchor)
  add(end)
  const total = totalConnector(bestStartC) + graphMeters + totalConnector(bestEndC)
  if (path.length < 2 || !Number.isFinite(total) || total <= 0) return null
  if (total > Math.max(direct * 5.5, direct + 12000)) return null
  return { path, distanceMeters: total }
}

// ---------------- styled (carry vs paddle) segments ----------------
function segmentDistanceToPathMeters(a: LL, b: LL, path: LL[]): number {
  if (!path.length) return Infinity
  const mid = { lat: (a.lat + b.lat) / 2, lng: (a.lng + b.lng) / 2 }
  const s = distanceMetersToPath(a, path), m = distanceMetersToPath(mid, path), e = distanceMetersToPath(b, path)
  return Math.min(m, (s + e) / 2)
}
function segmentDistanceToLineSetMeters(a: LL, b: LL, lines: LL[][]): number {
  if (!lines.length) return Infinity
  let best = Infinity
  for (const line of lines) {
    if (line.length < 2) continue
    const m = segmentDistanceToPathMeters(a, b, line)
    if (m < best) best = m
    if (best <= 3) break
  }
  return best
}
function routeLinesNearPath(lines: LL[][], path: LL[], maxDistanceMeters = 120): LL[][] {
  if (!lines.length || path.length < 2) return []
  return lines.filter((l) => l.length >= 2 && distanceLineToPathMeters(l, path, 20) <= maxDistanceMeters)
}
function isCarryEdge(start: LL, end: LL, nearbyPortage: LL[][], nearbyWater: LL[][]): boolean {
  if (!nearbyPortage.length) return false
  const pm = segmentDistanceToLineSetMeters(start, end, nearbyPortage)
  if (!Number.isFinite(pm) || pm > 45) return false
  const wm = segmentDistanceToLineSetMeters(start, end, nearbyWater)
  if (!Number.isFinite(wm)) return true
  if (pm <= 18 && pm <= wm + 4) return true
  return pm + 12 < wm
}

function buildPortagingStyledSegments(opts: { path: LL[]; entry: PortagingOverlayEntry; width: number; zIndex: number }): StyledRouteSegment[] {
  const { path, entry, width, zIndex } = opts
  if (path.length < 2) return []
  const nearbyPortage = routeLinesNearPath(entry.portageLines, path, 140)
  if (!nearbyPortage.length) return []
  const nearbyWater = routeLinesNearPath(entry.waterLines, path, 140)
  const waterColor = standardRouteColor('portaging')
  const out: StyledRouteSegment[] = []
  const commit = (points: LL[], carry: boolean) => {
    if (points.length < 2) return
    out.push({ path: [...points], color: carry ? PORTAGE_CARRY_COLOR : waterColor, width, zIndex: carry ? zIndex + 1 : zIndex })
  }
  let curCarry = isCarryEdge(path[0], path[1], nearbyPortage, nearbyWater)
  let cur = [path[0], path[1]]
  for (let i = 1; i + 1 < path.length; i++) {
    const nextCarry = isCarryEdge(path[i], path[i + 1], nearbyPortage, nearbyWater)
    if (nextCarry === curCarry) { cur.push(path[i + 1]); continue }
    commit(cur, curCarry)
    curCarry = nextCarry
    cur = [path[i], path[i + 1]]
  }
  commit(cur, curCarry)
  return out.some((s) => s.color === PORTAGE_CARRY_COLOR) ? out : []
}

// ---------------- full route ----------------
interface PortageLegSolution { start: LL; end: LL; startOption: PortageCandidate; endOption: PortageCandidate; pathPoints: LL[]; graphMeters: number }
const yieldToUi = () => new Promise<void>((r) => setTimeout(r, 0))

export async function routeViaPortageGraph(segPoints: PointMap[], forceFocusLookup = false): Promise<RouteComputation | null> {
  if (segPoints.length < 2) return null
  const routeStartedAt = Date.now()
  const anchors: LL[] = segPoints.map((p) => ({ lat: latOf(p), lng: lonOf(p) }))
  if (anchors.length < 2) return null

  const retryWithFocusLookup = async (reason: string): Promise<RouteComputation | null> => {
    if (forceFocusLookup) return null
    if (!hasAvailableOverpassEndpoint()) {
      console.debug(`portageRoute skip_retry_focus_lookup reason=${reason} all_endpoints_blocked`)
      return null
    }
    console.debug(`portageRoute retry_focus_lookup reason=${reason}`)
    return routeViaPortageGraph(segPoints, true)
  }

  const routeBaseCacheKey = portagingRouteCacheKey(anchors)
  const cacheKey = `${routeBaseCacheKey}:route-lite`
  const routePad = adaptivePortageRoutePadDegrees(anchors)
  let entry: PortagingOverlayEntry | null = null
  if (!forceFocusLookup) {
    entry = await getPortagingOverlayEntry({ cacheKey, anchors, padDegrees: routePad, includeCampsites: true })
    if (!entry) {
      const cachedRoute = portagingCacheRef.get(routeBaseCacheKey)
      if (cachedRoute) entry = cachedRoute
    }
  }
  if (!entry) {
    const focusPad = routeFocusPadDegrees(anchors, { minPad: 0.12, maxPad: 0.24, edgePadding: 0.08 })
    const focusCandidates = portagingOverlayFocusPoints({ routePath: anchors, modeAnchors: anchors, focusPoint: routeBoundsCenter(anchors), maxPoints: 5 })
    const attempted = new Set<string>([cacheKey])
    for (const focus of focusCandidates) {
      const fk = portagingFocusCacheKey(focus, focusPad)
      if (!attempted.add(fk)) continue
      const fe = await getPortagingOverlayEntry({ cacheKey: fk, anchors: [focus], focusPoint: focus, padDegrees: focusPad, includeCampsites: true })
      if (!fe) continue
      entry = fe
      break
    }
  }
  if (!entry && portageState.lastVisible) {
    const visible = portageState.lastVisible
    const graphLines = visible.waterLines.length + visible.portageLines.length
    const direct = anchors.length >= 2 ? haversineMeters(anchors[0], anchors[anchors.length - 1]) : 0
    if (!(graphLines > 3200 || (graphLines > 1800 && direct > 2500))) entry = visible
  }
  if (!entry) return null

  const routeWater = selectGraphLinesForAnchors(entry.waterLines, anchors, { maxLines: 260, bboxPadDegrees: 0.06, debugLabel: 'portageRouteWater' })
  const routePortage = selectGraphLinesForAnchors(entry.portageLines, anchors, { maxLines: 80, bboxPadDegrees: 0.04, debugLabel: 'portageRouteCarry', distanceSamples: 6 })
  const networkLines = [...routeWater, ...routePortage]
  if (!networkLines.length) return retryWithFocusLookup('network_lines_empty')

  const color = standardRouteColor('portaging')
  const finish = (path: LL[], meters: number, label: string): RouteComputation => ({
    path, distanceMeters: meters, durationSeconds: meters / 1.35, color, width: 6, zIndex: 28,
    styledSegments: buildPortagingStyledSegments({ path, entry: entry!, width: 6, zIndex: 28 }),
    instructions: [`${label} (${(meters / 1000).toFixed(1)} km)`], stepDetails: [],
  })

  if (anchors.length === 2) {
    const same = fastPortageRouteAlongSameLine({ start: anchors[0], end: anchors[1], waterLines: routeWater, portageLines: routePortage, entry })
    if (same) {
      console.debug(`portageRoute same_line_fallback kind=${same.lineKind} meters=${same.distanceMeters.toFixed(0)} ms=${Date.now() - routeStartedAt}`)
      return finish(same.path, same.distanceMeters, 'Portage-waterline route')
    }
  }

  // Water-first per-leg solve.
  const waterFirstLegs: WaterFirstLeg[] = []
  let solvedWaterFirst = true
  for (let leg = 0; leg + 1 < anchors.length; leg++) {
    const legAnchors = [anchors[leg], anchors[leg + 1]]
    const legWater = selectGraphLinesForAnchors(routeWater, legAnchors, { maxLines: 120, bboxPadDegrees: 0.035, debugLabel: 'portageLegWater' })
    const legPortage = selectGraphLinesForAnchors(routePortage, legAnchors, { maxLines: 42, bboxPadDegrees: 0.03, debugLabel: 'portageLegCarry', distanceSamples: 5 })
    const sol = solveWaterFirstPortageLeg({ start: legAnchors[0], end: legAnchors[1], waterLines: legWater, portageLines: legPortage, entry })
    if (!sol) { solvedWaterFirst = false; break }
    waterFirstLegs.push(sol)
    await yieldToUi()
  }
  if (solvedWaterFirst && waterFirstLegs.length) {
    const combined: LL[] = []
    let total = 0
    for (const l of waterFirstLegs) {
      for (const p of l.path) {
        const last = combined[combined.length - 1]
        if (last && Math.abs(last.lat - p.lat) < 1e-7 && Math.abs(last.lng - p.lng) < 1e-7) continue
        combined.push(p)
      }
      total += l.distanceMeters
    }
    let solvedPath = combined
    let solvedMeters = total
    const off = anchors.length === 2 ? trimPortagingPathToWaterOffRamp({ path: solvedPath, destination: anchors[anchors.length - 1], entry }) : null
    if (off) { solvedPath = off.path; solvedMeters = off.distanceMeters }
    console.debug(`portageRoute solved_water_first legs=${waterFirstLegs.length} offRampApplied=${!!off} ms=${Date.now() - routeStartedAt}`)
    return finish(solvedPath, solvedMeters, 'Portage-water route')
  }

  // Whole-network Dijkstra fallback.
  const graph = graphForLines(networkLines, { cacheKey: `portage_route:${cacheKey}`, bridgeToleranceMeters: 320, allowLoopBridges: true, maxLoopBridgeMeters: 140 })
  const { nodes, adjacency, spatialIndex } = graph
  if (nodes.length < 2) return retryWithFocusLookup('graph_nodes_lt_2')
  const nodeIndexByKey = new Map(nodes.map((n, i) => [trailNodeKey(n), i]))
  if (nodes.length > 12000) {
    console.debug(`portageRoute skipped_too_large nodes=${nodes.length}`)
    return null
  }
  const accessCoords: LL[] = entry.accessPoints.filter((a) => typeof a.lat === 'number' && typeof a.lon === 'number').map((a) => ({ lat: a.lat, lng: a.lon }))
  const portageRadii = [5000, 9000, 16000, 26000]
  const expandedRadii = [6000, 11000, 19000, 30000, 42000]
  const legTimeBudgetMs = 4500
  const legs: PortageLegSolution[] = []

  for (let leg = 0; leg + 1 < anchors.length; leg++) {
    const legStart = Date.now()
    const start = anchors[leg], end = anchors[leg + 1]
    const startAnchor = resolvePortagingGraphAnchor(start, nodes, spatialIndex, accessCoords)
    const endAnchor = resolvePortagingGraphAnchor(end, nodes, spatialIndex, accessCoords)

    const build = (anchor: LL, resolved: ResolvedAnchor) => {
      let c = portageGraphCandidatesForAnchor({ anchor, nodes, spatialIndex, accessPoints: accessCoords, entry: entry!, limit: 6, radiiMeters: portageRadii, maxGlobalFallbackMeters: 13000 })
      c = mergeCandidateGroups([c, snapPortageCandidatesToSegments({
        anchor, lines: networkLines, nodeIndexByKey, entry: entry!, limit: 6, maxAnchorMeters: 14000, maxLineDistanceMeters: 16000, maxAlongSegmentMeters: 24000, resolvedAnchor: resolved,
      })], 12)
      return augmentPortageCandidatesViaOpenWater({ anchor, resolvedAnchor: resolved, baseCandidates: c, nodes, spatialIndex, entry: entry!, maxExtraCandidates: 6, maxReachMeters: 7000 })
    }
    const startCandidates = build(start, startAnchor)
    const endCandidates = build(end, endAnchor)
    if (!startCandidates.length || !endCandidates.length) {
      console.debug(`portageRoute leg_unanchored leg=${leg}`)
      return retryWithFocusLookup(`leg_${leg}_unanchored`)
    }

    let bestPrev: number[] | null = null
    let bestStartC: PortageCandidate | null = null
    let bestEndC: PortageCandidate | null = null
    let bestStartNode = -1, bestEndNode = -1
    let bestGraphMeters = Infinity
    let bestLegScore = Infinity
    let bestLegPathPoints: LL[] | null = null
    const safePairCache = new Map<string, boolean>()
    const big = entry.waterLines.length > 150 || entry.waterPolygons.length > 60
    const waterSafeSamples = big ? 12 : 40
    const maxWaterSafeChecks = big ? 20 : 30
    let waterSafeChecksUsed = 0
    const isSafeNodePair = (a: number, b: number) => {
      if (a < 0 || b < 0 || a >= nodes.length || b >= nodes.length || a === b) return false
      const key = `${Math.min(a, b)}:${Math.max(a, b)}`
      let v = safePairCache.get(key)
      if (v === undefined) safePairCache.set(key, (v = isWaterSafeDirectSegment(nodes[a], nodes[b], entry!, waterSafeSamples)))
      return v
    }

    const consider = (starts: PortageCandidate[], ends: PortageCandidate[]) => {
      const endNodeSet = new Set(ends.map((c) => c.index))
      for (const s of starts) {
        if (Date.now() - legStart > legTimeBudgetMs) break
        const startScore = portageConnectorScore(totalConnector(s))
        const tree = shortestTrailTreeFromSource(s.index, adjacency, { stopNodes: endNodeSet })
        for (const e of ends) {
          if (Date.now() - legStart > legTimeBudgetMs) break
          const endScore = portageConnectorScore(totalConnector(e))
          const gm = tree.dist[e.index]
          if (Number.isFinite(gm)) {
            const score = startScore + gm + endScore
            if (score < bestLegScore) {
              bestLegScore = score; bestGraphMeters = gm; bestPrev = tree.prev; bestLegPathPoints = null
              bestStartC = s; bestEndC = e; bestStartNode = s.index; bestEndNode = e.index
            }
          }
          const dw = haversineMeters(nodes[s.index], nodes[e.index])
          if (!Number.isFinite(dw) || dw <= 25 || dw > 16000) continue
          if (!(!Number.isFinite(gm) || dw + 40 < gm * 0.88)) continue
          if (waterSafeChecksUsed >= maxWaterSafeChecks || (bestPrev != null && Date.now() - legStart > legTimeBudgetMs * 0.6)) continue
          waterSafeChecksUsed++
          if (!isSafeNodePair(s.index, e.index)) continue
          const score = startScore + dw + endScore
          if (score < bestLegScore) {
            bestLegScore = score; bestGraphMeters = dw; bestPrev = null
            bestLegPathPoints = [nodes[s.index], nodes[e.index]]
            bestStartC = s; bestEndC = e; bestStartNode = s.index; bestEndNode = e.index
          }
        }
      }
    }

    consider(startCandidates, endCandidates)
    await yieldToUi()
    const direct = haversineMeters(start, end)
    const shouldRetryExpanded = Date.now() - legStart < legTimeBudgetMs && ((bestPrev == null && bestLegPathPoints == null) || (direct > 1200 && bestLegScore > direct * 8))
    if (shouldRetryExpanded) {
      const largeGraph = nodes.length > 8000
      const expandLimit = largeGraph ? 8 : 14
      const augmentLimit = largeGraph ? 4 : 10
      const augmentReach = largeGraph ? 8000 : 12000
      const comps = graphComponents(adjacency)
      const expand = (anchor: LL, resolved: ResolvedAnchor) => {
        const c0 = portageGraphCandidatesForAnchor({
          anchor, nodes, spatialIndex, accessPoints: accessCoords, entry: entry!, limit: expandLimit, radiiMeters: expandedRadii, maxGlobalFallbackMeters: 22000,
          componentIds: comps.componentIds, componentSizes: comps.componentSizes, diversifyNearbyMeters: 3000,
        })
        const c1 = mergeCandidateGroups([c0, snapPortageCandidatesToSegments({
          anchor, lines: networkLines, nodeIndexByKey, entry: entry!, limit: expandLimit, maxAnchorMeters: 22000, maxLineDistanceMeters: 24000, maxAlongSegmentMeters: 30000, resolvedAnchor: resolved,
        })], Math.max(expandLimit + 6, 16))
        return augmentPortageCandidatesViaOpenWater({
          anchor, resolvedAnchor: resolved, baseCandidates: c1, nodes, spatialIndex, entry: entry!, maxExtraCandidates: augmentLimit, maxReachMeters: augmentReach,
          componentIds: comps.componentIds, componentSizes: comps.componentSizes,
        })
      }
      const es = expand(start, startAnchor)
      const ee = expand(end, endAnchor)
      if (es.length && ee.length) consider(es, ee)
    }

    if ((bestPrev == null && bestLegPathPoints == null) || !bestStartC || !bestEndC || !Number.isFinite(bestGraphMeters)) {
      console.debug(`portageRoute leg_unsolved leg=${leg} ms=${Date.now() - legStart}`)
      return retryWithFocusLookup(`leg_${leg}_unsolved`)
    }
    const sC = bestStartC as PortageCandidate, eC = bestEndC as PortageCandidate
    if (
      !isValidPortageConnectorToGraphAnchor({ anchor: start, graphAnchor: sC.graphAnchor, entry, allowAccessStraightToWater: sC.usedAccess }) ||
      !isValidPortageConnectorToGraphAnchor({ anchor: end, graphAnchor: eC.graphAnchor, entry, allowAccessStraightToWater: eC.usedAccess })
    ) return retryWithFocusLookup(`leg_${leg}_invalid_connector`)

    let legPathPoints: LL[] = bestLegPathPoints ?? []
    if (!bestLegPathPoints && bestPrev) {
      const np = reconstructNodePath(bestStartNode, bestEndNode, bestPrev)
      legPathPoints = np && np.length ? np.map((i) => nodes[i]) : []
    }
    if (!legPathPoints.length) return retryWithFocusLookup(`leg_${leg}_path_empty`)
    legs.push({ start, end, startOption: sC, endOption: eC, pathPoints: legPathPoints, graphMeters: bestGraphMeters })
    await yieldToUi()
  }
  if (!legs.length) return retryWithFocusLookup('no_legs_solved')

  const path: LL[] = []
  const add = (p: LL) => {
    const last = path[path.length - 1]
    if (last && Math.abs(last.lat - p.lat) < 1e-7 && Math.abs(last.lng - p.lng) < 1e-7) return
    path.push(p)
  }
  let totalMeters = 0
  for (const leg of legs) {
    add(leg.start)
    if (haversineMeters(leg.start, leg.startOption.graphAnchor) > 5) add(leg.startOption.graphAnchor)
    leg.pathPoints.forEach(add)
    if (haversineMeters(leg.endOption.graphAnchor, leg.end) > 5) add(leg.endOption.graphAnchor)
    add(leg.end)
    totalMeters += totalConnector(leg.startOption) + leg.graphMeters + totalConnector(leg.endOption)
  }
  if (path.length < 2) return retryWithFocusLookup('path_lt_2')

  let solvedPath = path
  let solvedMeters = totalMeters
  const off = anchors.length === 2 ? trimPortagingPathToWaterOffRamp({ path, destination: anchors[anchors.length - 1], entry }) : null
  if (off) { solvedPath = off.path; solvedMeters = off.distanceMeters }
  console.debug(`portageRoute solved legs=${anchors.length - 1} nodes=${nodes.length} ms=${Date.now() - routeStartedAt}`)
  return finish(solvedPath, solvedMeters, 'Portage-water network route')
}
