import type { LL } from './geo'
import type { StepDetail } from '@/services/directions'

export interface StyledRouteSegment {
  path: LL[]
  color: string
  width: number
  zIndex: number
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
