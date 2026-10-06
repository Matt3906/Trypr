import type { MarkerDef, PolyDef } from '@/components/map/overlays'
import type { LL } from './geo'

export interface ModeOverlays {
  polylines: PolyDef[]
  markers: MarkerDef[]
  trailSegments?: number
  campsiteMarkers?: number
  trailheadMarkers?: number
}

export const emptyOverlays = (): ModeOverlays => ({ polylines: [], markers: [] })

export type SegmentGeometry = Map<number, LL[]>
