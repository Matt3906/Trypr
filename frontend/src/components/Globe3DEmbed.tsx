import { useCallback, useEffect, useRef, useState } from 'react'
import { config } from '@/config'
import { Spinner } from '@/components/ui'
import { latOf, lonOf, type PointMap } from '@/lib/routing/types'

interface Props {
  points?: PointMap[]
  secondaryPoints?: PointMap[]
  routeGeometry?: PointMap[]
  onMapTap?: (lat: number, lon: number) => void
  onRouteSummary?: (distanceMeters: number, durationSeconds: number) => void
  /** Transport mode forwarded to the globe's Directions request. */
  transportMode?: string
}

function normalizeMode(mode: string): string {
  const m = mode.trim()
  if (!m) return 'DRIVING'
  switch (m.toLowerCase()) {
    case 'drive': case 'driving': return 'DRIVING'
    case 'walk': case 'walking': case 'portaging': case 'canoe': case 'canoeing': case 'portage': return 'WALKING'
    case 'bike': case 'bicycling': case 'bicycle': return 'BICYCLING'
    case 'train': case 'rail': case 'public_transit': case 'public transit': case 'transit': return 'TRANSIT'
  }
  return m.toUpperCase()
}

function normalizePoints(input: PointMap[], includeMeta: boolean) {
  const out: PointMap[] = []
  for (const p of input) {
    const lat = latOf(p), lon = lonOf(p)
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue
    const n: PointMap = { lat, lon, lng: lon }
    const name = String(p.name ?? p.title ?? '').trim()
    if (name) n.name = name
    if (includeMeta) {
      const kind = String(p.kind ?? '').trim()
      const category = String(p.category ?? '').trim()
      if (kind) n.kind = kind
      if (category) n.category = category
    }
    out.push(n)
  }
  return out
}

/** Renders the prebuilt Earth 3D globe (/earth) in an iframe and talks to it over postMessage. */
export default function Globe3DEmbed({ points = [], secondaryPoints = [], routeGeometry = [], onMapTap, onRouteSummary, transportMode = 'DRIVING' }: Props) {
  const iframeRef = useRef<HTMLIFrameElement>(null)
  const [ready, setReady] = useState(false)
  const readyRef = useRef(false)
  const retry = useRef(0)
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined)
  const [src, setSrc] = useState(() => buildSrc(0))
  const cbs = useRef({ onMapTap, onRouteSummary })
  cbs.current = { onMapTap, onRouteSummary }

  function buildSrc(pathIndex: number) {
    const base = pathIndex === 0 ? '/earth/index.html' : '/earth/index.html'
    const key = config.googleMapsApiKey
    const cb = Date.now()
    return key ? `${base}?embed=true&gmapsKey=${encodeURIComponent(key)}&cb=${cb}` : `${base}?embed=true&cb=${cb}`
  }

  const sendPoints = useCallback(() => {
    const win = iframeRef.current?.contentWindow
    if (!readyRef.current || !win) return
    const pts = normalizePoints(points, false)
    const sec = normalizePoints(secondaryPoints, true)
    const route = pts.length ? normalizePoints(routeGeometry, false) : []
    if (!pts.length && !sec.length && !route.length) {
      win.postMessage({ type: 'clearRoute' }, window.location.origin)
      return
    }
    win.postMessage({ type: 'setPoints', points: pts, secondaryPoints: sec, routeGeometry: route, transportMode: normalizeMode(transportMode) }, window.location.origin)
  }, [points, secondaryPoints, routeGeometry, transportMode])

  const scheduleReadyTimeout = useCallback(() => {
    clearTimeout(timer.current)
    timer.current = setTimeout(() => {
      if (readyRef.current) return
      if (retry.current < 2) {
        retry.current++
        setSrc(buildSrc(retry.current === 1 ? 1 : 0))
      } else {
        readyRef.current = true
        setReady(true)
      }
    }, 10000)
  }, [])

  useEffect(() => {
    const onMsg = (e: MessageEvent) => {
      if (e.source !== iframeRef.current?.contentWindow) return
      const d = e.data
      if (!d || typeof d !== 'object') return
      switch (d.type) {
        case 'mapTap':
          cbs.current.onMapTap?.(Number(d.lat), Number(d.lng))
          break
        case 'routeSummary':
          cbs.current.onRouteSummary?.(Number(d.distanceMeters), Number(d.durationSeconds))
          break
        case 'map_ready':
          clearTimeout(timer.current)
          if (!readyRef.current) {
            readyRef.current = true
            setReady(true)
          }
          break
      }
    }
    window.addEventListener('message', onMsg)
    return () => {
      window.removeEventListener('message', onMsg)
      clearTimeout(timer.current)
    }
  }, [])

  // Send whenever the ready flag flips or any input changes (deep-compared via JSON key).
  const key = JSON.stringify([normalizePoints(points, false), normalizePoints(secondaryPoints, true), normalizePoints(routeGeometry, false).length, normalizeMode(transportMode)])
  useEffect(() => {
    if (ready) sendPoints()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, key])

  return (
    <div style={{ position: 'relative', width: '100%', height: '100%' }}>
      <iframe ref={iframeRef} src={src} title="Trypr 3D Globe" allow="fullscreen" style={{ width: '100%', height: '100%', border: 0, display: 'block' }} onLoad={scheduleReadyTimeout} />
      {!ready && (
        <div className="center col gap-md" style={{ position: 'absolute', inset: 0, background: 'rgba(10,10,26,.8)', pointerEvents: 'none', color: 'rgba(255,255,255,.54)', fontSize: 13 }}>
          <Spinner white />
          Loading 3D Globe…
        </div>
      )}
    </div>
  )
}
