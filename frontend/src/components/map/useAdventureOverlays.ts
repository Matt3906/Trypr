import { useCallback, useRef, useState, type MutableRefObject } from 'react'
import {
  boundsOf, distanceLineToPathMeters, distanceMetersToPath, downsampleLine, haversineMeters, pathDistanceMeters, pathSignature, samplePath, type LL,
} from '@/lib/routing/geo'
import { hasAvailableOverpassEndpoint } from '@/lib/routing/overpass'
import {
  getHikingOverlayEntry, getPortagingOverlayEntry, hikingCacheKey, loadSegmentedPortagingOverlayEntry, nearestCachedPortagingFocusEntry, portageState,
  portagingCacheRef, portagingFocusCacheKey, portagingRouteCacheKey, quantizedOverlayPadDegrees, roundToStepExport, type PortagingOverlayEntry,
} from '@/lib/routing/overlayData'
import { isFresh, OVERLAY_CACHE_TTL_MS } from '@/lib/routing/graph'
import { latOf, lonOf, type PointMap, type RouteComputation } from '@/lib/routing/types'
import { routeViaTrailGraph } from '@/lib/routing/trailGraph'
import { routeViaPortageGraph } from '@/lib/routing/portageGraph'
import { ensureGoogleMapsLoaded } from '@/services/googleMapsLoader'
import { campsiteTriangleIcon, portageAccessIcon, trailheadIcon } from './markerIcons'
import type { MarkerDef, OverlayManager, PolyDef } from './overlays'
import type { MapEmbedProps } from './MapEmbed'
import { normalizeMapMode } from './mapStyles'

const MIN_ZOOM: Record<string, number> = { portaging: 10.8, hiking: 11.5 }
const nearestToLines = (point: LL, lines: LL[][]) => {
  let best = Infinity
  for (const l of lines) {
    if (!l.length) continue
    const m = distanceMetersToPath(point, l)
    if (m < best) best = m
    if (best <= 1) break
  }
  return best
}
const toLL = (p: PointMap): LL => ({ lat: latOf(p), lng: lonOf(p) })
const infoHtml = (title: string, snippet: string) =>
  `<div style="font-family:Inter,sans-serif"><div style="font-weight:700">${title.replace(/</g, '&lt;')}</div><div style="color:#555;font-size:12px">${snippet.replace(/</g, '&lt;')}</div></div>`

interface Viewport { center: LL; hikingAnchors: LL[]; portagingPadDegrees: number; signature: string }

interface Args {
  mapRef: MutableRefObject<google.maps.Map | null>
  ready: boolean
  propsRef: MutableRefObject<MapEmbedProps>
  segGeometry: MutableRefObject<Map<number, LL[]>>
  modeMatchesAnySegment: (mode: string) => boolean
  segmentMode: (i: number) => string
  segmentPoints: (i: number) => PointMap[]
  currentZoom: MutableRefObject<number>
  seqRef: MutableRefObject<number>
  suppressTapUntil: MutableRefObject<number>
  showNearbyContextOverlays: boolean
  points: PointMap[]
  overlays: MutableRefObject<OverlayManager | null>
  rerouteGaps: () => void
  lastBlockingGaps: MutableRefObject<boolean>
}

export interface GasResult { markers: MarkerDef[] }

export function useAdventureOverlays(a: Args) {
  const { mapRef, propsRef, segGeometry, modeMatchesAnySegment, segmentMode, segmentPoints, currentZoom, showNearbyContextOverlays, points, overlays } = a
  const [showLoadButton, setShowLoadButton] = useState(false)
  const [loading, setLoading] = useState(false)
  const refs = useRef({ lastSig: '', pendingSig: '', autoLoadSig: '', inFlight: false, timer: undefined as ReturnType<typeof setTimeout> | undefined, campOpened: false })
  const placesService = useRef<google.maps.places.PlacesService | null>(null)
  const gasCache = useRef(new Map<string, any[]>())

  const shouldRenderMode = useCallback((mode: string) => modeMatchesAnySegment(mode) && currentZoom.current >= (MIN_ZOOM[normalizeMapMode(mode)] ?? Infinity), [modeMatchesAnySegment, currentZoom])
  const canOffer = useCallback(() => showNearbyContextOverlays && (shouldRenderMode('hiking') || shouldRenderMode('portaging')), [showNearbyContextOverlays, shouldRenderMode])

  // ---- anchor / geometry helpers ----
  const anchorPathForMode = useCallback((mode: string): LL[] => {
    const target = normalizeMapMode(mode)
    const out: LL[] = []
    for (let seg = 0; seg < Math.max(0, points.length - 1); seg++) {
      if (segmentMode(seg) !== target) continue
      for (const p of segmentPoints(seg)) {
        const ll = toLL(p)
        if (!Number.isFinite(ll.lat) || !Number.isFinite(ll.lng)) continue
        const last = out[out.length - 1]
        if (last && Math.abs(last.lat - ll.lat) < 1e-7 && Math.abs(last.lng - ll.lng) < 1e-7) continue
        out.push(ll)
      }
    }
    return out
  }, [points, segmentMode, segmentPoints])

  const flattenRouteForMode = useCallback((geo: Map<number, LL[]>, mode: string): LL[] => {
    const wanted = normalizeMapMode(mode)
    const out: LL[] = []
    for (const seg of [...geo.keys()].sort((x, y) => x - y)) {
      if (segmentMode(seg) !== wanted) continue
      for (const p of geo.get(seg) ?? []) {
        const last = out[out.length - 1]
        if (last && Math.abs(last.lat - p.lat) < 1e-7 && Math.abs(last.lng - p.lng) < 1e-7) continue
        out.push(p)
      }
    }
    return out
  }, [segmentMode])

  const hikingAnchorPath = useCallback((geo: Map<number, LL[]>): LL[] => {
    const route = flattenRouteForMode(geo, 'hiking')
    if (route.length) return route
    return points.map(toLL).filter((p) => Number.isFinite(p.lat) && Number.isFinite(p.lng))
  }, [flattenRouteForMode, points])

  const focusOn = useCallback((p: LL) => {
    const map = mapRef.current
    if (!map) return
    a.suppressTapUntil.current = Date.now() + 900
    map.panTo(p)
    map.setZoom(Math.max(map.getZoom() ?? 0, 14))
  }, [mapRef, a.suppressTapUntil])

  // ---- hiking overlay ----
  const buildHiking = useCallback(async (geo: Map<number, LL[]>, overlayAnchors?: LL[]) => {
    const routePath = overlayAnchors?.length ? overlayAnchors : hikingAnchorPath(geo)
    if (!routePath.length) return { polys: [] as PolyDef[], markers: [] as MarkerDef[] }
    const entry = await getHikingOverlayEntry({ cacheKey: hikingCacheKey(routePath), routePath })
    if (!entry) return { polys: [], markers: [] }

    const polys: PolyDef[] = []
    entry.trailLines.forEach((line, i) => {
      if (line.length < 2) return
      const rendered = downsampleLine(line, 280)
      if (rendered.length >= 2) polys.push({ id: `trail_${i}`, path: rendered, width: 4, color: '#2e7d32', zIndex: 40 })
    })
    const camps = entry.campsites
      .map((camp) => {
        const point = { lat: Number(camp.lat), lng: Number(camp.lon) }
        return { camp, point, km: distanceMetersToPath(point, routePath) / 1000 }
      })
      .sort((x, y) => x.km - y.km)
    const markers: MarkerDef[] = camps.map(({ camp, point, km }, i) => ({
      id: `camp_${i}`, position: point, icon: campsiteTriangleIcon(), infoHtml: infoHtml(String(camp.name ?? 'Campsite'), `${km.toFixed(1)} km from route`),
      onClick: () => {
        focusOn(point)
        propsRef.current.onHikingCampsiteTap?.({ ...camp, name: String(camp.name ?? 'Campsite'), lat: point.lat, lon: point.lng, distanceKmFromRoute: km, mode: 'hiking' })
      },
    }))
    const heads = entry.trailheads
      .map((head) => {
        const point = { lat: Number(head.lat), lng: Number(head.lon) }
        return { head, point, km: distanceMetersToPath(point, routePath) / 1000 }
      })
      .sort((x, y) => x.km - y.km)
    let headCount = 0
    heads.forEach(({ head, point, km }, i) => {
      if (headCount >= 40) return
      if (headCount >= 16 && km > 2.5) return
      headCount++
      markers.push({ id: `trailhead_${i}`, position: point, icon: trailheadIcon(), infoHtml: infoHtml(String(head.name ?? 'Trailhead'), `${km.toFixed(1)} km from route`) })
    })
    return { polys, markers }
  }, [hikingAnchorPath, focusOn, propsRef])

  // ---- portaging overlay ----
  const buildPortaging = useCallback(async (geo: Map<number, LL[]>, opts: { focusPointOverride?: LL; focusPadDegreesOverride?: number; preferFocusOnly?: boolean } = {}) => {
    const empty = { polys: [] as PolyDef[], markers: [] as MarkerDef[] }
    const p = propsRef.current
    let fallbackFocus: LL | null = null
    if (points.length) {
      const idx = p.activeStopIndex
      const raw = idx != null && idx > 0 && idx < points.length ? points[idx] : points[points.length - 1]
      const ll = toLL(raw)
      fallbackFocus = Number.isFinite(ll.lat) && Number.isFinite(ll.lng) ? ll : null
    }
    const focus = opts.focusPointOverride ?? fallbackFocus
    if (!focus) return empty

    const fullRoute = flattenRouteForMode(geo, 'portaging')
    const routePath = fullRoute.length ? fullRoute : opts.preferFocusOnly && opts.focusPointOverride ? [opts.focusPointOverride] : []
    const modeAnchors = anchorPathForMode('portaging')
    const distancePath = routePath.length ? routePath : modeAnchors.length ? modeAnchors : [focus]
    const routeMeters = distancePath.length >= 2 ? pathDistanceMeters(distancePath) : 0
    const skipBroad = !opts.preferFocusOnly && (points.length >= 5 || routeMeters > 25000)
    const routeFetchAnchors = opts.preferFocusOnly ? [] : modeAnchors.length >= 2 ? modeAnchors : routePath.length >= 2 ? routePath : []
    const routeCacheKey = routeFetchAnchors.length >= 2 ? portagingRouteCacheKey(routeFetchAnchors) : ''
    const routePad = 0.12
    const exp = p.portageExperienceLevel
    const expPad = exp === 'intermediate' ? 0.135 : exp === 'advanced' ? 0.2 : 0.1
    const focusPad = quantizedOverlayPadDegrees(opts.focusPadDegreesOverride ?? expPad)

    let entry: PortagingOverlayEntry | null = null
    const useSegmented = routePath.length >= 2 && (opts.preferFocusOnly || skipBroad)
    if (useSegmented) {
      if (hasAvailableOverpassEndpoint()) {
        const segPad = quantizedOverlayPadDegrees(Math.min(0.14, Math.max(0.08, focusPad * (opts.preferFocusOnly ? 0.78 : 0.88))))
        entry = await loadSegmentedPortagingOverlayEntry({
          routePath, modeAnchors, focusPoint: focus, padDegrees: segPad, includeCampsites: true, maxFocusQueries: opts.preferFocusOnly ? 4 : 5, logPrefix: 'portagingOverlays',
        })
      }
    } else if (routeCacheKey) {
      entry = await getPortagingOverlayEntry({ cacheKey: routeCacheKey, anchors: routeFetchAnchors, padDegrees: routePad })
    }
    if (!entry) {
      entry = await getPortagingOverlayEntry({ cacheKey: portagingFocusCacheKey(focus, focusPad), anchors: [focus], focusPoint: focus, padDegrees: focusPad })
    }
    if (!entry) entry = nearestCachedPortagingFocusEntry(focus, Math.max(0.12, focusPad + 0.04))
    if (entry && !entry.campsites.length && routePath.length) {
      const fe = await getPortagingOverlayEntry({ cacheKey: portagingFocusCacheKey(focus, focusPad), anchors: [focus], focusPoint: focus, padDegrees: focusPad })
      if (fe && fe.campsites.length > entry.campsites.length) entry = fe
    }
    if (!entry) return empty
    primePortageCaches(entry, !!opts.preferFocusOnly)

    const MAX_WATER = 400, MAX_PORTAGE = 60
    const polys: PolyDef[] = []
    const waterCands: { index: number; dist: number; rendered: LL[] }[] = []
    entry.waterLines.forEach((line, i) => {
      if (line.length < 2) return
      const near = routePath.length ? distanceLineToPathMeters(line, routePath, 20) : distanceMetersToPath(focus, line)
      if (routePath.length && near > 7000) return
      if (!routePath.length && near > 35000) return
      const rendered = downsampleLine(line, 280)
      if (rendered.length >= 2) waterCands.push({ index: i, dist: near, rendered })
    })
    waterCands.sort((x, y) => x.dist - y.dist)
    waterCands.slice(0, MAX_WATER).forEach((c) => polys.push({ id: `portage_water_${c.index}`, path: c.rendered, width: 3, color: '#1e88e5', opacity: 0.62, zIndex: 33 }))
    await new Promise((r) => setTimeout(r, 0))

    const portageCands: { index: number; dist: number; rendered: LL[] }[] = []
    entry.portageLines.forEach((line, i) => {
      if (line.length < 2) return
      const near = routePath.length ? distanceLineToPathMeters(line, routePath, 20) : distanceMetersToPath(focus, line)
      if (routePath.length && near > 7000) return
      if (!routePath.length && near > 35000) return
      const rendered = downsampleLine(line, 320)
      if (rendered.length >= 2) portageCands.push({ index: i, dist: near, rendered })
    })
    portageCands.sort((x, y) => x.dist - y.dist)
    portageCands.slice(0, MAX_PORTAGE).forEach((c) => polys.push({ id: `portage_trail_${c.index}`, path: c.rendered, width: 4, color: '#8d6e63', opacity: 0.92, zIndex: 35, dashed: { dash: 16, gap: 8 } }))

    const nearbyWater = waterCands.slice(0, Math.min(MAX_WATER, 120)).map((c) => entry!.waterLines[c.index])
    const nearbyPortage = portageCands.slice(0, Math.min(MAX_PORTAGE, 50)).map((c) => entry!.portageLines[c.index])

    const campRows = entry.campsites.map((camp) => {
      const point = { lat: Number(camp.lat), lng: Number(camp.lon) }
      const distanceToKnownRoute = distanceMetersToPath(point, distancePath)
      const networkMeters = Math.min(nearestToLines(point, nearbyWater), nearestToLines(point, nearbyPortage))
      return { camp, point, networkMeters, effectiveMeters: Math.min(networkMeters, distanceToKnownRoute), distanceToKnownRoute }
    })
    const maxCrowFly = exp === 'intermediate' ? 14000 : exp === 'advanced' ? 20000 : 10000
    const selectCamps = (maxEffective: number, maxRoute: number, crowMul = 1) =>
      campRows
        .filter((r) => r.effectiveMeters <= maxEffective && r.distanceToKnownRoute <= maxRoute && haversineMeters(r.point, focus) <= maxCrowFly * crowMul)
        .sort((x, y) => x.effectiveMeters - y.effectiveMeters)
    const hasRouted = routePath.length > 0
    let sorted = selectCamps(hasRouted ? 45000 : 70000, hasRouted ? 14000 : 38000)
    if (sorted.length < 12) sorted = selectCamps(hasRouted ? 60000 : 85000, hasRouted ? 24000 : 52000, 1.4)
    if (sorted.length < 8) sorted = selectCamps(hasRouted ? 75000 : 100000, hasRouted ? 36000 : 65000, 2.0)
    if (!sorted.length && campRows.length) sorted = [...campRows].sort((x, y) => x.effectiveMeters - y.effectiveMeters)

    const markers: MarkerDef[] = []
    let campCount = 0
    sorted.forEach((row, i) => {
      if (campCount >= 120) return
      if (campCount >= 60 && row.effectiveMeters > 28000) return
      campCount++
      const km = row.effectiveMeters / 1000
      markers.push({
        id: `p_camp_${i}`, position: row.point, icon: campsiteTriangleIcon(), infoHtml: infoHtml(String(row.camp.name ?? 'Campsite'), `${km.toFixed(1)} km from route`),
        onClick: () => {
          focusOn(row.point)
          propsRef.current.onHikingCampsiteTap?.({ ...row.camp, name: String(row.camp.name ?? 'Campsite'), lat: row.point.lat, lon: row.point.lng, distanceKmFromRoute: km, mode: 'portaging' })
        },
      })
    })

    const accessRows = entry.accessPoints
      .map((head) => {
        const point = { lat: Number(head.lat), lng: Number(head.lon) }
        return { head, point, km: distanceMetersToPath(point, distancePath) / 1000 }
      })
      .sort((x, y) => x.km - y.km)
    const accessCap = hasRouted ? 40 : 80
    const cutoffKm = hasRouted ? 25 : 80
    const softCap = hasRouted ? 20 : 40
    let accessCount = 0
    accessRows.forEach((row, i) => {
      if (accessCount >= accessCap) return
      if (accessCount >= softCap && row.km > cutoffKm) return
      accessCount++
      const title = String(row.head.name ?? 'Portage access')
      markers.push({
        id: `p_access_${i}`, position: row.point, icon: portageAccessIcon(), infoHtml: infoHtml(title, `Put-in / take-out candidate · ${row.km.toFixed(1)} km`),
        onClick: () => {
          focusOn(row.point)
          propsRef.current.onPortageAccessTap?.({ ...row.head, name: title, lat: row.point.lat, lon: row.point.lng, distanceKmFromRoute: row.km, mode: 'portaging' })
        },
      })
    })
    return { polys, markers }
  }, [anchorPathForMode, flattenRouteForMode, points, focusOn, propsRef])

  function primePortageCaches(entry: PortagingOverlayEntry, preferFocusOnly: boolean) {
    portageState.lastVisible = entry
    if (preferFocusOnly) return
    const primed = new Set<string>()
    const prime = (key: string) => {
      const t = key.trim()
      if (!t || primed.has(t)) return
      primed.add(t)
      portagingCacheRef.set(t, entry)
    }
    const routeAnchors = anchorPathForMode('portaging')
    if (routeAnchors.length >= 2) {
      const base = portagingRouteCacheKey(routeAnchors)
      prime(base); prime(`${base}:route-lite`)
    }
    for (let seg = 0; seg + 1 < points.length; seg++) {
      if (segmentMode(seg) !== 'portaging') continue
      const anchors = segmentPoints(seg).map(toLL)
      if (anchors.length < 2) continue
      const base = portagingRouteCacheKey(anchors)
      prime(base); prime(`${base}:route-lite`)
    }
  }

  // ---- gas stops ----
  const ensurePlaces = useCallback(async () => {
    if (placesService.current) return placesService.current
    await ensureGoogleMapsLoaded()
    try { await (google.maps as any).importLibrary?.('places') } catch { /* ignore */ }
    let host = document.getElementById('trypr-map-places-host')
    if (!host) {
      host = document.createElement('div')
      host.id = 'trypr-map-places-host'
      host.style.display = 'none'
      document.body.appendChild(host)
    }
    try {
      placesService.current = new google.maps.places.PlacesService(host as HTMLDivElement)
    } catch {
      placesService.current = null
    }
    return placesService.current
  }, [])

  const nearbyGas = (svc: google.maps.places.PlacesService, center: LL) =>
    new Promise<any[]>((resolve) => {
      const timer = setTimeout(() => resolve([]), 6000)
      svc.nearbySearch({ location: center, radius: 3200, type: 'gas_station' }, (results, status) => {
        clearTimeout(timer)
        if (status !== 'OK' || !results) return resolve([])
        const out: any[] = []
        for (const r of results) {
          const loc = r.geometry?.location
          if (!loc) continue
          out.push({ name: (r.name ?? '').trim() || 'Gas Station', place_id: r.place_id ?? '', vicinity: (r.vicinity ?? '').trim(), lat: loc.lat(), lon: loc.lng() })
        }
        resolve(out)
      })
    })

  const buildGasStops = useCallback(async (geo: Map<number, LL[]>): Promise<GasResult> => {
    const routePath = flattenRouteForMode(geo, 'gas_stops')
    if (routePath.length < 2) return { markers: [] }
    const cacheKey = pathSignature(routePath)
    let gas = gasCache.current.get(cacheKey)
    if (!gas) {
      const svc = await ensurePlaces()
      if (!svc) return { markers: [] }
      const byPlace = new Map<string, any>()
      for (const s of samplePath(routePath, 8)) {
        for (const item of await nearbyGas(svc, s)) {
          byPlace.set(item.place_id ? `place:${item.place_id}` : `${item.lat},${item.lon}`, item)
        }
      }
      gas = [...byPlace.values()]
      for (const item of gas) item.distanceMeters = distanceMetersToPath({ lat: item.lat, lng: item.lon }, routePath)
      gas.sort((x, y) => (x.distanceMeters ?? Infinity) - (y.distanceMeters ?? Infinity))
      if (gas.length > 20) gas = gas.slice(0, 20)
      gasCache.current.set(cacheKey, gas)
    }
    const hue = `data:image/svg+xml;charset=UTF-8,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="26" height="26"><circle cx="13" cy="13" r="11" fill="#ef6c00" stroke="#fff" stroke-width="2"/><text x="13" y="17" text-anchor="middle" font-size="12" fill="#fff" font-family="Arial" font-weight="700">⛽</text></svg>')}`
    return {
      markers: gas.map((s, i) => {
        const km = (s.distanceMeters ?? 0) / 1000
        return {
          id: `gas_${i}`, position: { lat: s.lat, lng: s.lon },
          icon: { url: hue, scaledSize: new google.maps.Size(26, 26), anchor: new google.maps.Point(13, 13) },
          infoHtml: infoHtml(String(s.name ?? 'Gas Station'), s.vicinity ? `${s.vicinity} · ${km.toFixed(1)} km from route` : `${km.toFixed(1)} km from route`),
        } as MarkerDef
      }),
    }
  }, [flattenRouteForMode, ensurePlaces])

  const setGasLayer = useCallback((gas: GasResult) => overlays.current?.syncMarkers('gas', gas.markers), [overlays])

  // ---- viewport + load flow ----
  const currentViewport = useCallback((): Viewport | null => {
    const map = mapRef.current
    const bounds = map?.getBounds()
    const fallback = overlays.current?.markerPositions(['main'])[0] ?? null
    const fb = (f: LL): Viewport => ({
      center: f, hikingAnchors: [f], portagingPadDegrees: 0.12,
      signature: `${hikingCacheKey([f])}|${portagingFocusCacheKey(f, 0.12)}`,
    })
    if (!bounds) return fallback ? fb(fallback) : null
    const sw = bounds.getSouthWest(), ne = bounds.getNorthEast()
    const center = { lat: (sw.lat() + ne.lat()) / 2, lng: (sw.lng() + ne.lng()) / 2 }
    const latSpan = Math.abs(ne.lat() - sw.lat())
    let lonSpan = Math.abs(ne.lng() - sw.lng())
    if (lonSpan > 180) lonSpan = 360 - lonSpan
    const pad = quantizedOverlayPadDegrees(Math.min(0.18, Math.max(0.08, Math.max(latSpan, lonSpan) * 0.75)))
    const hikingAnchors = [{ lat: sw.lat(), lng: sw.lng() }, center, { lat: ne.lat(), lng: ne.lng() }]
    return { center, hikingAnchors, portagingPadDegrees: pad, signature: `${hikingCacheKey(hikingAnchors)}|${portagingFocusCacheKey(center, pad)}` }
  }, [mapRef, overlays])

  const existingNonAdventure = () => undefined

  const clearAdventureLayers = useCallback((resetSig = false) => {
    overlays.current?.clearLayer('trail')
    overlays.current?.clearLayer('portage')
    const r = refs.current
    if (resetSig) { r.lastSig = ''; r.autoLoadSig = '' }
    r.pendingSig = ''
    r.inFlight = false
    setShowLoadButton(false)
    setLoading(false)
  }, [overlays])

  const refreshAdventureOverlays = useCallback(async (force = false) => {
    const showHiking = showNearbyContextOverlays && shouldRenderMode('hiking')
    const showPortaging = showNearbyContextOverlays && shouldRenderMode('portaging')
    const viewport = showHiking || showPortaging ? currentViewport() : null
    const nextSig = `${showHiking ? 1 : 0}|${showPortaging ? 1 : 0}|${viewport?.signature ?? 'none'}`
    if (!force && refs.current.lastSig === nextSig) return
    const seq = a.seqRef.current
    const ov = overlays.current
    if (!ov) return

    if (showHiking && viewport) {
      try {
        const h = await buildHiking(segGeometry.current, viewport.hikingAnchors)
        if (seq !== a.seqRef.current) return
        if (h.polys.length || h.markers.length) {
          ov.syncPolylines('trail', h.polys)
          ov.syncMarkers('trail', h.markers)
        } else console.debug('hikingOverlays reused_previous_layers')
      } catch (e) { console.debug('hikingOverlays camera_refresh_failed', e) }
    } else ov.clearLayer('trail')

    if (showPortaging && viewport) {
      try {
        const pr = await buildPortaging(segGeometry.current, { focusPointOverride: viewport.center, focusPadDegreesOverride: viewport.portagingPadDegrees, preferFocusOnly: true })
        if (seq !== a.seqRef.current) return
        if (pr.polys.length || pr.markers.length) {
          ov.syncPolylines('portage', pr.polys)
          ov.syncMarkers('portage', pr.markers)
        } else console.debug('portagingOverlays reused_previous_layers')
      } catch (e) { console.debug('portagingOverlays camera_refresh_failed', e) }
    } else ov.clearLayer('portage')

    refs.current.pendingSig = nextSig
    refs.current.lastSig = nextSig
    setShowLoadButton(false)
    // Optionally open an info window for a specific campsite marker (debug aid).
    const wanted = (import.meta.env.VITE_CAMPSITE_INFO_MARKER_ID ?? '').trim()
    if (wanted && !refs.current.campOpened) {
      refs.current.campOpened = true
      setTimeout(() => { ov.openInfoFor('trail', wanted); ov.openInfoFor('portage', wanted) }, 200)
    }
  }, [showNearbyContextOverlays, shouldRenderMode, currentViewport, a.seqRef, overlays, buildHiking, buildPortaging, segGeometry])

  const loadForViewport = useCallback(async (showIndicator = true) => {
    const r = refs.current
    if (r.inFlight || !canOffer()) return
    r.inFlight = true
    if (showIndicator) setLoading(true)
    try {
      await refreshAdventureOverlays(true)
      if (a.lastBlockingGaps.current && points.length > 1 && (modeMatchesAnySegment('hiking') || modeMatchesAnySegment('portaging'))) a.rerouteGaps()
    } finally {
      r.inFlight = false
      if (showIndicator) setLoading(false)
      void updateLoadPrompt(true)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [canOffer, refreshAdventureOverlays, points.length, modeMatchesAnySegment])

  const updateLoadPrompt = useCallback(async (force = false) => {
    const hasAdventure = modeMatchesAnySegment('hiking') || modeMatchesAnySegment('portaging')
    const r = refs.current
    if (!showNearbyContextOverlays || !hasAdventure) {
      if (r.pendingSig) clearAdventureLayers(true)
      else if (r.lastSig) { r.lastSig = ''; r.autoLoadSig = '' }
      return
    }
    if (!canOffer()) {
      r.pendingSig = ''
      r.autoLoadSig = ''
      setShowLoadButton(false)
      return
    }
    const viewport = currentViewport()
    const nextSig = `${shouldRenderMode('hiking') ? 1 : 0}|${shouldRenderMode('portaging') ? 1 : 0}|${viewport?.signature ?? 'none'}`
    const shouldOffer = !!viewport && nextSig !== r.lastSig
    const shouldAuto = shouldOffer && !r.inFlight && nextSig !== r.autoLoadSig
    if (!force && nextSig === r.pendingSig && showLoadButton === (shouldOffer && !shouldAuto)) return
    r.pendingSig = nextSig
    setShowLoadButton(shouldOffer && !shouldAuto)
    if (shouldAuto) {
      r.autoLoadSig = nextSig
      void loadForViewport(false)
    }
  }, [modeMatchesAnySegment, showNearbyContextOverlays, canOffer, currentViewport, shouldRenderMode, showLoadButton, clearAdventureLayers, loadForViewport])

  const scheduleRefresh = useCallback((force = false) => {
    clearTimeout(refs.current.timer)
    refs.current.timer = setTimeout(() => void updateLoadPrompt(force), 120)
  }, [updateLoadPrompt])

  const resetSignatures = useCallback(() => {
    refs.current.lastSig = ''
    refs.current.autoLoadSig = ''
    refs.current.pendingSig = ''
    refs.current.inFlight = false
    setShowLoadButton(false)
    setLoading(false)
  }, [])

  return {
    canRenderPortage: shouldRenderMode('portaging'),
    canRenderHiking: shouldRenderMode('hiking'),
    showLoadButton,
    loading,
    loadForViewport: () => loadForViewport(true),
    clearAll: () => { clearAdventureLayers(true); overlays.current?.clearLayer('gas') },
    onCameraIdle: () => scheduleRefresh(false),
    scheduleRefresh,
    resetSignatures,
    buildGasStops,
    setGasLayer,
    async prewarmPortage() {
      const anchors = anchorPathForMode('portaging')
      if (anchors.length < 2) return
      try {
        const key = `${portagingRouteCacheKey(anchors)}:prewarm`
        const entry = await Promise.race([
          getPortagingOverlayEntry({ cacheKey: key, anchors, padDegrees: quantizedOverlayPadDegrees(0.22), includeCampsites: false }),
          new Promise<null>((r) => setTimeout(() => r(null), 8000)),
        ])
        if (entry) primePortageCaches(entry, false)
      } catch (e) { console.debug('portagePrewarm failed', e) }
    },
    async refreshAfterRoute(geo: Map<number, LL[]>) {
      const ov = overlays.current
      if (!ov) return
      if (modeMatchesAnySegment('hiking')) {
        try {
          const h = await buildHiking(geo)
          if (h.polys.length || h.markers.length) { ov.syncPolylines('trail', h.polys); ov.syncMarkers('trail', h.markers) }
        } catch (e) { console.debug('hikingOverlays route_refresh_failed', e) }
      } else ov.clearLayer('trail')
      if (modeMatchesAnySegment('portaging')) {
        try {
          const pr = await buildPortaging(geo)
          if (pr.polys.length || pr.markers.length) { ov.syncPolylines('portage', pr.polys); ov.syncMarkers('portage', pr.markers) }
        } catch (e) { console.debug('portagingOverlays route_refresh_failed', e) }
      } else ov.clearLayer('portage')
      if (!modeMatchesAnySegment('gas_stops')) ov.clearLayer('gas')
    },
    retryRoute(segPoints: PointMap[], mode: string, segType: string): Promise<RouteComputation | null> {
      if (segType === 'direct') return Promise.resolve(null)
      const m = normalizeMapMode(mode)
      if (m === 'hiking') return routeViaTrailGraph(segPoints, m)
      if (m === 'portaging') return routeViaPortageGraph(segPoints)
      return Promise.resolve(null)
    },
    existingNonAdventure,
    boundsOf,
    isFresh,
    OVERLAY_CACHE_TTL_MS,
  }
}
