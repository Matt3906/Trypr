import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { MdTerrain } from 'react-icons/md'
import { config } from '@/config'
import { ensureGoogleMapsLoaded, hasMapsKey, mapsReady as isMapsReady } from '@/services/googleMapsLoader'
import { Spinner } from '@/components/ui'
import {
  boundsOf, distPointToSegmentSq, distanceMetersToPath, haversineMeters, pathDistanceMeters, pathSignature, projectOnSegment, samplePath,
  type LL,
} from '@/lib/routing/geo'
import { latOf, lonOf, num, type PointMap, type RouteComputation } from '@/lib/routing/types'
import { calculateRouteForSegment, normalizeSegmentRoutingTypeFor, segmentLatLngs, segmentRouteTimeoutMs, straightRoute } from '@/lib/routing/segmentRouter'
import { emptyOverlays, type ModeOverlays } from '@/lib/routing/adventureOverlays'
import { iconBadge, numberedIcon, viaDotIcon } from './markerIcons'
import { mapStyleForMode, normalizeMapMode, standardRouteColor } from './mapStyles'
import { OverlayManager, type MarkerDef, type PolyDef } from './overlays'
import { ProjectionHelper } from './projection'
import RouteComputingOverlay from './RouteComputingOverlay'
import MapPreview3D, { PREVIEW_H, PREVIEW_TRI_H, PREVIEW_W } from './MapPreview3D'
import { useAdventureOverlays } from './useAdventureOverlays'

export interface MapEmbedProps {
  points: PointMap[]
  secondaryPoints?: PointMap[]
  onMapTap?: (lat: number, lon: number) => void
  onPointTap?: (point: PointMap) => void
  onRouteSummary?: (distanceMeters: number, durationSeconds: number) => void
  onRouteGeometry?: (geometry: { lat: number; lon: number; lng: number }[]) => void
  onRouteInstructions?: (lines: string[]) => void
  onRouteSegmentDetails?: (segments: PointMap[]) => void
  onTransitArrivalStop?: (stop: PointMap) => void
  onRouteComputingChanged?: (computing: boolean) => void
  onRouteError?: (message: string) => void
  focusedRouteStep?: PointMap | null
  initialRouteGeometry?: PointMap[]
  initialRouteInstructions?: string[]
  initialRouteSegmentDetails?: PointMap[]
  preferInitialRouteData?: boolean
  transportMode?: string
  segmentTransportModes?: string[]
  routeVia?: PointMap[]
  segmentRoutingTypes?: string[]
  onRouteTapAddVia?: (afterIndex: number, lat: number, lon: number) => void
  onViaDragEnd?: (viaIndex: number, lat: number, lon: number) => void
  onViaTapDelete?: (viaIndex: number) => void
  onHikingCampsiteTap?: (campsite: PointMap) => void
  onPortageAccessTap?: (accessPoint: PointMap) => void
  disableDefaultUi?: boolean
  disableGestures?: boolean
  zoomControlsEnabled?: boolean
  showNearbyContextOverlays?: boolean
  minZoom?: number
  maxZoom?: number
  routeComputingBannerTop?: number
  activeStopIndex?: number | null
  portageExperienceLevel?: string
}

const sigOf = (pts: PointMap[]) =>
  pts.map((p) => `${latOf(p).toFixed(6)},${lonOf(p).toFixed(6)}|${p.kind ?? ''}|${p.category ?? ''}|${p.name ?? ''};`).join('')

const viaSig = (via: PointMap[]) =>
  via.map((v) => `${Math.trunc(num(v.afterIndex ?? -1))}:${num(v.lat).toFixed(6)},${num(v.lon).toFixed(6)};`).join('')

const boolish = (v: unknown, fallback: boolean): boolean => {
  if (typeof v === 'boolean') return v
  if (typeof v === 'number') return v !== 0
  if (typeof v === 'string') {
    const n = v.trim().toLowerCase()
    if (['true', 'yes', '1'].includes(n)) return true
    if (['false', 'no', '0'].includes(n)) return false
  }
  return fallback
}

const toLL = (p: PointMap): LL => ({ lat: latOf(p), lng: lonOf(p) })

function ghostIcon(dragging: boolean): google.maps.Icon {
  const a = dragging ? 0.7 : 0.45
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="34" height="34"><circle cx="17" cy="17" r="12" fill="rgba(21,101,192,${a})" stroke="#fff" stroke-width="2.5"/></svg>`
  return { url: `data:image/svg+xml;charset=UTF-8,${encodeURIComponent(svg)}`, scaledSize: new google.maps.Size(34, 34), anchor: new google.maps.Point(17, 17) }
}

export default function MapEmbed(props: MapEmbedProps) {
  const propsRef = useRef(props)
  propsRef.current = props
  const {
    points, secondaryPoints = [], routeVia = [], transportMode = 'car', segmentTransportModes = [], segmentRoutingTypes = [],
    showNearbyContextOverlays = true, minZoom = 3, maxZoom = 18, routeComputingBannerTop = 12, disableGestures, disableDefaultUi, zoomControlsEnabled,
  } = props

  const containerRef = useRef<HTMLDivElement>(null)
  const mapRef = useRef<google.maps.Map | null>(null)
  const overlaysRef = useRef<OverlayManager | null>(null)
  const projRef = useRef<ProjectionHelper | null>(null)
  const [ready, setReady] = useState(false)
  const [mapObj, setMapObj] = useState<google.maps.Map | null>(null)

  const seqRef = useRef(0)
  const segGeometry = useRef<Map<number, LL[]>>(new Map())
  const lastRouteCalcSig = useRef('')
  const lastBlockingGaps = useRef(false)
  const lastErrorSig = useRef('')
  const suppressTapUntil = useRef(0)
  const currentZoom = useRef(2)
  const routePolyCount = useRef(0)

  const [computing, setComputing] = useState(false)
  const computingShownAt = useRef(0)
  const computingHideTimer = useRef<ReturnType<typeof setTimeout>>(undefined)
  const [anchors, setAnchors] = useState<{ start: { x: number; y: number } | null; target: { x: number; y: number } | null; seed: number }>({ start: null, target: null, seed: 0.5 })

  const [preview, setPreview] = useState<{ point: PointMap; px: { x: number; y: number } | null } | null>(null)
  const previewLL = useRef<LL | null>(null)

  const ghostRef = useRef<{ ll: LL; seg: number } | null>(null)
  const ghostTimer = useRef<ReturnType<typeof setTimeout>>(undefined)

  // ---------- mode helpers ----------
  const segmentMode = useCallback(
    (i: number) => {
      const fallback = normalizeMapMode(transportMode)
      if (i < 0 || i >= segmentTransportModes.length) return fallback
      return normalizeMapMode(segmentTransportModes[i])
    },
    [transportMode, segmentTransportModes],
  )
  const segmentRoutingType = useCallback(
    (i: number) => {
      const mode = segmentMode(i)
      if (i < 0) return 'calculated'
      if (i >= segmentRoutingTypes.length) return normalizeSegmentRoutingTypeFor('', mode)
      return normalizeSegmentRoutingTypeFor(segmentRoutingTypes[i], mode)
    },
    [segmentMode, segmentRoutingTypes],
  )
  const shouldUseVia = useCallback((i: number) => i >= 0 && !['train', 'plane'].includes(segmentMode(i)), [segmentMode])
  const modeMatchesAnySegment = useCallback(
    (mode: string) => {
      const target = normalizeMapMode(mode)
      const segments = points.length > 1 ? points.length - 1 : 0
      if (segments <= 0) return normalizeMapMode(transportMode) === target
      for (let i = 0; i < segments; i++) if (segmentMode(i) === target) return true
      return false
    },
    [points.length, transportMode, segmentMode],
  )
  const usesTerrain = useMemo(() => {
    const mode = normalizeMapMode(transportMode)
    if (mode === 'hiking' || mode === 'portaging') return true
    const segments = points.length > 1 ? points.length - 1 : 0
    for (let i = 0; i < segments; i++) {
      const m = segmentMode(i)
      if (m === 'hiking' || m === 'portaging') return true
    }
    return false
  }, [transportMode, points.length, segmentMode])

  const segmentPoints = useCallback(
    (afterIndex: number): PointMap[] => {
      if (points.length < 2 || afterIndex < 0 || afterIndex >= points.length - 1) return []
      const out: PointMap[] = [points[afterIndex]]
      if (shouldUseVia(afterIndex)) {
        for (const v of routeVia) {
          if (Math.trunc(num(v.afterIndex ?? -1)) !== afterIndex) continue
          out.push({ lat: num(v.lat), lon: num(v.lon), name: 'Via' })
        }
      }
      out.push(points[afterIndex + 1])
      return out
    },
    [points, routeVia, shouldUseVia],
  )

  const routeCalculationSignature = useCallback(
    () =>
      [
        points.map((p) => `${latOf(p).toFixed(6)},${lonOf(p).toFixed(6)};`).join(''),
        normalizeMapMode(transportMode),
        segmentTransportModes.map(normalizeMapMode).join(','),
        Array.from({ length: Math.max(0, points.length - 1) }, (_, i) => segmentRoutingType(i)).join(','),
        viaSig(routeVia),
      ].join('|'),
    [points, transportMode, segmentTransportModes, routeVia, segmentRoutingType],
  )

  // ---------- route-computing indicator ----------
  const MIN_VISIBLE_MS = 1100
  const setRouteComputing = useCallback((value: boolean, seq: number) => {
    if (seq !== seqRef.current) return
    if (value) {
      clearTimeout(computingHideTimer.current)
      computingShownAt.current = Date.now()
      setComputing((was) => {
        if (!was) propsRef.current.onRouteComputingChanged?.(true)
        return true
      })
      return
    }
    const remaining = MIN_VISIBLE_MS - (Date.now() - computingShownAt.current)
    const hide = () => {
      setComputing((was) => {
        if (was) propsRef.current.onRouteComputingChanged?.(false)
        return false
      })
      setAnchors((a) => ({ ...a, start: null, target: null }))
    }
    clearTimeout(computingHideTimer.current)
    if (remaining > 0) computingHideTimer.current = setTimeout(hide, remaining)
    else hide()
  }, [])

  const updateComputingAnchors = useCallback(() => {
    const proj = projRef.current
    const c = containerRef.current
    const pts = propsRef.current.points
    if (!proj || !c || pts.length < 2) return
    const s = toLL(pts[0]), t = toLL(pts[1])
    const sp = proj.toPixel(s), tp = proj.toPixel(t)
    if (!sp || !tp) return
    const w = c.clientWidth, h = c.clientHeight
    const clampP = (p: { x: number; y: number }) => ({ x: Math.min(Math.max(p.x, 18), w - 18), y: Math.min(Math.max(p.y, 18), h - 18) })
    const basis = Math.abs(s.lat) * 13 + Math.abs(s.lng) * 7 + Math.abs(t.lat) * 5 + Math.abs(t.lng) * 11
    const seed = Math.min(0.86, Math.max(0.14, basis - Math.floor(basis)))
    setAnchors({ start: clampP(sp), target: clampP(tp), seed })
  }, [])

  // ---------- adventure overlays (hiking trails / portage network) ----------
  const adventure = useAdventureOverlays({
    mapRef, ready, propsRef, segGeometry, modeMatchesAnySegment, segmentMode, segmentPoints, currentZoom, seqRef, suppressTapUntil,
    showNearbyContextOverlays, points, overlays: overlaysRef, rerouteGaps: () => { lastRouteCalcSig.current = ''; void updateRoutePolylineRef.current(seqRef.current) },
    lastBlockingGaps,
  })
  const adventureRef = useRef(adventure)
  adventureRef.current = adventure

  // ---------- route polylines ----------
  const emitGeometry = useCallback((geo: Map<number, LL[]>) => {
    const cb = propsRef.current.onRouteGeometry
    if (!cb) return
    const out: { lat: number; lon: number; lng: number }[] = []
    for (const seg of [...geo.keys()].sort((a, b) => a - b)) {
      for (const p of geo.get(seg) ?? []) {
        const last = out[out.length - 1]
        if (last && Math.abs(last.lat - p.lat) < 1e-7 && Math.abs(last.lon - p.lng) < 1e-7) continue
        out.push({ lat: p.lat, lon: p.lng, lng: p.lng })
      }
    }
    cb(out)
  }, [])

  const routeDefs = (routes: Map<number, RouteComputation>): PolyDef[] => {
    const defs: PolyDef[] = []
    for (const [seg, r] of routes) {
      if (r.styledSegments?.length) {
        r.styledSegments.forEach((s, i) => {
          if (s.path.length >= 2) defs.push({ id: `seg_${seg}_style_${i}`, path: s.path, color: s.color, width: s.width, zIndex: s.zIndex })
        })
      } else {
        defs.push({ id: `seg_${seg}`, path: r.path, color: r.color, width: r.width, zIndex: r.zIndex, geodesic: r.geodesic, dashed: r.dashed, opacity: r.opacity })
      }
    }
    return defs
  }

  const applyInitialRouteData = useCallback(
    (seq: number): boolean => {
      const p = propsRef.current
      if (!p.preferInitialRouteData || showNearbyContextOverlays) return false
      const path: LL[] = []
      for (const pt of p.initialRouteGeometry ?? []) {
        const lat = num(pt.lat), lon = num(pt.lon ?? pt.lng)
        if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue
        const last = path[path.length - 1]
        if (last && Math.abs(lat - last.lat) < 1e-7 && Math.abs(lon - last.lng) < 1e-7) continue
        path.push({ lat, lng: lon })
      }
      if (path.length < 2) return false

      const mode = normalizeMapMode(transportMode)
      const instructions = (p.initialRouteInstructions ?? []).map((l) => l.trim()).filter(Boolean).slice(0, 8)
      const segCount = points.length > 1 ? points.length - 1 : 0
      const geometry = new Map<number, LL[]>()
      if (segCount === 1) geometry.set(0, path)
      else if (segCount > 1) {
        const targets = points.map(toLL)
        const boundary = [0]
        let searchStart = 0
        for (let i = 1; i < targets.length - 1; i++) {
          let best = searchStart, bestD = Infinity
          for (let j = searchStart; j < path.length; j++) {
            const d = haversineMeters(targets[i], path[j])
            if (d < bestD) { bestD = d; best = j }
          }
          boundary.push(best)
          searchStart = best
        }
        boundary.push(path.length - 1)
        for (let seg = 0; seg < segCount; seg++) {
          const s = boundary[seg], e = boundary[seg + 1]
          geometry.set(seg, e <= s ? [targets[seg], targets[seg + 1]] : path.slice(s, e + 1))
        }
      }

      segGeometry.current = geometry
      p.onRouteInstructions?.(instructions)
      p.onRouteSegmentDetails?.(p.initialRouteSegmentDetails ?? [])
      if (seq !== seqRef.current) return true
      const color = standardRouteColor(mode)
      const width = mode === 'hiking' || mode === 'portaging' ? 6 : 4
      const defs: PolyDef[] = [...geometry.entries()].map(([k, pts]) => ({ id: `cached_route_${k}`, path: pts, color, width, zIndex: 2, opacity: 0.9 }))
      overlaysRef.current?.syncPolylines('route', defs)
      routePolyCount.current = defs.length
      adventureRef.current.clearAll()
      const total = pathDistanceMeters(path)
      if (total > 0) p.onRouteSummary?.(total, 0)
      lastRouteCalcSig.current = routeCalculationSignature()
      lastBlockingGaps.current = false
      lastErrorSig.current = ''
      setRouteComputing(false, seq)
      return true
    },
    [points, transportMode, showNearbyContextOverlays, routeCalculationSignature, setRouteComputing],
  )

  const updateRoutePolyline = useCallback(
    async (seq: number) => {
      const sig = routeCalculationSignature()
      const expected = points.length > 1 ? points.length - 1 : 0
      if (lastRouteCalcSig.current === sig && (expected === 0 || routePolyCount.current >= expected || lastBlockingGaps.current)) return
      if (applyInitialRouteData(seq)) return

      setRouteComputing(true, seq)
      const alive = () => seq === seqRef.current
      const ov = overlaysRef.current
      try {
        if (points.length < 2) {
          segGeometry.current = new Map()
          emitGeometry(segGeometry.current)
          ov?.syncPolylines('route', [])
          routePolyCount.current = 0
          const p = propsRef.current
          p.onRouteInstructions?.([])
          p.onRouteSegmentDetails?.([])
          p.onRouteSummary?.(0, 0)
          lastRouteCalcSig.current = sig
          lastBlockingGaps.current = false
          lastErrorSig.current = ''
          return
        }

        // Warm adventure caches (portage network) before the per-segment loop.
        if (showNearbyContextOverlays && modeMatchesAnySegment('portaging')) await adventureRef.current.prewarmPortage()
        if (!alive()) return

        const routes = new Map<number, RouteComputation>()
        const geo = new Map<number, LL[]>()
        const segDist = new Map<number, number>()
        const segDur = new Map<number, number>()
        const instructions: string[] = []
        const segmentDetails: PointMap[] = []
        let distSum = 0, durSum = 0
        let lastArrival: PointMap | null = null
        const fallbackSegs = new Map<number, { segPoints: PointMap[]; mode: string; segType: string }>()
        const unresolvedPortage = new Map<number, PointMap[]>()

        for (let seg = 0; seg < points.length - 1; seg++) {
          if (!alive()) return
          const segPts = segmentPoints(seg)
          if (segPts.length < 2) continue
          const mode = segmentMode(seg)
          const segType = segmentRoutingType(seg)
          const fallbackPath = segmentLatLngs(segPts)

          let route: RouteComputation | null = null
          try {
            route = await Promise.race([
              calculateRouteForSegment({ segmentIndex: seg, segPoints: segPts, mode, segType }),
              new Promise<null>((r) => setTimeout(() => { console.debug(`segmentRoute timeout segment=${seg} mode=${mode}`); r(null) }, segmentRouteTimeoutMs(mode))),
            ])
          } catch (e) {
            console.debug(`segmentRoute failed segment=${seg} mode=${mode}`, e)
          }
          if (!alive()) return

          if (!route && config.strictRouting && segType !== 'direct' && mode !== 'plane') {
            throw new Error(`STRICT_ROUTING_HARD_ERROR segment_route_unavailable segment=${seg} mode=${mode} segType=${segType}`)
          }
          const hidePortageFallback = !route && mode === 'portaging' && segType !== 'direct'
          const computed =
            route ??
            straightRoute({ path: fallbackPath, mode, color: standardRouteColor(mode), opacity: 0.72, width: 4, geodesic: mode === 'plane' })
          if (!route && (mode === 'portaging' || mode === 'hiking') && segType !== 'direct') fallbackSegs.set(seg, { segPoints: segPts, mode, segType })
          if (hidePortageFallback) {
            unresolvedPortage.set(seg, [...segPts])
            geo.set(seg, fallbackPath)
            continue
          }

          routes.set(seg, computed)
          geo.set(seg, computed.path)
          segDist.set(seg, computed.distanceMeters)
          segDur.set(seg, computed.durationSeconds)
          distSum += computed.distanceMeters
          durSum += computed.durationSeconds
          instructions.push(...computed.instructions)
          if (computed.stepDetails.length) {
            segmentDetails.push({
              segmentIndex: seg, mode, distanceMeters: computed.distanceMeters, durationSeconds: computed.durationSeconds,
              steps: computed.stepDetails, ...(computed.arrivalStop ? { arrivalStop: computed.arrivalStop } : {}),
            })
          }
          if (computed.arrivalStop) lastArrival = computed.arrivalStop
        }

        segGeometry.current = geo
        emitGeometry(geo)

        if (routes.size === 0 && points.length >= 2 && unresolvedPortage.size === 0) {
          const fm = normalizeMapMode(transportMode)
          const fb = straightRoute({ path: points.map(toLL), mode: fm, color: standardRouteColor(fm), opacity: 0.82, width: fm === 'hiking' || fm === 'portaging' ? 6 : 4, geodesic: fm === 'plane' })
          routes.set(-1, fb)
          geo.set(0, fb.path)
          distSum = fb.distanceMeters
          durSum = fb.durationSeconds
        }

        let blockingGap = unresolvedPortage.size > 0
        const deferSummary = fallbackSegs.size > 0 || blockingGap

        const p = propsRef.current
        const last8 = instructions.slice(0, 8)
        p.onRouteInstructions?.(last8)
        p.onRouteSegmentDetails?.(segmentDetails)
        p.onTransitArrivalStop?.(lastArrival ?? {})

        if (!alive()) return
        ov?.syncPolylines('route', routeDefs(routes))
        routePolyCount.current = routes.size
        if (!deferSummary && distSum > 0) p.onRouteSummary?.(distSum, durSum)

        // Adventure overlays (trails / campsites / water network) for hiking & portaging.
        if (showNearbyContextOverlays) {
          await adventureRef.current.refreshAfterRoute(geo)
          if (!alive()) return
        }

        // Retry adventure fallbacks once more now that overlay caches are warm.
        if (fallbackSegs.size > 0) {
          let retriedAny = false
          for (const [seg, info] of fallbackSegs) {
            if (!alive()) break
            let retried: RouteComputation | null = null
            try {
              retried = await Promise.race([
                adventureRef.current.retryRoute(info.segPoints, info.mode, info.segType),
                new Promise<null>((r) => setTimeout(() => r(null), 10000)),
              ])
            } catch (e) {
              console.debug(`adventureRetry failed segment=${seg}`, e)
            }
            if (!retried || !alive()) {
              if (normalizeMapMode(info.mode) === 'portaging') unresolvedPortage.set(seg, [...info.segPoints])
              continue
            }
            distSum -= segDist.get(seg) ?? 0
            durSum -= segDur.get(seg) ?? 0
            geo.set(seg, retried.path)
            segDist.set(seg, retried.distanceMeters)
            segDur.set(seg, retried.durationSeconds)
            distSum += retried.distanceMeters
            durSum += retried.durationSeconds
            routes.set(seg, retried)
            unresolvedPortage.delete(seg)
            retriedAny = true
          }
          if (retriedAny && alive()) {
            segGeometry.current = geo
            emitGeometry(geo)
            ov?.syncPolylines('route', routeDefs(routes))
            routePolyCount.current = routes.size
          }
        }

        blockingGap = unresolvedPortage.size > 0
        if (blockingGap) {
          const first = [...unresolvedPortage.keys()].sort((a, b) => a - b)[0]
          const failed = unresolvedPortage.get(first)!
          const label = (pt: PointMap | undefined, fb: string) => {
            if (!pt) return fb
            const name = String(pt.name ?? pt.title ?? '').trim()
            if (name) return name
            return latOf(pt) === 0 && lonOf(pt) === 0 ? fb : `${latOf(pt).toFixed(4)}, ${lonOf(pt).toFixed(4)}`
          }
          const esig = `${sig}:portage:${first}`
          if (esig !== lastErrorSig.current) {
            lastErrorSig.current = esig
            p.onRouteError?.(`Site inaccessible: no mapped waterway or portage connection could be found from ${label(failed[0], 'start point')} to ${label(failed[failed.length - 1], 'destination')}.`)
          }
        } else {
          lastErrorSig.current = ''
        }
        if (deferSummary && !blockingGap && alive() && distSum > 0) p.onRouteSummary?.(distSum, durSum)

        if (showNearbyContextOverlays && modeMatchesAnySegment('gas_stops')) {
          try {
            const gas = await adventureRef.current.buildGasStops(geo)
            if (!alive()) return
            adventureRef.current.setGasLayer(gas)
          } catch (e) {
            console.debug('gasStopOverlays failed', e)
          }
        }

        if (!alive()) return
        lastRouteCalcSig.current = sig
        lastBlockingGaps.current = blockingGap
      } finally {
        setRouteComputing(false, seq)
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [points, transportMode, segmentTransportModes, segmentRoutingTypes, routeVia, showNearbyContextOverlays, applyInitialRouteData, routeCalculationSignature, segmentMode, segmentRoutingType, segmentPoints, modeMatchesAnySegment, emitGeometry, setRouteComputing],
  )
  const updateRoutePolylineRef = useRef(updateRoutePolyline)
  updateRoutePolylineRef.current = updateRoutePolyline

  // ---------- camera ----------
  const fitCamera = useCallback(() => {
    const map = mapRef.current
    if (!map) return
    const pts = overlaysRef.current?.markerPositions(['main', 'secondary', 'via']) ?? []
    const b = boundsOf(pts)
    if (!b) return
    if (pts.length === 1) {
      map.setCenter(pts[0])
      map.setZoom(12)
    } else {
      map.fitBounds({ south: b.south, west: b.west, north: b.north, east: b.east }, 48)
    }
    currentZoom.current = map.getZoom() ?? currentZoom.current
  }, [])

  const hidePreview = useCallback(() => {
    previewLL.current = null
    setPreview(null)
  }, [])

  const updatePreviewPosition = useCallback(() => {
    const target = previewLL.current
    const proj = projRef.current
    const c = containerRef.current
    if (!target || !proj || !c) return
    const px = proj.toPixel(target)
    if (!px) return
    const w = c.clientWidth, h = c.clientHeight
    let left = px.x - PREVIEW_W / 2
    let top = px.y - PREVIEW_H - PREVIEW_TRI_H
    left = Math.min(Math.max(left, 12), Math.max(12, w - PREVIEW_W - 12))
    top = Math.min(Math.max(top, 12), Math.max(12, h - PREVIEW_H - PREVIEW_TRI_H - 12))
    setPreview((p) => (p ? { ...p, px: { x: left, y: top } } : p))
  }, [])

  const showPreviewFor = useCallback(
    (point: PointMap) => {
      const lat = latOf(point), lon = lonOf(point)
      if (lat === 0 && lon === 0) return
      previewLL.current = { lat, lng: lon }
      setPreview({ point, px: null })
      setTimeout(updatePreviewPosition, 50)
    },
    [updatePreviewPosition],
  )

  const focusPoint = useCallback(
    (p: LL) => {
      const map = mapRef.current
      if (!map) return
      map.panTo(p)
      map.setZoom(Math.min(Math.max(14, minZoom), maxZoom))
      setTimeout(updatePreviewPosition, 350)
    },
    [minZoom, maxZoom, updatePreviewPosition],
  )

  // ---------- markers ----------
  const rebuildMarkers = useCallback(() => {
    const ov = overlaysRef.current
    if (!ov) return
    const p = propsRef.current
    const primary = '#4aade8'
    let next = 1
    const stopNumbers = points.map((pt) => (boolish(pt.isStop, true) ? next++ : null))

    const mkTap = (pt: PointMap, ll: LL) => () => {
      suppressTapUntil.current = Date.now() + 900
      focusPoint(ll)
      showPreviewFor(pt)
      p.onPointTap?.(pt)
    }

    const main: MarkerDef[] = points.map((pt, i) => {
      const ll = toLL(pt)
      const n = stopNumbers[i]
      const name = String(pt.name ?? '').trim()
      return {
        id: `main_${i}`, position: ll, icon: n == null ? viaDotIcon() : numberedIcon(n, primary),
        title: name || (n != null ? `Stop ${n}` : 'Waypoint'), onClick: mkTap(pt, ll), zIndex: 10,
      }
    })
    const secondary: MarkerDef[] = secondaryPoints.map((pt, i) => {
      const ll = toLL(pt)
      const kind = String(pt.kind ?? ''), category = String(pt.category ?? '')
      const name = String(pt.name ?? '')
      return { id: `secondary_${i}`, position: ll, icon: iconBadge(kind, category), title: name || category || 'Point', onClick: mkTap(pt, ll), zIndex: 8 }
    })
    const via: MarkerDef[] = []
    routeVia.forEach((v, i) => {
      const after = Math.trunc(num(v.afterIndex ?? -1))
      if (!shouldUseVia(after)) return
      const lat = num(v.lat), lon = num(v.lon)
      const origin = { lat, lng: lon }
      via.push({
        id: `via_${i}`, position: origin, icon: viaDotIcon(), opacity: 0.85, draggable: !!p.onViaDragEnd, zIndex: 9,
        onClick: () => {
          suppressTapUntil.current = Date.now() + 900
          p.onViaTapDelete?.(i)
          hidePreview()
        },
        onDragEnd: (pos) => {
          suppressTapUntil.current = Date.now() + 900
          if (Math.abs(pos.lat - origin.lat) < 0.0002 && Math.abs(pos.lng - origin.lng) < 0.0002) {
            p.onViaTapDelete?.(i)
            hidePreview()
            return
          }
          p.onViaDragEnd?.(i, pos.lat, pos.lng)
        },
      })
    })
    ov.syncMarkers('main', main)
    ov.syncMarkers('secondary', secondary)
    ov.syncMarkers('via', via)
  }, [points, secondaryPoints, routeVia, shouldUseVia, focusPoint, showPreviewFor, hidePreview])

  // ---------- ghost via (Garmin-style route shaping) ----------
  const nearestPointOnRoute = useCallback(
    (cursor: LL): { point: LL; seg: number; distSq: number } | null => {
      if (points.length < 2) return null
      let bestD = Infinity, bestP = cursor, bestSeg = 0
      for (let seg = 0; seg < points.length - 1; seg++) {
        const geom = segGeometry.current.get(seg)
        const pairs: [LL, LL][] = []
        if (geom && geom.length >= 2) for (let j = 0; j < geom.length - 1; j++) pairs.push([geom[j], geom[j + 1]])
        else pairs.push([toLL(points[seg]), toLL(points[seg + 1])])
        for (const [a, b] of pairs) {
          const d = distPointToSegmentSq(cursor, a, b)
          if (d < bestD) { bestD = d; bestP = projectOnSegment(cursor, a, b); bestSeg = seg }
        }
      }
      return { point: bestP, seg: bestSeg, distSq: bestD }
    },
    [points],
  )

  const nearestSegmentAfterIndex = useCallback(
    (tap: LL, maxDeg = 0.008): number => {
      const r = nearestPointOnRoute(tap)
      if (!r) return -1
      return Math.sqrt(r.distSq) > maxDeg ? -1 : r.seg
    },
    [nearestPointOnRoute],
  )

  const showGhost = useCallback((g: { ll: LL; seg: number } | null) => {
    ghostRef.current = g
    const ov = overlaysRef.current
    if (!ov) return
    if (!g) {
      ov.syncMarkers('ghost', [])
      return
    }
    ov.syncMarkers('ghost', [
      {
        id: 'ghost', position: g.ll, icon: ghostIcon(false), draggable: true, zIndex: 50,
        onClick: () => {
          const cur = ghostRef.current
          if (!cur) return
          showGhost(null)
          propsRef.current.onRouteTapAddVia?.(cur.seg, cur.ll.lat, cur.ll.lng)
        },
        onDragEnd: (pos) => {
          const cur = ghostRef.current
          showGhost(null)
          if (cur) propsRef.current.onRouteTapAddVia?.(cur.seg, pos.lat, pos.lng)
        },
      },
    ])
  }, [])

  // ---------- map lifecycle ----------
  useEffect(() => {
    let cancelled = false
    ensureGoogleMapsLoaded().then(() => {
      if (!cancelled && isMapsReady()) setReady(true)
    })
    return () => { cancelled = true }
  }, [])

  useEffect(() => {
    if (!ready || !containerRef.current || mapRef.current) return
    const map = new google.maps.Map(containerRef.current, {
      center: { lat: 0, lng: 0 },
      zoom: 2,
      mapTypeId: usesTerrain ? 'terrain' : 'roadmap',
      styles: mapStyleForMode(normalizeMapMode(transportMode)),
      minZoom, maxZoom,
      disableDefaultUI: !!disableDefaultUi,
      zoomControl: !!zoomControlsEnabled && !disableDefaultUi,
      mapTypeControl: false, streetViewControl: false, fullscreenControl: false, rotateControl: false,
      gestureHandling: disableGestures ? 'none' : 'greedy',
      clickableIcons: false,
    })
    mapRef.current = map
    overlaysRef.current = new OverlayManager(map)
    projRef.current = new ProjectionHelper(map)
    setMapObj(map)

    map.addListener('zoom_changed', () => { currentZoom.current = map.getZoom() ?? currentZoom.current })
    map.addListener('bounds_changed', () => {
      if (previewLL.current) updatePreviewPosition()
      updateComputingAnchors()
      if (ghostRef.current) showGhost(null)
    })
    map.addListener('click', (e: google.maps.MapMouseEvent) => {
      hidePreview()
      const p = propsRef.current
      if (p.disableGestures || !e.latLng) return
      if (Date.now() < suppressTapUntil.current) return
      const ll = { lat: e.latLng.lat(), lng: e.latLng.lng() }
      const ghost = ghostRef.current
      if (ghost && p.onRouteTapAddVia) {
        showGhost(null)
        p.onRouteTapAddVia(ghost.seg, ghost.ll.lat, ghost.ll.lng)
        return
      }
      if (p.onRouteTapAddVia && p.points.length >= 2) {
        const after = nearestSegmentRef.current(ll)
        if (after >= 0) {
          p.onRouteTapAddVia(after, ll.lat, ll.lng)
          return
        }
      }
      p.onMapTap?.(ll.lat, ll.lng)
    })
    map.addListener('mousemove', (e: google.maps.MapMouseEvent) => {
      clearTimeout(ghostTimer.current)
      const p = propsRef.current
      if (!p.onRouteTapAddVia || p.points.length < 2 || !e.latLng) {
        if (ghostRef.current) showGhost(null)
        return
      }
      const cursor = { lat: e.latLng.lat(), lng: e.latLng.lng() }
      ghostTimer.current = setTimeout(() => {
        const r = nearestPointRef.current(cursor)
        if (!r) return showGhost(null)
        // ~30px proximity at any zoom: 360/256 ≈ 1.40625 → 42° / 2^zoom
        const threshold = 42 / Math.pow(2, currentZoom.current)
        if (Math.sqrt(r.distSq) < threshold) showGhost({ ll: r.point, seg: r.seg })
        else showGhost(null)
      }, 40)
    })
    map.addListener('mouseout', () => { clearTimeout(ghostTimer.current) })
    map.addListener('idle', () => { updateComputingAnchors(); adventureRef.current.onCameraIdle() })

    return () => {
      clearTimeout(ghostTimer.current)
      clearTimeout(computingHideTimer.current)
      overlaysRef.current?.dispose()
      projRef.current?.dispose()
      google.maps.event.clearInstanceListeners(map)
      mapRef.current = null
      overlaysRef.current = null
      projRef.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready])

  // Latest-callback refs for listeners registered once.
  const nearestSegmentRef = useRef(nearestSegmentAfterIndex)
  nearestSegmentRef.current = nearestSegmentAfterIndex
  const nearestPointRef = useRef(nearestPointOnRoute)
  nearestPointRef.current = nearestPointOnRoute

  // Keep style / terrain / zoom limits in sync with props.
  useEffect(() => {
    const map = mapRef.current
    if (!map) return
    map.setOptions({
      mapTypeId: usesTerrain ? 'terrain' : 'roadmap',
      styles: mapStyleForMode(normalizeMapMode(transportMode)),
      minZoom, maxZoom,
      gestureHandling: disableGestures ? 'none' : 'greedy',
    })
  }, [mapObj, usesTerrain, transportMode, minZoom, maxZoom, disableGestures])

  // Rebuild markers + routes whenever the inputs change.
  const mainSig = sigOf(points)
  const secSig = sigOf(secondaryPoints)
  const modeSig = `${normalizeMapMode(transportMode)}|${segmentTransportModes.map(normalizeMapMode).join(',')}|${viaSig(routeVia)}|${segmentRoutingTypes.join(',')}|${showNearbyContextOverlays}|${props.preferInitialRouteData}`
  const prevMainSig = useRef('')
  useEffect(() => {
    if (!ready || !mapObj) return
    const seq = ++seqRef.current
    rebuildMarkers()
    if (prevMainSig.current !== mainSig || prevMainSig.current === '') fitCamera()
    prevMainSig.current = mainSig
    adventureRef.current.resetSignatures()
    void updateRoutePolylineRef.current(seq).then(() => {
      if (seq !== seqRef.current) return
      if (prevMainSig.current === mainSig) fitCamera()
      adventureRef.current.scheduleRefresh(true)
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, mapObj, mainSig, secSig, modeSig])

  // Focused route-step highlight.
  const focusSig = props.focusedRouteStep
    ? [props.focusedRouteStep.requestId ?? '', props.focusedRouteStep.headline ?? '', num(props.focusedRouteStep.focusLat ?? props.focusedRouteStep.lat).toFixed(5), num(props.focusedRouteStep.focusLon ?? props.focusedRouteStep.lon ?? props.focusedRouteStep.lng).toFixed(5), Array.isArray(props.focusedRouteStep.path) ? props.focusedRouteStep.path.length : 0].join('|')
    : ''
  useEffect(() => {
    const ov = overlaysRef.current
    const map = mapRef.current
    if (!ov || !map) return
    const step = propsRef.current.focusedRouteStep
    if (!step || !focusSig) {
      ov.clearLayer('focus')
      return
    }
    const path: LL[] = []
    for (const pt of Array.isArray(step.path) ? step.path : []) {
      const lat = num(pt.lat), lon = num(pt.lon ?? pt.lng)
      if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue
      const last = path[path.length - 1]
      if (last && Math.abs(last.lat - lat) < 1e-7 && Math.abs(last.lng - lon) < 1e-7) continue
      path.push({ lat, lng: lon })
    }
    const fLat = num(step.focusLat ?? step.lat), fLon = num(step.focusLon ?? step.lon ?? step.lng)
    const focus: LL | null = Number.isFinite(fLat) && Number.isFinite(fLon) && (fLat || fLon) ? { lat: fLat, lng: fLon } : path.length ? path[Math.floor(path.length / 2)] : null
    if (!focus) { ov.clearLayer('focus'); return }

    const mode = normalizeMapMode(String(step.mode ?? ''))
    const hex = String(step.lineColor ?? '').trim().replace('#', '')
    const accent = hex.length === 6 ? `#${hex}` : standardRouteColor(mode)
    ov.syncPolylines('focus', path.length >= 2 ? [{ id: 'focus_step_path', path, color: accent, width: 8, zIndex: 70, opacity: 0.96 }] : [])
    ov.syncMarkers('focus', [{ id: 'focus_step_marker', position: focus, zIndex: 71, icon: iconBadge('route_step', mode) }])

    const zoomReq = num(step.focusZoom)
    const zoom = Math.min(maxZoom, Math.max(minZoom, zoomReq > 0 ? zoomReq : 14))
    const b = path.length >= 2 ? boundsOf(path) : null
    const shouldFit = b && pathDistanceMeters(path) > 140 && (Math.abs(b.north - b.south) > 1e-4 || Math.abs(b.east - b.west) > 1e-4)
    if (shouldFit && b) map.fitBounds({ south: b.south, west: b.west, north: b.north, east: b.east }, 72)
    else { map.panTo(focus); map.setZoom(zoom) }

    const t = setTimeout(() => ov.clearLayer('focus'), 1500)
    return () => clearTimeout(t)
  }, [focusSig, mapObj, minZoom, maxZoom])

  // Recompute the computing-overlay anchors while visible.
  useEffect(() => {
    if (computing) {
      const t = setTimeout(updateComputingAnchors, 140)
      return () => clearTimeout(t)
    }
  }, [computing, mainSig, updateComputingAnchors])

  // ---------- render ----------
  if (!hasMapsKey()) {
    return (
      <div className="center" style={{ padding: 12, textAlign: 'center', height: '100%' }}>
        Google Maps is not configured. Set VITE_GOOGLE_MAPS_API_KEY in frontend/.env.local and rebuild.
      </div>
    )
  }
  if (!ready) {
    return <div className="center" style={{ height: '100%' }}><Spinner /></div>
  }

  const hasPortage = adventure.canRenderPortage
  const hasHiking = adventure.canRenderHiking
  const headline =
    modeMatchesAnySegment('portaging') && !modeMatchesAnySegment('hiking') ? 'Tracing connected waterways'
    : modeMatchesAnySegment('hiking') ? 'Scanning trail network'
    : modeMatchesAnySegment('train') ? 'Linking transit segments'
    : 'Locking route geometry'
  const detail =
    modeMatchesAnySegment('portaging') && !modeMatchesAnySegment('hiking') ? 'Sweeping for viable carries, shoreline landings, and uninterrupted water access.'
    : modeMatchesAnySegment('hiking') ? 'Matching your stops to mapped trails, campsites, and realistic backcountry connectors.'
    : modeMatchesAnySegment('train') ? 'Resolving the cleanest sequence of stations, transfers, and arrival timing.'
    : 'Committing each leg, mode, and stop order into one continuous route.'

  const loadTop = Math.min(220, Math.max(16, (routeComputingBannerTop < 0 ? 16 : routeComputingBannerTop) + 44))
  const idleLabel = hasPortage && !hasHiking ? 'View nearby portage routes & campsites' : 'View nearby trails & campsites'
  const loadingLabel = hasPortage && !hasHiking ? 'Loading portage routes...' : 'Loading trails & campsites...'

  return (
    <div className="map-embed">
      <div ref={containerRef} className="map-canvas" />
      {computing && (
        <RouteComputingOverlay headline={headline} detail={detail} topOffset={routeComputingBannerTop < 0 ? 16 : routeComputingBannerTop} start={anchors.start} target={anchors.target} curveSeed={anchors.seed} />
      )}
      {(adventure.showLoadButton || adventure.loading) && (
        <button type="button" className="map-load-btn" style={{ top: loadTop }} disabled={adventure.loading} onClick={() => void adventure.loadForViewport()}>
          {adventure.loading ? <Spinner size="sm" /> : <MdTerrain size={18} />}
          {adventure.loading ? loadingLabel : idleLabel}
        </button>
      )}
      {preview?.px && previewLL.current && (
        <div style={{ position: 'absolute', left: preview.px.x, top: preview.px.y, zIndex: 2, pointerEvents: 'none' }}>
          <MapPreview3D lat={previewLL.current.lat} lon={previewLL.current.lng} title={String(preview.point.name ?? preview.point.title ?? 'Location')} region={String(preview.point.region ?? preview.point.country ?? preview.point.subtitle ?? '').trim()} />
        </div>
      )}
    </div>
  )
}

export { distanceMetersToPath, pathSignature, samplePath, emptyOverlays }
export type { ModeOverlays }
