/** Geometry helpers shared by the map and routing engines. */
export type LL = { lat: number; lng: number }

export const ll = (lat: number, lng: number): LL => ({ lat, lng })
const RAD = Math.PI / 180

export function haversineMeters(a: LL, b: LL): number {
  const r = 6371000
  const dLat = (b.lat - a.lat) * RAD
  const dLon = (b.lng - a.lng) * RAD
  const lat1 = a.lat * RAD
  const lat2 = b.lat * RAD
  const s1 = Math.sin(dLat / 2)
  const s2 = Math.sin(dLon / 2)
  const aa = s1 * s1 + Math.cos(lat1) * Math.cos(lat2) * s2 * s2
  return r * 2 * Math.atan2(Math.sqrt(aa), Math.sqrt(1 - aa))
}

export const sameLL = (a: LL, b: LL, eps = 1e-7) => Math.abs(a.lat - b.lat) < eps && Math.abs(a.lng - b.lng) < eps

/** Append `p` unless it duplicates the last point. */
export function appendDistinct(out: LL[], p: LL, eps = 1e-7) {
  const last = out[out.length - 1]
  if (last && sameLL(last, p, eps)) return
  out.push(p)
}

export function pathDistanceMeters(path: LL[]): number {
  let total = 0
  for (let i = 0; i + 1 < path.length; i++) total += haversineMeters(path[i], path[i + 1])
  return total
}

/** Squared distance (in projected degrees) from p to segment a→b. */
export function distPointToSegmentSq(p: LL, a: LL, b: LL): number {
  const cosLat = Math.cos(((a.lat + b.lat) / 2) * RAD)
  const px = p.lng * cosLat, py = p.lat
  const ax = a.lng * cosLat, ay = a.lat
  const bx = b.lng * cosLat, by = b.lat
  const abx = bx - ax, aby = by - ay
  const apx = px - ax, apy = py - ay
  const abLen2 = abx * abx + aby * aby
  if (abLen2 <= 1e-12) {
    const dx = px - ax, dy = py - ay
    return dx * dx + dy * dy
  }
  const t = Math.min(1, Math.max(0, (apx * abx + apy * aby) / abLen2))
  const dx = px - (ax + abx * t)
  const dy = py - (ay + aby * t)
  return dx * dx + dy * dy
}

/** Closest point to p ON segment a→b. */
export function projectOnSegment(p: LL, a: LL, b: LL): LL {
  const cosLat = Math.cos(((a.lat + b.lat) / 2) * RAD)
  const ax = a.lng * cosLat, ay = a.lat
  const bx = b.lng * cosLat, by = b.lat
  const px = p.lng * cosLat, py = p.lat
  const abx = bx - ax, aby = by - ay
  const apx = px - ax, apy = py - ay
  const abLen2 = abx * abx + aby * aby
  const t = abLen2 > 1e-12 ? Math.min(1, Math.max(0, (apx * abx + apy * aby) / abLen2)) : 0
  return { lat: a.lat + t * (b.lat - a.lat), lng: a.lng + t * (b.lng - a.lng) }
}

export function distanceMetersToPath(point: LL, path: LL[]): number {
  if (!path.length) return Infinity
  if (path.length === 1) return haversineMeters(point, path[0])
  let best = Infinity
  for (let i = 0; i + 1 < path.length; i++) {
    const m = haversineMeters(point, projectOnSegment(point, path[i], path[i + 1]))
    if (m < best) best = m
  }
  return best
}

export function distanceLineToPathMeters(line: LL[], path: LL[], maxSamples = 28): number {
  if (!line.length || !path.length) return Infinity
  let best = Infinity
  const step = Math.max(1, Math.floor(line.length / maxSamples))
  for (let i = 0; i < line.length; i += step) {
    const d = distanceMetersToPath(line[i], path)
    if (d < best) best = d
    if (best <= 1) break
  }
  const tail = distanceMetersToPath(line[line.length - 1], path)
  return Math.min(best, tail)
}

export const lerpLL = (a: LL, b: LL, t: number): LL => {
  const c = Math.min(1, Math.max(0, t))
  return { lat: a.lat + (b.lat - a.lat) * c, lng: a.lng + (b.lng - a.lng) * c }
}

export function pointInPolygon(point: LL, polygon: LL[]): boolean {
  if (polygon.length < 4) return false
  const x = point.lng, y = point.lat
  let inside = false
  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const xi = polygon[i].lng, yi = polygon[i].lat
    const xj = polygon[j].lng, yj = polygon[j].lat
    const denom = Math.abs(yj - yi) < 1e-12 ? 1e-12 : yj - yi
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / denom + xi) inside = !inside
  }
  return inside
}

export function downsampleLine(line: LL[], maxPoints = 220): LL[] {
  if (line.length <= maxPoints) return line
  const sampled: LL[] = []
  const step = Math.max(1, Math.floor(line.length / maxPoints))
  for (let i = 0; i < line.length; i += step) sampled.push(line[i])
  const tail = sampled[sampled.length - 1]
  const last = line[line.length - 1]
  if (tail && (Math.abs(tail.lat - last.lat) > 1e-8 || Math.abs(tail.lng - last.lng) > 1e-8)) sampled.push(last)
  return sampled
}

export function boundsOf(points: LL[]): { south: number; west: number; north: number; east: number } | null {
  if (!points.length) return null
  let south = points[0].lat, north = south, west = points[0].lng, east = west
  for (const p of points) {
    south = Math.min(south, p.lat)
    north = Math.max(north, p.lat)
    west = Math.min(west, p.lng)
    east = Math.max(east, p.lng)
  }
  return { south, west, north, east }
}

export const roundToStep = (v: number, step: number) => (!Number.isFinite(v) || step <= 0 ? v : Math.round(v / step) * step)
export const floorToStep = (v: number, step: number) => (!Number.isFinite(v) || step <= 0 ? v : Math.floor(v / step) * step)
export const ceilToStep = (v: number, step: number) => (!Number.isFinite(v) || step <= 0 ? v : Math.ceil(v / step) * step)

export function samplePath(path: LL[], target = 8): LL[] {
  if (path.length <= target) return [...path]
  const out: LL[] = []
  const step = Math.max(1, Math.floor(path.length / target))
  for (let i = 0; i < path.length; i += step) out.push(path[i])
  const last = path[path.length - 1]
  if (!out.length || Math.abs(out[out.length - 1].lat - last.lat) > 1e-8 || Math.abs(out[out.length - 1].lng - last.lng) > 1e-8) out.push(last)
  return out
}

export function pathSignature(path: LL[], sample = 14): string {
  if (!path.length) return ''
  const step = Math.max(1, Math.floor(path.length / sample))
  const parts: string[] = []
  for (let i = 0; i < path.length; i += step) parts.push(`${path[i].lat.toFixed(4)},${path[i].lng.toFixed(4)}`)
  const last = path[path.length - 1]
  return `${parts.join(';')};${last.lat.toFixed(4)},${last.lng.toFixed(4)}`
}

/** Min-heap used by Dijkstra searches. */
export class MinHeap<T> {
  private items: { v: T; k: number }[] = []
  get isEmpty() { return this.items.length === 0 }
  add(v: T, k: number) {
    const a = this.items
    a.push({ v, k })
    let i = a.length - 1
    while (i > 0) {
      const p = (i - 1) >> 1
      if (a[p].k <= a[i].k) break
      ;[a[p], a[i]] = [a[i], a[p]]
      i = p
    }
  }
  removeFirst(): { v: T; k: number } {
    const a = this.items
    const first = a[0]
    const last = a.pop()!
    if (!a.length) return first
    a[0] = last
    let i = 0
    for (;;) {
      const l = 2 * i + 1, r = l + 1
      let s = i
      if (l < a.length && a[l].k < a[s].k) s = l
      if (r < a.length && a[r].k < a[s].k) s = r
      if (s === i) break
      ;[a[i], a[s]] = [a[s], a[i]]
      i = s
    }
    return first
  }
}
