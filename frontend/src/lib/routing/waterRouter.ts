import { haversineMeters, pathDistanceMeters, type LL } from './geo'
import type { Bounds, PortagingOverlayEntry } from './overlayData'

/**
 * Paddle routing over a raster of the map's water data. Lakes (with islands cut out) and rivers are cheap to
 * cross, mapped portage trails cost a little more, and bush costs a lot, so the cheapest path paddles the
 * lakes, carries over the portages, and only crosses unmapped land where the data has a gap. Open water is
 * then straightened by line-of-sight so the route crosses a lake instead of following the grid.
 */

const LAND = 0, LAKE = 1, PORTAGE = 2, RIVER = 3, STREAM = 4
/** Cost per meter by cell kind (index = kind). A creek beats bushwhacking but loses to a mapped portage beside it. */
const COST = [25, 1, 2, 1.25, 4]
const isWater = (k: number) => k === LAKE || k === RIVER || k === STREAM

const MAX_CELLS = 800_000
const MIN_CELL_METERS = 18
const METERS_PER_DEG = 111_320
/** Land this short between two paddle runs is a narrows or a lift-over the grid missed, not a carry. */
const NARROWS_METERS = 90
/** Land at the start/end this short is the walk from the campsite or launch to the shore. */
const SHORE_METERS = 250

export type RunKind = 'paddle' | 'portage' | 'carry'
export interface WaterRun { kind: RunKind; path: LL[]; meters: number }
export interface WaterRoute { path: LL[]; runs: WaterRun[]; meters: number }
/** A way from the first to the last stop; `via` is the bend point that steers the route onto it (null = best). */
export interface WaterOption extends WaterRoute { via: LL | null }

interface Raster {
  w: number
  h: number
  cell: number
  kind: Uint8Array
  /** Which lake (1-based index of its water area) each cell belongs to; 0 off-lake. */
  lake: Int32Array
  toCell: (p: LL) => [number, number]
  toLL: (x: number, y: number) => LL
}

const overlaps = (b: Bounds, s: number, w: number, n: number, e: number) => b.north >= s && b.south <= n && b.east >= w && b.west <= e

function lineBounds(line: LL[]): Bounds {
  let south = Infinity, north = -Infinity, west = Infinity, east = -Infinity
  for (const p of line) {
    if (p.lat < south) south = p.lat
    if (p.lat > north) north = p.lat
    if (p.lng < west) west = p.lng
    if (p.lng > east) east = p.lng
  }
  return { south, west, north, east }
}

function buildRaster(entries: PortagingOverlayEntry[], bounds: Bounds): Raster | null {
  const lat0 = (bounds.south + bounds.north) / 2
  const mPerLng = METERS_PER_DEG * Math.cos((lat0 * Math.PI) / 180)
  const widthM = (bounds.east - bounds.west) * mPerLng
  const heightM = (bounds.north - bounds.south) * METERS_PER_DEG
  const cell = Math.max(MIN_CELL_METERS, Math.sqrt((widthM * heightM) / MAX_CELLS))
  const w = Math.max(2, Math.ceil(widthM / cell)), h = Math.max(2, Math.ceil(heightM / cell))
  const kind = new Uint8Array(w * h)
  const lake = new Int32Array(w * h)
  let lakeId = 0
  const fx = (lng: number) => ((lng - bounds.west) * mPerLng) / cell
  const fy = (lat: number) => ((lat - bounds.south) * METERS_PER_DEG) / cell
  const clampX = (x: number) => Math.min(w - 1, Math.max(0, x))
  const clampY = (y: number) => Math.min(h - 1, Math.max(0, y))
  const { south, west, north, east } = bounds
  const seenAreas = new Set<string>()

  // Lakes: even-odd scanline fill over each area's rings, so islands (inner rings) stay land.
  for (const entry of entries) {
    for (const area of entry.waterAreas ?? []) {
      if (seenAreas.has(area.key)) continue
      seenAreas.add(area.key)
      if (!area.rings.some((r) => overlaps(lineBounds(r), south, west, north, east))) continue
      lakeId++
      const rows = new Map<number, number[]>()
      for (const ring of area.rings) {
        for (let k = 0; k + 1 < ring.length; k++) {
          const ax = fx(ring[k].lng), ay = fy(ring[k].lat), bx = fx(ring[k + 1].lng), by = fy(ring[k + 1].lat)
          if (ay === by) continue
          const y0 = Math.max(0, Math.ceil(Math.min(ay, by) - 0.5)), y1 = Math.min(h - 1, Math.floor(Math.max(ay, by) - 0.5))
          for (let y = y0; y <= y1; y++) {
            const cy = y + 0.5
            if (cy < Math.min(ay, by) || cy >= Math.max(ay, by)) continue
            const x = ax + ((cy - ay) * (bx - ax)) / (by - ay)
            const row = rows.get(y)
            if (row) row.push(x)
            else rows.set(y, [x])
          }
        }
      }
      for (const [y, xs] of rows) {
        xs.sort((a, b) => a - b)
        for (let i = 0; i + 1 < xs.length; i += 2) {
          const x0 = Math.max(0, Math.ceil(xs[i] - 0.5)), x1 = Math.min(w - 1, Math.floor(xs[i + 1] - 0.5))
          for (let x = x0; x <= x1; x++) {
            kind[y * w + x] = LAKE
            lake[y * w + x] = lakeId
          }
        }
      }
    }
  }

  const stroke = (line: LL[], value: number, radius: number, onlyOver: number) => {
    if (!overlaps(lineBounds(line), south, west, north, east)) return
    for (let k = 0; k + 1 < line.length; k++) {
      const ax = fx(line[k].lng), ay = fy(line[k].lat), bx = fx(line[k + 1].lng), by = fy(line[k + 1].lat)
      const steps = Math.max(1, Math.ceil(Math.hypot(bx - ax, by - ay) * 2))
      for (let s = 0; s <= steps; s++) {
        const cx = Math.floor(ax + ((bx - ax) * s) / steps), cy = Math.floor(ay + ((by - ay) * s) / steps)
        for (let dy = -radius; dy <= radius; dy++) for (let dx = -radius; dx <= radius; dx++) {
          const x = cx + dx, y = cy + dy
          if (x < 0 || y < 0 || x >= w || y >= h) continue
          if (kind[y * w + x] === onlyOver) kind[y * w + x] = value
        }
      }
    }
  }
  // Rivers keep narrow channels between lakes connected even where no river polygon is mapped.
  // Portages go first so a river line drawn along a trail can't turn the trail into paddling.
  const riverRadius = cell < 30 ? 1 : 0
  for (const entry of entries) for (const line of entry.portageLines) stroke(line, PORTAGE, 0, LAND)
  for (const entry of entries) for (const line of entry.channelLines ?? []) stroke(line, RIVER, riverRadius, LAND)
  for (const entry of entries) for (const line of entry.streamLines ?? []) stroke(line, STREAM, 0, LAND)

  let water = 0
  for (let i = 0; i < kind.length; i++) if (isWater(kind[i])) water++
  if (!water) return null

  return {
    w, h, cell, kind, lake,
    toCell: (p) => [clampX(Math.floor(fx(p.lng))), clampY(Math.floor(fy(p.lat)))],
    toLL: (x, y) => ({ lat: south + ((y + 0.5) * cell) / METERS_PER_DEG, lng: west + ((x + 0.5) * cell) / mPerLng }),
  }
}

const DX = [1, -1, 0, 0, 1, 1, -1, -1]
const DY = [0, 0, 1, -1, 1, -1, 1, -1]
const STEP = [1, 1, 1, 1, Math.SQRT2, Math.SQRT2, Math.SQRT2, Math.SQRT2]

/** A* over the raster; returns the cell indices from start to goal. Cells flagged in `penalty` cost ALT_PENALTY times more. */
function searchCells(r: Raster, start: number, goal: number, penalty?: Uint8Array): number[] | null {
  const { w, h, kind, cell } = r
  const n = w * h
  const g = new Float64Array(n).fill(Infinity)
  const prev = new Int32Array(n).fill(-1)
  const closed = new Uint8Array(n)
  const gx = goal % w, gy = (goal / w) | 0
  const heuristic = (i: number) => {
    const dx = Math.abs((i % w) - gx), dy = Math.abs(((i / w) | 0) - gy)
    return (Math.max(dx, dy) + (Math.SQRT2 - 1) * Math.min(dx, dy)) * cell * COST[LAKE]
  }
  // Binary heap of cell indices keyed by f = g + h.
  const heap: number[] = []
  const key: number[] = []
  const push = (i: number, f: number) => {
    heap.push(i); key.push(f)
    let c = heap.length - 1
    while (c > 0) {
      const p = (c - 1) >> 1
      if (key[p] <= key[c]) break
      ;[heap[p], heap[c]] = [heap[c], heap[p]]
      ;[key[p], key[c]] = [key[c], key[p]]
      c = p
    }
  }
  const pop = (): number => {
    const top = heap[0]
    const lastI = heap.pop()!, lastK = key.pop()!
    if (heap.length) {
      heap[0] = lastI; key[0] = lastK
      for (let c = 0; ;) {
        const l = 2 * c + 1, rr = l + 1
        let s = c
        if (l < heap.length && key[l] < key[s]) s = l
        if (rr < heap.length && key[rr] < key[s]) s = rr
        if (s === c) break
        ;[heap[s], heap[c]] = [heap[c], heap[s]]
        ;[key[s], key[c]] = [key[c], key[s]]
        c = s
      }
    }
    return top
  }

  g[start] = 0
  push(start, heuristic(start))
  while (heap.length) {
    const i = pop()
    if (closed[i]) continue
    if (i === goal) break
    closed[i] = 1
    const x = i % w, y = (i / w) | 0
    const ci = COST[kind[i]]
    for (let d = 0; d < 8; d++) {
      const nx = x + DX[d], ny = y + DY[d]
      if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue
      const j = ny * w + nx
      if (closed[j]) continue
      let step = STEP[d] * cell * (ci + COST[kind[j]]) * 0.5
      if (penalty && (penalty[i] || penalty[j])) step *= ALT_PENALTY
      const ng = g[i] + step
      if (ng >= g[j]) continue
      g[j] = ng
      prev[j] = i
      push(j, ng + heuristic(j))
    }
  }
  if (prev[goal] < 0 && goal !== start) return null
  const out: number[] = []
  for (let i = goal; i >= 0; i = prev[i]) {
    out.push(i)
    if (i === start) break
  }
  return out.reverse()
}

const classOf = (k: number): RunKind => (isWater(k) ? 'paddle' : k === PORTAGE ? 'portage' : 'carry')

/** Splits a cell path into paddle / portage / carry runs and folds grid noise into its neighbours. */
function cellRuns(r: Raster, cells: number[]): { kind: RunKind; cells: number[] }[] {
  const runs: { kind: RunKind; cells: number[] }[] = []
  for (const c of cells) {
    const kind = classOf(r.kind[c])
    const last = runs[runs.length - 1]
    if (last && last.kind === kind) last.cells.push(c)
    else runs.push({ kind, cells: [c] })
  }
  const meters = (run: { cells: number[] }) => run.cells.length * r.cell
  for (let i = 0; i < runs.length; i++) {
    const run = runs[i]
    if (run.kind !== 'carry') continue
    const before = runs[i - 1]?.kind, after = runs[i + 1]?.kind
    if (before === 'portage' || after === 'portage') run.kind = 'portage'
    else if (before === 'paddle' && after === 'paddle' && meters(run) <= NARROWS_METERS) run.kind = 'paddle'
    else if ((!before || !after) && meters(run) <= SHORE_METERS) run.kind = before ?? after ?? 'carry'
  }
  const merged: { kind: RunKind; cells: number[] }[] = []
  for (const run of runs) {
    const last = merged[merged.length - 1]
    if (last && last.kind === run.kind) last.cells.push(...run.cells)
    else merged.push({ kind: run.kind, cells: [...run.cells] })
  }
  return merged
}

/** Greedy line-of-sight smoothing: keep a cell only where a straight line to the next kept cell would leave water. */
function straightenOverWater(r: Raster, cells: number[]): number[] {
  if (cells.length <= 2) return cells
  const { w, kind } = r
  const clear = (a: number, b: number) => {
    const ax = a % w + 0.5, ay = ((a / w) | 0) + 0.5, bx = b % w + 0.5, by = ((b / w) | 0) + 0.5
    const steps = Math.ceil(Math.hypot(bx - ax, by - ay) * 2)
    for (let s = 1; s < steps; s++) {
      const k = kind[Math.floor(ay + ((by - ay) * s) / steps) * w + Math.floor(ax + ((bx - ax) * s) / steps)]
      if (k !== LAKE && k !== RIVER) return false
    }
    return true
  }
  const out = [cells[0]]
  let i = 0
  while (i < cells.length - 1) {
    let ok = i + 1, bad = -1
    for (let step = 2; ; step *= 2) {
      const j = Math.min(cells.length - 1, i + step)
      if (!clear(cells[i], cells[j])) { bad = j; break }
      ok = j
      if (j === cells.length - 1) break
    }
    while (bad > ok + 1) {
      const mid = (ok + bad) >> 1
      if (clear(cells[i], cells[mid])) ok = mid
      else bad = mid
    }
    out.push(cells[ok])
    i = ok
  }
  return out
}

/** Douglas-Peucker in cell units; removes the grid's staircase from portage and carry runs. */
function simplifyCells(r: Raster, cells: number[], tolerance = 0.9): number[] {
  if (cells.length <= 2) return cells
  const { w } = r
  const xy = (c: number) => [c % w, (c / w) | 0]
  const keep = new Uint8Array(cells.length)
  keep[0] = keep[cells.length - 1] = 1
  const stack: [number, number][] = [[0, cells.length - 1]]
  while (stack.length) {
    const [a, b] = stack.pop()!
    const [ax, ay] = xy(cells[a]), [bx, by] = xy(cells[b])
    const len = Math.hypot(bx - ax, by - ay) || 1
    let best = -1, bestD = tolerance
    for (let i = a + 1; i < b; i++) {
      const [px, py] = xy(cells[i])
      const d = Math.abs((bx - ax) * (ay - py) - (ax - px) * (by - ay)) / len
      if (d > bestD) { bestD = d; best = i }
    }
    if (best >= 0) {
      keep[best] = 1
      stack.push([a, best], [best, b])
    }
  }
  return cells.filter((_, i) => keep[i])
}

/** Bounding box around the stops, padded so the route can swing around peninsulas and up side bays. */
export function waterRouteBounds(points: LL[]): Bounds {
  let south = Infinity, north = -Infinity, west = Infinity, east = -Infinity
  for (const p of points) {
    south = Math.min(south, p.lat); north = Math.max(north, p.lat)
    west = Math.min(west, p.lng); east = Math.max(east, p.lng)
  }
  const pad = Math.max(0.02, 0.35 * Math.max(north - south, east - west))
  return { south: south - pad, west: west - pad * 1.4, north: north + pad, east: east + pad * 1.4 }
}

/** Paddle / portage / carry runs for one leg's cell path, pinned to the exact stops at both ends. */
function legRuns(r: Raster, cells: number[], from: LL, to: LL): WaterRun[] {
  const runs = cellRuns(r, cells)
  return runs.map((run, i) => {
    // Runs share their boundary cell so the drawn line has no gaps.
    const withJoin = i + 1 < runs.length ? [...run.cells, runs[i + 1].cells[0]] : run.cells
    const kept = run.kind === 'paddle' ? straightenOverWater(r, withJoin) : simplifyCells(r, withJoin)
    const path = kept.map((c) => r.toLL(c % r.w, (c / r.w) | 0))
    if (path.length < 2) path.push(path[0]) // both stops in one cell
    if (i === 0) path[0] = from
    if (i === runs.length - 1) path[path.length - 1] = to
    return { kind: run.kind, path, meters: pathDistanceMeters(path) }
  })
}

function assemble(legs: WaterRun[][]): WaterRoute {
  const runs: WaterRun[] = []
  for (const leg of legs) for (const run of leg) {
    const last = runs[runs.length - 1]
    if (last && last.kind === run.kind) {
      last.path.push(...run.path.slice(1))
      last.meters = pathDistanceMeters(last.path)
    } else runs.push({ ...run, path: [...run.path] })
  }
  const path: LL[] = []
  for (const run of runs) for (const p of run.path) {
    const last = path[path.length - 1]
    if (!last || haversineMeters(last, p) > 0.5) path.push(p)
  }
  return { path, runs, meters: pathDistanceMeters(path) }
}

// ---- alternatives: penalize the corridor around each route found so far and search again ----
/** Gentle enough that water every route must use (a lake's only outlet) stays shared rather than detoured around. */
const ALT_PENALTY = 2
const ALT_CORRIDOR_METERS = 300
/** Near the stops every route has to share the same water, so the corridor leaves them free. */
const ALT_ENDPOINT_FREE_METERS = 700
/** An alternative may cost at most this much more than the best route... */
const ALT_MAX_STRETCH = 1.6
/** ...and must cross a different set of lakes (counting lakes it paddles at least this far in) or portage differently. */
const ALT_LAKE_MIN_METERS = 250
const ALT_PORTAGE_DIFF_METERS = 200
const ALT_SEARCHES = 4

function pathCost(r: Raster, cells: number[]): number {
  let total = 0
  for (let k = 0; k + 1 < cells.length; k++) {
    const a = cells[k], b = cells[k + 1]
    const diagonal = a % r.w !== b % r.w && ((a / r.w) | 0) !== ((b / r.w) | 0)
    total += (diagonal ? Math.SQRT2 : 1) * r.cell * (COST[r.kind[a]] + COST[r.kind[b]]) * 0.5
  }
  return total
}

function markCorridor(r: Raster, penalty: Uint8Array, cells: number[], start: number, goal: number) {
  const radius = Math.ceil(ALT_CORRIDOR_METERS / r.cell)
  const free = ALT_ENDPOINT_FREE_METERS / r.cell
  const sx = start % r.w, sy = (start / r.w) | 0, gx = goal % r.w, gy = (goal / r.w) | 0
  for (let k = 0; k < cells.length; k += 2) {
    const cx = cells[k] % r.w, cy = (cells[k] / r.w) | 0
    if (Math.hypot(cx - sx, cy - sy) < free || Math.hypot(cx - gx, cy - gy) < free) continue
    for (let dy = -radius; dy <= radius; dy++) for (let dx = -radius; dx <= radius; dx++) {
      const x = cx + dx, y = cy + dy
      if (x >= 0 && y >= 0 && x < r.w && y < r.h && dx * dx + dy * dy <= radius * radius) penalty[y * r.w + x] = 1
    }
  }
}

function lakesOf(r: Raster, cells: number[]): Set<number> {
  const meters = new Map<number, number>()
  for (const c of cells) if (r.lake[c]) meters.set(r.lake[c], (meters.get(r.lake[c]) ?? 0) + r.cell)
  return new Set([...meters].filter(([, m]) => m >= ALT_LAKE_MIN_METERS).map(([id]) => id))
}
const portageMetersOf = (route: WaterRoute) => route.runs.reduce((t, run) => t + (run.kind === 'paddle' ? 0 : run.meters), 0)

/** Middle of the longest stretch outside the penalized corridors, nudged onto water: where to bend the line. */
function viaCell(r: Raster, cells: number[], penalty: Uint8Array): number {
  let bestStart = 0, bestLen = 0
  for (let k = 0; k < cells.length;) {
    if (penalty[cells[k]]) { k++; continue }
    let e = k
    while (e < cells.length && !penalty[cells[e]]) e++
    if (e - k > bestLen) { bestLen = e - k; bestStart = k }
    k = e
  }
  const mid = bestStart + (bestLen >> 1)
  for (let off = 0; off <= bestLen >> 1; off++) {
    for (const k of [mid - off, mid + off]) if (k >= bestStart && k < bestStart + bestLen && isWater(r.kind[cells[k]])) return cells[k]
  }
  return cells[mid]
}

/**
 * Routes through `points` in order (stops plus any bend points the user placed) over the water data in
 * `entries`. Returns null when the area has no water data, so the caller can fall back to a straight line.
 * With `alternatives`, also returns `options`: the best way from the first to the last stop (ignoring bend
 * points) plus up to that many genuinely different ways, each with the bend point that selects it.
 */
export function routeOverWater(points: LL[], entries: PortagingOverlayEntry[], opts: { alternatives?: number } = {}): (WaterRoute & { options: WaterOption[] }) | null {
  if (points.length < 2 || !entries.length) return null
  const raster = buildRaster(entries, waterRouteBounds(points))
  if (!raster) return null
  const cellOf = (p: LL) => {
    const [x, y] = raster.toCell(p)
    return y * raster.w + x
  }

  const legs: WaterRun[][] = []
  let directCells: number[] | null = null
  for (let leg = 0; leg + 1 < points.length; leg++) {
    const cells = searchCells(raster, cellOf(points[leg]), cellOf(points[leg + 1]))
    if (!cells) return null
    if (points.length === 2) directCells = cells
    legs.push(legRuns(raster, cells, points[leg], points[leg + 1]))
  }
  const route = assemble(legs)

  const options: WaterOption[] = []
  const wanted = opts.alternatives ?? 0
  if (wanted > 0) {
    const from = points[0], to = points[points.length - 1]
    const start = cellOf(from), goal = cellOf(to)
    const best = directCells ?? searchCells(raster, start, goal)
    if (best) {
      const bestCost = pathCost(raster, best)
      const penalty = new Uint8Array(raster.w * raster.h)
      const found: { cells: number[]; lakes: Set<number>; route: WaterRoute }[] = [
        { cells: best, lakes: lakesOf(raster, best), route: directCells ? route : assemble([legRuns(raster, best, from, to)]) },
      ]
      const differs = (a: { lakes: Set<number>; route: WaterRoute }, b: { lakes: Set<number>; route: WaterRoute }) =>
        [...a.lakes].some((id) => !b.lakes.has(id)) || [...b.lakes].some((id) => !a.lakes.has(id)) ||
        Math.abs(portageMetersOf(a.route) - portageMetersOf(b.route)) > ALT_PORTAGE_DIFF_METERS
      markCorridor(raster, penalty, best, start, goal)
      for (let k = 0; k < ALT_SEARCHES && found.length <= wanted; k++) {
        const cells = searchCells(raster, start, goal, penalty)
        if (!cells || pathCost(raster, cells) > bestCost * ALT_MAX_STRETCH) break
        markCorridor(raster, penalty, cells, start, goal)
        const candidate = { cells, lakes: lakesOf(raster, cells), route: assemble([legRuns(raster, cells, from, to)]) }
        if (found.every((f) => differs(f, candidate))) found.push(candidate)
      }
      if (found.length > 1) {
        const free = new Uint8Array(raster.w * raster.h)
        found.forEach((f, k) => {
          // Bend where this option leaves the others, so routing through the bend reproduces it.
          free.fill(0)
          found.forEach((o, j) => { if (j !== k) markCorridor(raster, free, o.cells, start, goal) })
          const via = k === 0 ? null : viaCell(raster, f.cells, free)
          options.push({ ...f.route, via: via == null ? null : raster.toLL(via % raster.w, (via / raster.w) | 0) })
        })
      }
    }
  }
  return { ...route, options }
}
