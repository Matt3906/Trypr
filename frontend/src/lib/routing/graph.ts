import { distanceLineToPathMeters, haversineMeters, MinHeap, projectOnSegment, type LL } from './geo'

export interface TrailEdge { to: number; meters: number }
export interface TrailCandidate { index: number; meters: number }

const M_PER_DEG = 111320

/** Grid-bucketed spatial index over graph nodes. */
export class TrailSpatialIndex {
  constructor(
    readonly cellMeters: number,
    readonly lonScale: number,
    readonly projectedX: number[],
    readonly projectedY: number[],
    readonly buckets: Map<string, number[]>,
  ) {}

  static fromNodes(nodes: LL[], cellMeters = 1800): TrailSpatialIndex {
    const safe = Math.min(5000, Math.max(300, cellMeters))
    if (!nodes.length) return new TrailSpatialIndex(safe, 1, [], [], new Map())
    let meanLat = 0
    for (const n of nodes) meanLat += n.lat
    meanLat /= nodes.length
    const lonScale = Math.min(1, Math.max(0.2, Math.abs(Math.cos(meanLat * (Math.PI / 180)))))
    const px = new Array<number>(nodes.length)
    const py = new Array<number>(nodes.length)
    const buckets = new Map<string, number[]>()
    for (let i = 0; i < nodes.length; i++) {
      const x = nodes[i].lng * M_PER_DEG * lonScale
      const y = nodes[i].lat * M_PER_DEG
      px[i] = x
      py[i] = y
      const key = `${Math.floor(x / safe)},${Math.floor(y / safe)}`
      const b = buckets.get(key)
      if (b) b.push(i)
      else buckets.set(key, [i])
    }
    return new TrailSpatialIndex(safe, lonScale, px, py, buckets)
  }

  indicesWithinRadius(target: LL, radiusMeters: number): number[] {
    if (!this.projectedX.length || radiusMeters <= 0) return []
    const x = target.lng * M_PER_DEG * this.lonScale
    const y = target.lat * M_PER_DEG
    const padded = Math.max(radiusMeters + 180, radiusMeters * 1.08)
    const br = Math.max(1, Math.ceil(padded / this.cellMeters))
    const bx = Math.floor(x / this.cellMeters)
    const by = Math.floor(y / this.cellMeters)
    const rSq = padded * padded
    const out: number[] = []
    for (let dx = -br; dx <= br; dx++) {
      for (let dy = -br; dy <= br; dy++) {
        const bucket = this.buckets.get(`${bx + dx},${by + dy}`)
        if (!bucket) continue
        for (const idx of bucket) {
          const ddx = this.projectedX[idx] - x
          const ddy = this.projectedY[idx] - y
          if (ddx * ddx + ddy * ddy <= rSq) out.push(idx)
        }
      }
    }
    return out
  }
}

export interface Graph {
  nodes: LL[]
  adjacency: TrailEdge[][]
  spatialIndex: TrailSpatialIndex
}

export const trailNodeKey = (p: LL) => `${p.lat.toFixed(6)},${p.lng.toFixed(6)}`
export const latLngMergeKey = (p: LL, decimals = 5) => `${p.lat.toFixed(decimals)},${p.lng.toFixed(decimals)}`

export function connectNearbyDeadEnds(opts: { nodes: LL[]; adjacency: TrailEdge[][]; maxBridgeMeters: number; allowLoopBridges?: boolean; maxLoopBridgeMeters?: number }) {
  const { nodes, adjacency, maxBridgeMeters } = opts
  if (maxBridgeMeters <= 0 || nodes.length < 2) return
  const minBridge = 10
  const maxSynthetic = 3
  const n = nodes.length
  const neighbors: Set<number>[] = Array.from({ length: n }, () => new Set<number>())
  for (let i = 0; i < adjacency.length; i++) for (const e of adjacency[i]) if (e.to >= 0 && e.to < n) neighbors[i].add(e.to)
  const degree = neighbors.map((s) => s.size)
  const endpointLike: number[] = []
  for (let i = 0; i < n; i++) if (degree[i] <= 2) endpointLike.push(i)
  if (endpointLike.length < 2) return

  let meanLat = 0
  for (const p of nodes) meanLat += p.lat
  meanLat /= n
  const lonScale = Math.min(1, Math.max(0.2, Math.abs(Math.cos(meanLat * (Math.PI / 180)))))
  const px = nodes.map((p) => p.lng * M_PER_DEG * lonScale)
  const py = nodes.map((p) => p.lat * M_PER_DEG)

  const cell = maxBridgeMeters
  const buckets = new Map<string, number[]>()
  for (const i of endpointLike) {
    const key = `${Math.floor(px[i] / cell)},${Math.floor(py[i] / cell)}`
    const b = buckets.get(key)
    if (b) b.push(i)
    else buckets.set(key, [i])
  }
  const maxSq = maxBridgeMeters * maxBridgeMeters
  const minSq = minBridge * minBridge
  const maxLoopSq = (opts.maxLoopBridgeMeters ?? 0) > 0 ? opts.maxLoopBridgeMeters! ** 2 : 0
  const synth = new Array<number>(n).fill(0)
  const limitFor = (node: number) => (degree[node] > 1 ? 1 : maxSynthetic)

  for (const i of endpointLike) {
    if (synth[i] >= limitFor(i)) continue
    const cx = Math.floor(px[i] / cell)
    const cy = Math.floor(py[i] / cell)
    const candidates: [number, number][] = []
    for (let dx = -1; dx <= 1; dx++) {
      for (let dy = -1; dy <= 1; dy++) {
        const list = buckets.get(`${cx + dx},${cy + dy}`)
        if (!list) continue
        for (const j of list) {
          if (j <= i || neighbors[i].has(j) || synth[j] >= limitFor(j)) continue
          const ddx = px[i] - px[j], ddy = py[i] - py[j]
          const dSq = ddx * ddx + ddy * ddy
          if (dSq < minSq || dSq > maxSq) continue
          if (degree[i] > 1 && degree[j] > 1) {
            if (!opts.allowLoopBridges) continue
            if (maxLoopSq <= 0 || dSq > maxLoopSq) continue
          }
          candidates.push([j, dSq])
        }
      }
    }
    candidates.sort((a, b) => a[1] - b[1])
    for (const [j, dSq] of candidates) {
      if (synth[i] >= limitFor(i)) break
      if (synth[j] >= limitFor(j) || neighbors[i].has(j)) continue
      const meters = Math.sqrt(dSq)
      if (!Number.isFinite(meters) || meters <= 0) continue
      adjacency[i].push({ to: j, meters })
      adjacency[j].push({ to: i, meters })
      neighbors[i].add(j)
      neighbors[j].add(i)
      synth[i]++
      synth[j]++
    }
  }
}

export function buildGraphFromLines(lines: LL[][], opts: { bridgeToleranceMeters?: number; allowLoopBridges?: boolean; maxLoopBridgeMeters?: number } = {}): Graph {
  const nodeByKey = new Map<string, number>()
  const nodes: LL[] = []
  const adjacency: TrailEdge[][] = []
  const ensure = (p: LL) => {
    const key = trailNodeKey(p)
    const existing = nodeByKey.get(key)
    if (existing != null) return existing
    const idx = nodes.length
    nodeByKey.set(key, idx)
    nodes.push(p)
    adjacency.push([])
    return idx
  }
  const addEdge = (a: number, b: number) => {
    if (a === b) return
    const meters = haversineMeters(nodes[a], nodes[b])
    if (!Number.isFinite(meters) || meters <= 0.5) return
    adjacency[a].push({ to: b, meters })
    adjacency[b].push({ to: a, meters })
  }
  for (const line of lines) {
    if (line.length < 2) continue
    let prev = ensure(line[0])
    for (let i = 1; i < line.length; i++) {
      const cur = ensure(line[i])
      addEdge(prev, cur)
      prev = cur
    }
  }
  if ((opts.bridgeToleranceMeters ?? 0) > 0 && nodes.length >= 2) {
    connectNearbyDeadEnds({
      nodes, adjacency, maxBridgeMeters: opts.bridgeToleranceMeters!, allowLoopBridges: opts.allowLoopBridges, maxLoopBridgeMeters: opts.maxLoopBridgeMeters,
    })
  }
  return { nodes, adjacency, spatialIndex: TrailSpatialIndex.fromNodes(nodes) }
}

export const OVERLAY_CACHE_TTL_MS = 30 * 60_000
export const isFresh = (at: number, ttl: number) => Date.now() - at <= ttl

const graphCache = new Map<string, { at: number; graph: Graph }>()
export function graphForLines(lines: LL[][], opts: { cacheKey: string; bridgeToleranceMeters?: number; allowLoopBridges?: boolean; maxLoopBridgeMeters?: number }): Graph {
  const full = `${opts.cacheKey}|bridge=${(opts.bridgeToleranceMeters ?? 0).toFixed(1)}|loop=${opts.allowLoopBridges ? 1 : 0}|loopMax=${(opts.maxLoopBridgeMeters ?? 0).toFixed(1)}`
  const existing = graphCache.get(full)
  if (existing && isFresh(existing.at, OVERLAY_CACHE_TTL_MS)) return existing.graph
  const graph = buildGraphFromLines(lines, opts)
  graphCache.set(full, { at: Date.now(), graph })
  return graph
}

export function graphComponents(adjacency: TrailEdge[][]): { componentIds: number[]; componentSizes: number[] } {
  const n = adjacency.length
  const ids = new Array<number>(n).fill(-1)
  const sizes: number[] = []
  let next = 0
  for (let start = 0; start < n; start++) {
    if (ids[start] !== -1) continue
    const queue = [start]
    ids[start] = next
    let size = 0
    for (let qi = 0; qi < queue.length; qi++) {
      const node = queue[qi]
      size++
      for (const e of adjacency[node]) {
        if (e.to < 0 || e.to >= n || ids[e.to] !== -1) continue
        ids[e.to] = next
        queue.push(e.to)
      }
    }
    sizes.push(size)
    next++
  }
  return { componentIds: ids, componentSizes: sizes }
}

export function shortestTrailTreeFromSource(source: number, adjacency: TrailEdge[][], opts: { stopNodes?: Set<number>; deadline?: number; debugLabel?: string } = {}): { dist: number[]; prev: number[] } {
  const n = adjacency.length
  const dist = new Array<number>(n).fill(Infinity)
  const prev = new Array<number>(n).fill(-1)
  if (source < 0 || source >= n) return { dist, prev }
  dist[source] = 0
  const pending = opts.stopNodes ? new Set(opts.stopNodes) : null
  const heap = new MinHeap<number>()
  heap.add(source, 0)
  let visited = 0
  while (!heap.isEmpty) {
    if (opts.deadline != null && (visited & 255) === 0 && Date.now() > opts.deadline) {
      if (opts.debugLabel) console.debug(`${opts.debugLabel} timed_out visited=${visited} nodes=${n}`)
      break
    }
    const { v: u, k: best } = heap.removeFirst()
    visited++
    if (best > dist[u] + 1e-9) continue
    if (pending && pending.delete(u) && pending.size === 0) break
    for (const e of adjacency[u]) {
      const alt = dist[u] + e.meters
      if (alt + 1e-9 < dist[e.to]) {
        dist[e.to] = alt
        prev[e.to] = u
        heap.add(e.to, alt)
      }
    }
  }
  return { dist, prev }
}

export function reconstructNodePath(start: number, end: number, prev: number[]): number[] | null {
  if (start < 0 || end < 0 || start >= prev.length || end >= prev.length) return null
  const reversed: number[] = []
  let cursor = end
  while (cursor >= 0) {
    reversed.push(cursor)
    if (cursor === start) break
    cursor = prev[cursor]
    if (cursor < 0) return null
  }
  return reversed.reverse()
}

export function shortestTrailPath(start: number, end: number, adjacency: TrailEdge[][]): { nodePath: number[]; meters: number } | null {
  const n = adjacency.length
  if (start < 0 || start >= n || end < 0 || end >= n) return null
  if (start === end) return { nodePath: [start], meters: 0 }
  const dist = new Array<number>(n).fill(Infinity)
  const prev = new Array<number>(n).fill(-1)
  dist[start] = 0
  const heap = new MinHeap<number>()
  heap.add(start, 0)
  while (!heap.isEmpty) {
    const { v: u, k: best } = heap.removeFirst()
    if (best > dist[u] + 1e-9) continue
    if (u === end) break
    for (const e of adjacency[u]) {
      const alt = dist[u] + e.meters
      if (alt + 1e-9 < dist[e.to]) {
        dist[e.to] = alt
        prev[e.to] = u
        heap.add(e.to, alt)
      }
    }
  }
  if (!Number.isFinite(dist[end])) return null
  const nodePath = reconstructNodePath(start, end, prev)
  return nodePath ? { nodePath, meters: dist[end] } : null
}

export function nearestTrailCandidates(target: LL, nodes: LL[], opts: { spatialIndex?: TrailSpatialIndex; limit?: number; maxMeters?: number } = {}): TrailCandidate[] {
  const limit = opts.limit ?? 6
  const maxMeters = opts.maxMeters ?? 3000
  const indices = opts.spatialIndex ? opts.spatialIndex.indicesWithinRadius(target, maxMeters) : nodes.map((_, i) => i)
  if (!indices.length) return []
  const cands: TrailCandidate[] = []
  for (const i of indices) {
    const meters = haversineMeters(target, nodes[i])
    if (meters <= maxMeters) cands.push({ index: i, meters })
  }
  cands.sort((a, b) => a.meters - b.meters)
  return cands.length > limit ? cands.slice(0, limit) : cands
}

export function nearestTrailCandidatesAdaptive(target: LL, nodes: LL[], opts: { spatialIndex?: TrailSpatialIndex; limit?: number; radiiMeters?: number[]; allowGlobalFallback?: boolean; maxGlobalFallbackMeters?: number } = {}): TrailCandidate[] {
  if (!nodes.length) return []
  const limit = opts.limit ?? 6
  const radii = opts.radiiMeters ?? [3000, 6000, 10000, 18000]
  const byIndex = new Map<number, TrailCandidate>()
  for (let ring = 0; ring < radii.length; ring++) {
    const cands = nearestTrailCandidates(target, nodes, { spatialIndex: opts.spatialIndex, limit: Math.max(limit * 2, limit + 2), maxMeters: radii[ring] })
    for (const c of cands) {
      const ex = byIndex.get(c.index)
      if (!ex || c.meters < ex.meters) byIndex.set(c.index, c)
    }
    if (byIndex.size >= limit && (radii.length <= 1 || ring >= 1)) break
  }
  if (byIndex.size) {
    const merged = [...byIndex.values()].sort((a, b) => a.meters - b.meters)
    return merged.length > limit ? merged.slice(0, limit) : merged
  }
  if (opts.allowGlobalFallback === false) return []
  if (opts.spatialIndex && opts.maxGlobalFallbackMeters != null) {
    return nearestTrailCandidates(target, nodes, { spatialIndex: opts.spatialIndex, limit, maxMeters: opts.maxGlobalFallbackMeters })
  }
  const all = nodes.map((p, i) => ({ index: i, meters: haversineMeters(target, p) })).sort((a, b) => a.meters - b.meters)
  if (opts.maxGlobalFallbackMeters != null && all.length && all[0].meters > opts.maxGlobalFallbackMeters) return []
  return all.length > limit ? all.slice(0, limit) : all
}

export function diversifyTrailCandidatesByComponent(opts: {
  anchor: LL; baseCandidates: TrailCandidate[]; nodes: LL[]; spatialIndex: TrailSpatialIndex; componentIds: number[]; componentSizes: number[]
  limit: number; nearbyRadiusMeters: number; maxNewComponents?: number
}): TrailCandidate[] {
  const { baseCandidates, nodes, componentIds, componentSizes } = opts
  const maxNew = opts.maxNewComponents ?? 3
  if (!baseCandidates.length || componentIds.length !== nodes.length || !componentSizes.length || opts.nearbyRadiusMeters <= 0) return baseCandidates

  const merged = [...baseCandidates]
  const seenIdx = new Set(baseCandidates.map((c) => c.index))
  const seenComp = new Set(baseCandidates.filter((c) => c.index >= 0 && c.index < componentIds.length).map((c) => componentIds[c.index]))
  const bestByComp = new Map<number, TrailCandidate>()
  for (const index of opts.spatialIndex.indicesWithinRadius(opts.anchor, opts.nearbyRadiusMeters)) {
    if (index < 0 || index >= nodes.length || seenIdx.has(index)) continue
    const cid = componentIds[index]
    if (seenComp.has(cid)) continue
    const meters = haversineMeters(opts.anchor, nodes[index])
    if (!Number.isFinite(meters) || meters > opts.nearbyRadiusMeters) continue
    const next = { index, meters }
    const ex = bestByComp.get(cid)
    if (!ex || next.meters < ex.meters) bestByComp.set(cid, next)
  }
  if (!bestByComp.size) return baseCandidates
  const ranked = [...bestByComp.keys()].sort((a, b) => {
    const sa = componentSizes[a] ?? 0, sb = componentSizes[b] ?? 0
    return sb - sa || bestByComp.get(a)!.meters - bestByComp.get(b)!.meters
  })
  for (const cid of ranked) {
    if (merged.length >= opts.limit + maxNew) break
    const c = bestByComp.get(cid)
    if (!c) continue
    merged.push(c)
    seenIdx.add(c.index)
    seenComp.add(cid)
  }
  merged.sort((a, b) => a.meters - b.meters)
  return merged.length > opts.limit + maxNew ? merged.slice(0, opts.limit + maxNew) : merged
}

export function selectGraphLinesForAnchors(lines: LL[][], anchors: LL[], opts: { maxLines: number; bboxPadDegrees: number; debugLabel: string; distanceSamples?: number }): LL[][] {
  const { maxLines } = opts
  const samples = opts.distanceSamples ?? 8
  if (lines.length <= maxLines || !anchors.length || maxLines <= 0) return lines
  let minLat = Infinity, maxLat = -Infinity, minLon = Infinity, maxLon = -Infinity
  for (const a of anchors) {
    minLat = Math.min(minLat, a.lat); maxLat = Math.max(maxLat, a.lat)
    minLon = Math.min(minLon, a.lng); maxLon = Math.max(maxLon, a.lng)
  }
  minLat -= opts.bboxPadDegrees; maxLat += opts.bboxPadDegrees
  minLon -= opts.bboxPadDegrees; maxLon += opts.bboxPadDegrees

  const inBox: number[] = []
  const outBox: { index: number; dist: number }[] = []
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (line.length < 2) continue
    const inside = line.some((p) => p.lat >= minLat && p.lat <= maxLat && p.lng >= minLon && p.lng <= maxLon)
    if (inside) inBox.push(i)
    else outBox.push({ index: i, dist: distanceLineToPathMeters(line, anchors, samples) })
  }
  let selectedInBox = inBox
  if (selectedInBox.length > maxLines) {
    selectedInBox = selectedInBox
      .map((index) => ({ index, dist: distanceLineToPathMeters(lines[index], anchors, samples) }))
      .sort((a, b) => a.dist - b.dist)
      .slice(0, maxLines)
      .map((s) => s.index)
  }
  outBox.sort((a, b) => a.dist - b.dist)
  const remaining = Math.max(0, maxLines - selectedInBox.length)
  return [...selectedInBox.map((i) => lines[i]), ...outBox.slice(0, remaining).map((o) => lines[o.index])]
}

// ---- same-line projection helpers ----
export interface LineProjection { point: LL; segmentIndex: number; anchorMeters: number }

export function nearestProjectionOnLine(anchor: LL, line: LL[], maxAnchorMeters = Infinity): LineProjection | null {
  if (line.length < 2) return null
  let best: LineProjection | null = null
  let bestMeters = Infinity
  for (let i = 0; i + 1 < line.length; i++) {
    const projected = projectOnSegment(anchor, line[i], line[i + 1])
    const meters = haversineMeters(anchor, projected)
    if (!Number.isFinite(meters) || meters >= bestMeters) continue
    bestMeters = meters
    best = { point: projected, segmentIndex: i, anchorMeters: meters }
  }
  if (!best || best.anchorMeters > maxAnchorMeters) return null
  return best
}

export function sliceLineBetweenProjections(line: LL[], start: LineProjection, end: LineProjection): LL[] {
  if (line.length < 2) return []
  const out: LL[] = []
  const add = (p: LL) => {
    const last = out[out.length - 1]
    if (last && Math.abs(last.lat - p.lat) < 1e-7 && Math.abs(last.lng - p.lng) < 1e-7) return
    out.push(p)
  }
  add(start.point)
  if (start.segmentIndex === end.segmentIndex) {
    add(end.point)
    return out
  }
  if (start.segmentIndex < end.segmentIndex) {
    for (let i = start.segmentIndex + 1; i <= end.segmentIndex; i++) add(line[i])
    add(end.point)
    return out
  }
  for (let i = start.segmentIndex; i > end.segmentIndex; i--) add(line[i])
  add(end.point)
  return out
}
