import type { LL } from '@/lib/routing/geo'

export interface PolyDef {
  id: string
  path: LL[]
  color: string
  width: number
  zIndex?: number
  geodesic?: boolean
  dashed?: { dash: number; gap: number } | null
  opacity?: number
}

export interface MarkerDef {
  id: string
  position: LL
  icon?: google.maps.Icon | google.maps.Symbol | string
  title?: string
  /** HTML shown in an info window when the marker is clicked. */
  infoHtml?: string
  draggable?: boolean
  opacity?: number
  zIndex?: number
  onClick?: () => void
  onDragEnd?: (pos: LL) => void
}

/**
 * Syncs declarative polyline/marker definitions onto a google.maps.Map. Each layer key owns its own
 * set of objects so independent layers (route, mode overlays, focused-step highlight, ...) never clobber each other.
 */
export class OverlayManager {
  private polys = new Map<string, Map<string, google.maps.Polyline>>()
  private markers = new Map<string, Map<string, { marker: google.maps.Marker; sig: string }>>()
  private info: google.maps.InfoWindow | null = null

  constructor(private map: google.maps.Map) {}

  private polySig = (d: PolyDef) =>
    `${d.color}|${d.width}|${d.zIndex ?? 0}|${d.geodesic ? 1 : 0}|${d.opacity ?? 1}|${d.dashed ? `${d.dashed.dash},${d.dashed.gap}` : ''}|${d.path.length}|${d.path[0]?.lat}|${d.path[d.path.length - 1]?.lat}`

  syncPolylines(layer: string, defs: PolyDef[]) {
    let cur = this.polys.get(layer)
    if (!cur) this.polys.set(layer, (cur = new Map()))
    const wanted = new Set(defs.map((d) => d.id))
    for (const [id, p] of cur) {
      if (!wanted.has(id)) {
        p.setMap(null)
        cur.delete(id)
      }
    }
    for (const d of defs) {
      const existing = cur.get(d.id)
      const options: google.maps.PolylineOptions = {
        path: d.path,
        strokeColor: d.color,
        strokeWeight: d.width,
        strokeOpacity: d.dashed ? 0 : d.opacity ?? 1,
        zIndex: d.zIndex ?? 1,
        geodesic: !!d.geodesic,
        clickable: false,
        icons: d.dashed
          ? [{
              icon: { path: 'M 0,-1 0,1', strokeOpacity: d.opacity ?? 1, strokeColor: d.color, strokeWeight: d.width, scale: 1 },
              offset: '0',
              repeat: `${d.dashed.dash + d.dashed.gap}px`,
            }]
          : [],
      }
      if (existing) {
        existing.setOptions(options)
      } else {
        cur.set(d.id, new google.maps.Polyline({ ...options, map: this.map }))
      }
    }
  }

  syncMarkers(layer: string, defs: MarkerDef[]) {
    let cur = this.markers.get(layer)
    if (!cur) this.markers.set(layer, (cur = new Map()))
    const wanted = new Set(defs.map((d) => d.id))
    for (const [id, m] of cur) {
      if (!wanted.has(id)) {
        google.maps.event.clearInstanceListeners(m.marker)
        m.marker.setMap(null)
        cur.delete(id)
      }
    }
    for (const d of defs) {
      const sig = `${d.position.lat},${d.position.lng}|${typeof d.icon === 'string' ? d.icon : (d.icon as any)?.url ?? ''}|${d.opacity ?? 1}|${d.draggable ? 1 : 0}|${d.title ?? ''}|${d.infoHtml ?? ''}`
      const existing = cur.get(d.id)
      if (existing && existing.sig === sig) continue
      if (existing) {
        google.maps.event.clearInstanceListeners(existing.marker)
        existing.marker.setMap(null)
      }
      const marker = new google.maps.Marker({
        map: this.map,
        position: d.position,
        icon: d.icon as any,
        title: d.title,
        draggable: !!d.draggable,
        opacity: d.opacity ?? 1,
        zIndex: d.zIndex,
      })
      if (d.onClick || d.infoHtml) {
        marker.addListener('click', () => {
          if (d.infoHtml) {
            this.info ??= new google.maps.InfoWindow()
            this.info.setContent(d.infoHtml)
            this.info.open({ map: this.map, anchor: marker })
          }
          d.onClick?.()
        })
      }
      if (d.onDragEnd) {
        marker.addListener('dragend', () => {
          const p = marker.getPosition()
          if (p) d.onDragEnd!({ lat: p.lat(), lng: p.lng() })
        })
      }
      cur.set(d.id, { marker, sig })
    }
  }

  clearLayer(layer: string) {
    this.syncPolylines(layer, [])
    this.syncMarkers(layer, [])
  }

  openInfoFor(layer: string, id: string) {
    const entry = this.markers.get(layer)?.get(id)
    if (entry) google.maps.event.trigger(entry.marker, 'click')
  }

  markerPositions(layers: string[]): LL[] {
    const out: LL[] = []
    for (const l of layers) {
      for (const { marker } of this.markers.get(l)?.values() ?? []) {
        const p = marker.getPosition()
        if (p) out.push({ lat: p.lat(), lng: p.lng() })
      }
    }
    return out
  }

  dispose() {
    for (const layer of [...this.polys.keys(), ...this.markers.keys()]) this.clearLayer(layer)
    this.info?.close()
  }
}
