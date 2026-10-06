import { useEffect, useRef } from 'react'
import { MdMap } from 'react-icons/md'
import { ensureGoogleMapsLoaded, hasMapsKey, mapsReady } from '@/services/googleMapsLoader'
import { normalizeRouteMode, readRouteGeometry, simplifyRouteGeometry } from '@/lib/routeCache'
import { numberedIcon } from './map/markerIcons'

const MODE_COLORS: Record<string, string> = {
  flying: '#3949ab', train: '#546e7a', walking: '#00897b', biking: '#1565c0', hiking: '#8e24aa', portaging: '#d81b60', driving: '#1e88e5',
}

interface Props {
  waypoints: any[]
  routeGeometry?: any[]
  transportMode?: string
  segmentTransportModes?: string[]
}

/** Non-interactive route thumbnail (Google Maps) used on trip cards. */
export default function MapPreview({ waypoints, routeGeometry = [], transportMode = 'car', segmentTransportModes = [] }: Props) {
  const ref = useRef<HTMLDivElement>(null)

  const wpts = waypoints
    .map((w) => ({ lat: Number(w?.lat ?? w?.latitude ?? w?.locationLat), lng: Number(w?.lon ?? w?.longitude ?? w?.lng ?? w?.locationLon) }))
    .filter((p) => Number.isFinite(p.lat) && Number.isFinite(p.lng))
  const cached = simplifyRouteGeometry(readRouteGeometry(routeGeometry), 160).map((p) => ({ lat: p.lat, lng: p.lon }))
  const route = cached.length ? cached : wpts
  const active = (segmentTransportModes.map(normalizeRouteMode)[0]) ?? normalizeRouteMode(transportMode)
  const color = MODE_COLORS[active] ?? MODE_COLORS.driving
  const sig = JSON.stringify([wpts, route.length, route[0], route[route.length - 1], color])

  useEffect(() => {
    if (!wpts.length && !route.length) return
    let cancelled = false
    let map: google.maps.Map | null = null
    ensureGoogleMapsLoaded().then(() => {
      if (cancelled || !ref.current || !mapsReady()) return
      map = new google.maps.Map(ref.current, {
        center: route[0] ?? wpts[0], zoom: 3, disableDefaultUI: true, gestureHandling: 'none', keyboardShortcuts: false, clickableIcons: false,
      })
      if (route.length > 1) {
        new google.maps.Polyline({ map, path: route, strokeColor: '#fff', strokeOpacity: 0.7, strokeWeight: 5 })
        new google.maps.Polyline({ map, path: route, strokeColor: color, strokeOpacity: 0.9, strokeWeight: 3 })
      }
      wpts.forEach((p, i) => new google.maps.Marker({ map: map!, position: p, icon: numberedIcon(i + 1, color), title: `Stop ${i + 1}` }))
      const all = [...route, ...wpts]
      if (all.length === 1) map.setZoom(12)
      else {
        const b = new google.maps.LatLngBounds()
        all.forEach((p) => b.extend(p))
        map.fitBounds(b, 48)
      }
    })
    return () => { cancelled = true; map = null }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sig])

  if (!wpts.length && !route.length) {
    return <div className="center" style={{ height: '100%', background: '#eee' }}><MdMap size={36} color="rgba(0,0,0,.26)" /></div>
  }
  if (!hasMapsKey()) return <div style={{ height: '100%', background: '#e5eef5' }} />
  return <div ref={ref} style={{ width: '100%', height: '100%', background: '#e5eef5', pointerEvents: 'none' }} />
}
