import { ensureGoogleMapsLoaded, mapsReady } from './googleMapsLoader'

export interface TravelRouteOption {
  mode: string
  summary: string
  distanceMeters: number
  durationSeconds: number
  transferCount: number
  layoverCount: number
  layoverMinutes: number
  departureTimeText: string
  arrivalTimeText: string
  instructions: string[]
  transitLineColor?: string | null
  transitArrivalStop?: { name?: string; lat?: number; lon?: number } | null
}

let svc: google.maps.DirectionsService | null = null

async function ensureService() {
  await Promise.race([ensureGoogleMapsLoaded(), new Promise((r) => setTimeout(r, 8000))])
  if (!mapsReady() || svc) return
  try {
    await Promise.race([(google.maps as any).importLibrary?.('routes'), new Promise((r) => setTimeout(r, 4000))])
  } catch {
    /* ignore */
  }
  if (google.maps.DirectionsService) svc = new google.maps.DirectionsService()
}

function normalizeMode(raw: string): string {
  switch (raw.trim().toLowerCase()) {
    case 'train':
    case 'rail':
    case 'public_transit':
    case 'public transit':
    case 'transit':
      return 'transit'
    case 'driving':
    case 'walking':
    case 'hiking':
    case 'portaging':
    case 'backpacking':
    case 'biking':
    case 'bikepacking':
      return raw.trim().toLowerCase()
    default:
      return 'driving'
  }
}

function googleModeFor(mode: string): string {
  switch (mode) {
    case 'transit':
      return 'TRANSIT'
    case 'walking':
    case 'hiking':
    case 'portaging':
    case 'backpacking':
      return 'WALKING'
    case 'biking':
    case 'bikepacking':
      return 'BICYCLING'
    default:
      return 'DRIVING'
  }
}

const stripHtml = (v: string) => v.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim()

function stopToMap(stop?: google.maps.TransitStop | null) {
  if (!stop) return null
  const name = (stop.name ?? '').trim()
  const loc = stop.location
  if (!loc) return name ? { name } : null
  return { ...(name ? { name } : {}), lat: loc.lat(), lon: loc.lng() }
}

function routeSummary(route: google.maps.DirectionsRoute, mode: string, instructions: string[], n: number): string {
  const summary = (route.summary ?? '').trim()
  if (summary) return summary
  if (instructions.length) return instructions[0]
  switch (mode) {
    case 'transit':
      return `Transit option ${n}`
    case 'biking':
    case 'bikepacking':
      return `Bike route ${n}`
    case 'walking':
    case 'hiking':
    case 'backpacking':
      return `Walking route ${n}`
    case 'portaging':
      return `Portage route ${n}`
    default:
      return `Driving route ${n}`
  }
}

export interface RouteOptionsArgs {
  originLat: number
  originLng: number
  destLat: number
  destLng: number
  mode: string
  departureTime?: Date
  avoidHighways?: boolean
  avoidTolls?: boolean
  maxOptions?: number
}

export async function getRouteOptions(a: RouteOptionsArgs): Promise<TravelRouteOption[]> {
  try {
    const mode = normalizeMode(a.mode)
    await ensureService()
    if (!svc) return []

    const request: google.maps.DirectionsRequest = {
      origin: { lat: a.originLat, lng: a.originLng },
      destination: { lat: a.destLat, lng: a.destLng },
      travelMode: (google.maps.TravelMode as any)[googleModeFor(mode)],
      provideRouteAlternatives: true,
      avoidHighways: !!a.avoidHighways || mode === 'biking',
      avoidTolls: !!a.avoidTolls,
    }
    if (mode === 'transit') {
      const transitOptions: google.maps.TransitOptions = {
        routingPreference: 'FEWER_TRANSFERS' as google.maps.TransitRoutePreference,
        departureTime: a.departureTime ?? new Date(Date.now() + 5 * 60 * 1000),
      }
      if ((google.maps.TransitMode as any)?.TRAIN) transitOptions.modes = [google.maps.TransitMode.TRAIN]
      request.transitOptions = transitOptions
    }

    const result = await Promise.race([
      new Promise<google.maps.DirectionsResult | null>((resolve) =>
        svc!.route(request, (res, status) => resolve(status === 'OK' && res ? res : null)),
      ),
      new Promise<null>((r) => setTimeout(() => r(null), 16000)),
    ])
    if (!result?.routes?.length) return []

    const options: TravelRouteOption[] = []
    const routes = result.routes.slice(0, a.maxOptions ?? 4)

    routes.forEach((route, idx) => {
      let totalDistance = 0
      let totalDuration = 0
      const instructions: string[] = []
      let departureText = ''
      let arrivalText = ''
      let transitLineColor: string | null = null
      let transitArrivalStop: TravelRouteOption['transitArrivalStop'] = null
      const windows: { dep: number; arr: number }[] = []
      let transitLegCount = 0

      for (const leg of route.legs ?? []) {
        totalDistance += leg.distance?.value ?? 0
        totalDuration += leg.duration?.value ?? 0
        if (!departureText) departureText = leg.departure_time?.text?.trim() ?? ''
        const legArr = leg.arrival_time?.text?.trim() ?? ''
        if (legArr) arrivalText = legArr

        for (const step of leg.steps ?? []) {
          const stepMode = String(step.travel_mode ?? '').toUpperCase()
          if (mode === 'transit' && stepMode === 'TRANSIT') {
            const transit = step.transit
            if (!transit) continue
            transitLegCount++
            const line = transit.line
            const shortName = (line?.short_name ?? '').trim()
            const lineName = (line?.name ?? '').trim()
            const lineColor = (line?.color ?? '').trim()
            if (lineColor && !transitLineColor) transitLineColor = lineColor
            const vehicleName = (line?.vehicle?.name ?? '').trim()
            const headsign = (transit.headsign ?? '').trim()
            const depName = (transit.departure_stop?.name ?? '').trim()
            const arrName = (transit.arrival_stop?.name ?? '').trim()

            if (!departureText) departureText = transit.departure_time?.text?.trim() ?? ''
            const arrText = transit.arrival_time?.text?.trim() ?? ''
            if (arrText) arrivalText = arrText

            const depMs = transit.departure_time?.value?.getTime()
            const arrMs = transit.arrival_time?.value?.getTime()
            if (depMs != null && arrMs != null && arrMs >= depMs) windows.push({ dep: depMs, arr: arrMs })

            const arrivalStop = stopToMap(transit.arrival_stop)
            if (arrivalStop) transitArrivalStop = arrivalStop

            const label = [vehicleName, shortName || lineName].filter(Boolean).join(' ')
            const stopPart = depName && arrName ? `${depName} -> ${arrName}` : ''
            const headPart = headsign ? `-> ${headsign}` : ''
            const full = [label, stopPart, headPart].filter((s) => s.trim()).join(' - ')
            if (full) instructions.push(full)
          } else {
            const clean = stripHtml(step.instructions ?? '')
            if (!clean) continue
            const distText = (step.distance?.text ?? '').trim()
            instructions.push(distText ? `${clean} (${distText})` : clean)
          }
        }
      }

      let layoverCount = 0
      let layoverMinutes = 0
      for (let i = 1; i < windows.length; i++) {
        const gapMs = windows[i].dep - windows[i - 1].arr
        if (gapMs <= 0) continue
        const gapMin = gapMs / 60000
        if (gapMin < 3) continue
        layoverCount++
        layoverMinutes += gapMin
      }

      options.push({
        mode,
        summary: routeSummary(route, mode, instructions, idx + 1),
        distanceMeters: totalDistance,
        durationSeconds: totalDuration,
        transferCount: transitLegCount > 0 ? transitLegCount - 1 : 0,
        layoverCount,
        layoverMinutes,
        departureTimeText: departureText,
        arrivalTimeText: arrivalText,
        instructions: instructions.slice(0, 8),
        transitLineColor,
        transitArrivalStop,
      })
    })
    return options
  } catch {
    return []
  }
}
