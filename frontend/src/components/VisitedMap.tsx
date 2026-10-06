import { useEffect, useRef, useState } from 'react'
import { ensureGoogleMapsLoaded, hasMapsKey, mapsReady } from '@/services/googleMapsLoader'
import { Spinner } from '@/components/ui'

interface Ring { pts: google.maps.LatLngLiteral[]; minLat: number; maxLat: number; minLng: number; maxLng: number }

const CENTROIDS: Record<string, [number, number]> = {
  'United States': [39.8283, -98.5795], Canada: [56.1304, -106.3468], Mexico: [23.6345, -102.5528], Brazil: [-14.235, -51.9253],
  Argentina: [-38.4161, -63.6167], 'United Kingdom': [55.3781, -3.436], France: [46.2276, 2.2137], Germany: [51.1657, 10.4515],
  Italy: [41.8719, 12.5674], Spain: [40.4637, -3.7492], Portugal: [39.3999, -8.2245], Netherlands: [52.1326, 5.2913],
  Belgium: [50.5039, 4.4699], Switzerland: [46.8182, 8.2275], Austria: [47.5162, 14.5501], Sweden: [60.1282, 18.6435],
  Norway: [60.472, 8.4689], Finland: [61.9241, 25.7482], Denmark: [56.2639, 9.5018], Poland: [51.9194, 19.1451],
  'Czech Republic': [49.8175, 15.473], Hungary: [47.1625, 19.5033], Greece: [39.0742, 21.8243], Turkey: [38.9637, 35.2433],
  Russia: [61.524, 105.3188], China: [35.8617, 104.1954], Japan: [36.2048, 138.2529], 'South Korea': [35.9078, 127.7669],
  India: [20.5937, 78.9629], Pakistan: [30.3753, 69.3451], Bangladesh: [23.685, 90.3563], Australia: [-25.2744, 133.7751],
  'New Zealand': [-40.9006, 174.886], 'South Africa': [-30.5595, 22.9375], Egypt: [26.8206, 30.8025], Nigeria: [9.082, 8.6753],
  Kenya: [-0.0236, 37.9062], Morocco: [31.7917, -7.0926], Algeria: [28.0339, 1.6596], 'Saudi Arabia': [23.8859, 45.0792],
  'United Arab Emirates': [23.4241, 53.8478], Israel: [31.0461, 34.8516], Lebanon: [33.8547, 35.8623], Indonesia: [-0.7893, 113.9213],
  Philippines: [12.8797, 121.774], Vietnam: [14.0583, 108.2772], Thailand: [15.87, 100.9925], Malaysia: [4.2105, 101.9758],
  Singapore: [1.3521, 103.8198],
}

const STOP_WORDS = new Set(['of', 'the', 'and', 'republic', 'federation', 'kingdom'])
/** Same normalisation the Flutter app used, so existing `visitedCountries` data keeps matching. */
export const keyForMatching = (s: string) =>
  s.toLowerCase().replace(/[^a-z0-9]/g, ' ').split(/\s+/).filter((t) => t && !STOP_WORDS.has(t)).join(' ')
export const normalizeCountryName = (s: string) =>
  s.trim().split(/\s+/).filter(Boolean).map((w) => w[0].toUpperCase() + w.slice(1).toLowerCase()).join(' ')

let indexPromise: Promise<Map<string, Ring[]>> | null = null
function loadCountryIndex(): Promise<Map<string, Ring[]>> {
  if (indexPromise) return indexPromise
  indexPromise = (async () => {
    const index = new Map<string, Ring[]>()
    try {
      const js = await (await fetch('/countries.geojson')).json()
      for (const feat of js.features ?? []) {
        try {
          const props = feat.properties ?? {}
          const rawName = String(props.ADMIN ?? props.admin ?? props.NAME ?? props.name ?? props.COUNTRY ?? props.country ?? '')
          const geom = feat.geometry
          if (!rawName || !geom) continue
          const toRing = (coords: any[]): Ring | null => {
            const pts: google.maps.LatLngLiteral[] = []
            let minLat = 90, maxLat = -90, minLng = 180, maxLng = -180
            for (const p of coords) {
              if (!Array.isArray(p) || p.length < 2) continue
              const lng = Number(p[0]), lat = Number(p[1])
              pts.push({ lat, lng })
              minLat = Math.min(minLat, lat); maxLat = Math.max(maxLat, lat); minLng = Math.min(minLng, lng); maxLng = Math.max(maxLng, lng)
            }
            return pts.length ? { pts, minLat, maxLat, minLng, maxLng } : null
          }
          const rings: Ring[] = []
          if (geom.type === 'Polygon' && geom.coordinates?.length) {
            const r = toRing(geom.coordinates[0])
            if (r) rings.push(r)
          } else if (geom.type === 'MultiPolygon') {
            for (const poly of geom.coordinates ?? []) {
              const r = poly?.length ? toRing(poly[0]) : null
              if (r) rings.push(r)
            }
          }
          if (rings.length) index.set(keyForMatching(rawName), rings)
        } catch {
          /* ignore per-feature failures */
        }
      }
    } catch {
      /* leave index empty */
    }
    return index
  })()
  return indexPromise
}

function pointInRing(lat: number, lng: number, ring: Ring): boolean {
  if (lat < ring.minLat || lat > ring.maxLat || lng < ring.minLng || lng > ring.maxLng) return false
  let inside = false
  const pts = ring.pts
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const xi = pts[i].lng, yi = pts[i].lat, xj = pts[j].lng, yj = pts[j].lat
    if (yi > lat !== yj > lat && lng < ((xj - xi) * (lat - yi)) / (yj - yi + 0.0) + xi) inside = !inside
  }
  return inside
}

/** World map where tapping a country marks it as visited. */
export default function VisitedMap({ visited, onAdd, height = 460 }: { visited: Set<string>; onAdd: (displayName: string) => void; height?: number }) {
  const el = useRef<HTMLDivElement>(null)
  const mapRef = useRef<google.maps.Map | null>(null)
  const overlays = useRef<(google.maps.Polygon | google.maps.Marker)[]>([])
  const indexRef = useRef<Map<string, Ring[]> | null>(null)
  const onAddRef = useRef(onAdd)
  const visitedRef = useRef(visited)
  onAddRef.current = onAdd
  visitedRef.current = visited
  const [state, setState] = useState<'loading' | 'ready' | 'nokey'>(hasMapsKey() ? 'loading' : 'nokey')
  const [indexReady, setIndexReady] = useState(false)

  useEffect(() => {
    if (!hasMapsKey()) return
    let cancelled = false
    ;(async () => {
      await ensureGoogleMapsLoaded()
      if (cancelled || !el.current || !mapsReady()) return
      const map = new google.maps.Map(el.current, {
        center: { lat: 20, lng: 0 }, zoom: 2, minZoom: 2, maxZoom: 18, mapTypeControl: false, streetViewControl: false,
        fullscreenControl: false, rotateControl: false, zoomControl: true, clickableIcons: false,
      })
      mapRef.current = map
      map.addListener('click', (e: google.maps.MapMouseEvent) => {
        const idx = indexRef.current
        if (!idx || !e.latLng) return
        const lat = e.latLng.lat(), lng = e.latLng.lng()
        for (const [key, rings] of idx) {
          if (rings.some((r) => pointInRing(lat, lng, r))) {
            const display = normalizeCountryName(key)
            if (!visitedRef.current.has(display)) onAddRef.current(display)
            return
          }
        }
      })
      setState('ready')
      indexRef.current = await loadCountryIndex()
      if (!cancelled) setIndexReady(true)
    })()
    return () => {
      cancelled = true
    }
  }, [])

  // Draw visited countries (polygons only for visited; markers when we have no polygon).
  useEffect(() => {
    const map = mapRef.current
    if (!map || state !== 'ready') return
    overlays.current.forEach((o) => o.setMap(null))
    overlays.current = []
    const idx = indexRef.current
    for (const name of visited) {
      const rings = idx?.get(keyForMatching(name))
      if (rings) {
        for (const ring of rings) {
          overlays.current.push(new google.maps.Polygon({ map, paths: ring.pts, fillColor: '#4aade8', fillOpacity: 0.28, strokeColor: '#4aade8', strokeOpacity: 0.55, strokeWeight: 1, clickable: false }))
        }
      } else {
        const c = CENTROIDS[name.trim()]
        if (c) overlays.current.push(new google.maps.Marker({ map, position: { lat: c[0], lng: c[1] }, icon: 'https://maps.google.com/mapfiles/ms/icons/green-dot.png' }))
      }
    }
  }, [visited, state, indexReady])

  if (state === 'nokey') {
    return <div className="center muted" style={{ height, textAlign: 'center', padding: 16 }}>Google Maps is not configured. Set VITE_GOOGLE_MAPS_API_KEY in frontend/.env.local.</div>
  }
  return (
    <div style={{ position: 'relative', height }}>
      <div ref={el} style={{ position: 'absolute', inset: 0 }} />
      {(state === 'loading' || !indexReady) && (
        <div style={{ position: 'absolute', top: 8, left: 8, display: 'flex', alignItems: 'center', gap: 6, padding: '6px 10px', borderRadius: 999, background: 'rgba(255,255,255,0.92)', fontSize: 12 }}>
          <Spinner size="sm" /> {state === 'loading' ? 'Loading map…' : 'Loading countries…'}
        </div>
      )}
    </div>
  )
}
