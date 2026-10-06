// Google Directions via the Maps JavaScript API (avoids CORS issues with REST).
import { ensureGoogleMapsLoaded, mapsReady } from './googleMapsLoader'

export interface PathPoint {
  lat: number
  lon: number
  lng: number
}

export interface StepDetail {
  mode: string
  tabLabel: string
  headline: string
  detail?: string
  caption?: string
  lineColor?: string
  focusLat?: number
  focusLon?: number
  focusZoom?: number
  path?: PathPoint[]
}

export interface DirectionsResult {
  polylinePoints: [number, number][] // [lat, lng]
  distanceMeters: number
  durationSeconds: number
  instructions: string[]
  stepDetails: StepDetail[]
  transitArrivalStop?: { name: string; lat: number; lon: number } | null
  transitLineColor?: string | null
}

let directionsService: google.maps.DirectionsService | null = null

async function ensureDirectionsService(): Promise<void> {
  await Promise.race([ensureGoogleMapsLoaded(), new Promise((r) => setTimeout(r, 8000))])
  if (!mapsReady()) return
  if (directionsService) return
  try {
    await Promise.race([(google.maps as any).importLibrary?.('routes'), new Promise((r) => setTimeout(r, 4000))])
  } catch {
    /* ignore */
  }
  if (google.maps.DirectionsService) directionsService = new google.maps.DirectionsService()
}

function tabLabelForStep(travelMode: string, shortName = '', vehicleName = ''): string {
  switch (travelMode.trim().toUpperCase()) {
    case 'WALKING':
      return 'Walk'
    case 'BICYCLING':
      return 'Bike'
    case 'TRANSIT':
      if (shortName) return `Train ${shortName}`
      if (vehicleName) return vehicleName
      return 'Transit'
    default:
      return 'Step'
  }
}

function stepDetail(s: StepDetail): StepDetail {
  const out: StepDetail = {
    mode: s.mode.trim().toLowerCase(),
    tabLabel: s.tabLabel.trim(),
    headline: s.headline.trim(),
  }
  if (s.detail?.trim()) out.detail = s.detail.trim()
  if (s.caption?.trim()) out.caption = s.caption.trim()
  if (s.lineColor?.trim()) out.lineColor = s.lineColor.trim()
  if (s.focusLat != null && s.focusLon != null) {
    out.focusLat = s.focusLat
    out.focusLon = s.focusLon
  }
  if (s.focusZoom != null && Number.isFinite(s.focusZoom)) out.focusZoom = s.focusZoom
  if (s.path?.length) out.path = s.path
  return out
}

function pointFromLocation(loc?: google.maps.LatLng | null): PathPoint | null {
  if (!loc) return null
  const lat = loc.lat()
  const lon = loc.lng()
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null
  return { lat, lon, lng: lon }
}

function appendDistinct(out: PathPoint[], p: PathPoint | null) {
  if (!p) return
  const last = out[out.length - 1]
  if (last && Math.abs(last.lat - p.lat) < 1e-7 && Math.abs(last.lon - p.lon) < 1e-7) return
  out.push(p)
}

function pathFromStep(step: google.maps.DirectionsStep, start: PathPoint | null, end: PathPoint | null): PathPoint[] {
  const out: PathPoint[] = []
  appendDistinct(out, start)
  for (const pt of step.path ?? []) appendDistinct(out, pointFromLocation(pt))
  appendDistinct(out, end)
  return out
}

const focusPoint = (path: PathPoint[]): PathPoint | null =>
  path.length === 0 ? null : path.length === 1 ? path[0] : path[Math.floor(path.length / 2)]

function focusZoomForMode(mode: string): number {
  switch (mode.trim().toUpperCase()) {
    case 'WALKING':
      return 15.4
    case 'BICYCLING':
      return 14.8
    case 'TRANSIT':
      return 13.6
    default:
      return 14.0
  }
}

const stripHtml = (html: string) => html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim()

export interface DirectionsArgs {
  originLat: number
  originLng: number
  destLat: number
  destLng: number
  /** 'driving' | 'walking' | 'bicycling' | 'transit' */
  mode: string
  waypoints?: [number, number][]
  originQuery?: string
  destQuery?: string
  waypointQueries?: string[]
  avoidHighways?: boolean
  avoidTolls?: boolean
  includeTransitTrainMode?: boolean
}

/** Decode a Google encoded polyline. */
export function decodePolyline(encoded: string): [number, number][] {
  const points: [number, number][] = []
  let index = 0
  let lat = 0
  let lng = 0
  while (index < encoded.length) {
    let result = 0
    let shift = 0
    let b: number
    do {
      b = encoded.charCodeAt(index++) - 63
      result |= (b & 0x1f) << shift
      shift += 5
    } while (b >= 0x20)
    lat += result & 1 ? ~(result >> 1) : result >> 1

    result = 0
    shift = 0
    do {
      b = encoded.charCodeAt(index++) - 63
      result |= (b & 0x1f) << shift
      shift += 5
    } while (b >= 0x20)
    lng += result & 1 ? ~(result >> 1) : result >> 1

    points.push([lat / 1e5, lng / 1e5])
  }
  return points
}

export async function getDirections(a: DirectionsArgs): Promise<DirectionsResult | null> {
  try {
    await ensureDirectionsService()
    const svc = directionsService
    if (!svc) return null

    const originQ = a.originQuery?.trim() ?? ''
    const destQ = a.destQuery?.trim() ?? ''
    const wpQueries = (a.waypointQueries ?? []).map((q) => q.trim())
    const mode = a.mode.toLowerCase()

    const waypoints: google.maps.DirectionsWaypoint[] = []
    ;(a.waypoints ?? []).forEach((wp, i) => {
      if (wp.length < 2) return
      const q = wpQueries[i] ?? ''
      waypoints.push({ location: q || { lat: wp[0], lng: wp[1] }, stopover: true })
    })

    const request: google.maps.DirectionsRequest = {
      origin: originQ || { lat: a.originLat, lng: a.originLng },
      destination: destQ || { lat: a.destLat, lng: a.destLng },
      travelMode: (google.maps.TravelMode as any)[a.mode.toUpperCase()],
      // Bicycling already prefers quiet roads; avoidHighways reinforces it.
      avoidHighways: !!a.avoidHighways || mode === 'bicycling',
      avoidTolls: !!a.avoidTolls,
    }
    if (waypoints.length) request.waypoints = waypoints

    if (mode === 'transit') {
      const transitOptions: google.maps.TransitOptions = {
        routingPreference: 'FEWER_TRANSFERS' as google.maps.TransitRoutePreference,
        departureTime: new Date(Date.now() + 5 * 60 * 1000),
      }
      if (a.includeTransitTrainMode !== false && (google.maps.TransitMode as any)?.TRAIN) {
        transitOptions.modes = [google.maps.TransitMode.TRAIN]
      }
      request.transitOptions = transitOptions
    }

    const response = await Promise.race([
      new Promise<google.maps.DirectionsResult | null>((resolve) => {
        svc.route(request, (result, status) => {
          if (status !== 'OK' || !result) {
            console.debug(`googleDirections status=${status} mode=${a.mode}`)
            resolve(null)
            return
          }
          resolve(result)
        })
      }),
      new Promise<null>((r) => setTimeout(() => r(null), 15000)),
    ])
    if (!response) return null
    const route = response.routes?.[0]
    if (!route) return null

    const polyPoints: [number, number][] = []
    for (const pt of route.overview_path ?? []) polyPoints.push([pt.lat(), pt.lng()])
    if (!polyPoints.length && route.overview_polyline) {
      const encoded = typeof route.overview_polyline === 'string' ? route.overview_polyline : (route.overview_polyline as any).points
      if (encoded) polyPoints.push(...decodePolyline(String(encoded)))
    }

    let totalDist = 0
    let totalDur = 0
    const instructions: string[] = []
    const stepDetails: StepDetail[] = []
    let transitArrivalStop: DirectionsResult['transitArrivalStop'] = null
    let transitLineColor: string | null = null

    for (const leg of route.legs ?? []) {
      totalDist += leg.distance?.value ?? 0
      totalDur += leg.duration?.value ?? 0

      for (const step of leg.steps ?? []) {
        const travelMode = String((step as any).travel_mode ?? step.travel_mode ?? '')

        if (mode === 'transit' && travelMode === 'TRANSIT') {
          const transit = step.transit
          const line = transit?.line
          if (transit && line) {
            const shortName = line.short_name ?? ''
            const lineName = line.name ?? ''
            const color = line.color ?? null
            if (transitLineColor == null) transitLineColor = color
            const vehicleName = line.vehicle?.name ?? ''
            const headsign = transit.headsign ?? ''
            const dep = transit.departure_stop
            const arr = transit.arrival_stop
            const depName = dep?.name ?? ''
            const arrName = arr?.name ?? ''

            if (arr?.location) {
              transitArrivalStop = { name: arrName, lat: arr.location.lat(), lon: arr.location.lng() }
            }

            const stepStart = pointFromLocation(step.start_location) ?? pointFromLocation(dep?.location)
            const stepEnd = pointFromLocation(step.end_location) ?? pointFromLocation(arr?.location)
            const stepPath = pathFromStep(step, stepStart, stepEnd)
            const focus = focusPoint(stepPath) ?? stepStart ?? stepEnd

            const label = [vehicleName, shortName || lineName].filter(Boolean).join(' ')
            const stopPart = depName && arrName ? `${depName} → ${arrName}` : ''
            const headPart = headsign ? `→ ${headsign}` : ''
            const full = [label, stopPart, headPart].filter((s) => s.trim()).join(' — ')
            if (full) {
              instructions.push(full)
              stepDetails.push(
                stepDetail({
                  mode: 'transit',
                  tabLabel: tabLabelForStep(travelMode, shortName, vehicleName),
                  headline: full,
                  detail: stopPart,
                  caption: headsign,
                  lineColor: color ?? '',
                  focusLat: focus?.lat,
                  focusLon: focus?.lon,
                  focusZoom: focusZoomForMode(travelMode),
                  path: stepPath,
                }),
              )
            }
          }
        } else {
          const clean = stripHtml(step.instructions ?? '')
          if (clean) {
            const distText = step.distance?.text ?? ''
            const stepStart = pointFromLocation(step.start_location)
            const stepEnd = pointFromLocation(step.end_location)
            const stepPath = pathFromStep(step, stepStart, stepEnd)
            const focus = focusPoint(stepPath) ?? stepStart ?? stepEnd
            instructions.push(distText ? `${clean} (${distText})` : clean)
            if (mode === 'transit') {
              const tm = travelMode || 'WALKING'
              stepDetails.push(
                stepDetail({
                  mode: travelMode || 'walking',
                  tabLabel: tabLabelForStep(tm),
                  headline: clean,
                  detail: distText,
                  focusLat: focus?.lat,
                  focusLon: focus?.lon,
                  focusZoom: focusZoomForMode(tm),
                  path: stepPath,
                }),
              )
            }
          }
        }

        // If the overview path is unavailable, rebuild from step paths.
        if (!polyPoints.length) {
          for (const pt of step.path ?? []) {
            const last = polyPoints[polyPoints.length - 1]
            if (last && Math.abs(last[0] - pt.lat()) < 1e-7 && Math.abs(last[1] - pt.lng()) < 1e-7) continue
            polyPoints.push([pt.lat(), pt.lng()])
          }
        }
      }
    }

    return {
      polylinePoints: polyPoints,
      distanceMeters: totalDist,
      durationSeconds: totalDur,
      instructions: instructions.slice(0, 6),
      stepDetails: stepDetails.slice(0, 6),
      transitArrivalStop,
      transitLineColor,
    }
  } catch (e) {
    console.debug('googleDirections request_exception', e)
    return null
  }
}
