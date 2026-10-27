import type { LL } from './geo'
import type { StepDetail } from '@/services/directions'

export interface StyledRouteSegment {
  path: LL[]
  color: string
  width: number
  zIndex: number
}

/** One way to paddle a leg, offered when the water network has genuinely different routes between two stops. */
export interface RouteOption {
  distanceMeters: number
  durationSeconds: number
  paddleMeters: number
  portages: number
  portageMeters: number
  /** Bend point that steers the leg onto this option; null for the best route (no bend point). */
  via: { lat: number; lon: number } | null
  /** Whether the leg as currently routed follows this option. */
  current: boolean
  path: LL[]
}

export interface RouteComputation {
  path: LL[]
  distanceMeters: number
  durationSeconds: number
  color: string
  width: number
  zIndex: number
  geodesic?: boolean
  dashed?: { dash: number; gap: number } | null
  styledSegments?: StyledRouteSegment[]
  instructions: string[]
  stepDetails: StepDetail[]
  arrivalStop?: { name?: string; lat?: number; lon?: number } | null
  /** Opacity applied when rendering (straight-line fallbacks are faded). */
  opacity?: number
  /** Alternative ways to paddle this leg (portaging only); includes the current one. */
  options?: RouteOption[]
}

export type PointMap = Record<string, any>

export const latOf = (p: PointMap): number => num(p.lat ?? p.latitude ?? p.locationLat ?? p.LocationLat)
export const lonOf = (p: PointMap): number => num(p.lon ?? p.lng ?? p.longitude ?? p.locationLon ?? p.LocationLon)

export function num(v: unknown): number {
  if (typeof v === 'number') return v
  if (typeof v === 'string') {
    const n = parseFloat(v)
    return Number.isFinite(n) ? n : 0
  }
  return 0
}
