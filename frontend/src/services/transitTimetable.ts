// Real departure-time timetable for one transit leg: Google Directions for times, stops and lines,
// optionally enriched with platforms / realtime from config.transitPlatformProvider.
import { config } from '@/config'
import type { JourneyStep } from '@/lib/transitJourney'
import { ensureDirectionsService, focusPoint, focusZoomForMode, pathFromStep, pointFromLocation, requestDirections, stripHtml } from './directions'

export interface Timetable {
  steps: JourneyStep[]
  /** IANA zone of the departure station; every time shown is local to it. */
  timeZone: string
  departAt?: number
  arriveAt?: number
  platformSource?: { name: string; url: string }
}

export interface TimetableArgs {
  originLat: number
  originLng: number
  destLat: number
  destLng: number
  /** "YYYY-MM-DDTHH:mm", as the traveller reads it on the station clock. */
  wallTime: string
  /** Best guess at the station's zone (from an earlier lookup); corrected from Google's answer. */
  timeZone?: string
}

// ---- time zones --------------------------------------------------------------------------------

export const browserTimeZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'

function zoneOffsetMs(tz: string, at: number): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(new Date(at))
  const get = (t: string) => Number(parts.find((p) => p.type === t)?.value ?? 0)
  return Date.UTC(get('year'), get('month') - 1, get('day'), get('hour'), get('minute'), get('second')) - Math.floor(at / 1000) * 1000
}

/** Epoch ms for a wall-clock time in `tz` (falls back to the browser zone if `tz` is unknown). */
export function wallTimeToEpoch(wall: string, tz: string): number {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(wall)
  if (!m) return NaN
  const naive = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5])
  try {
    const first = naive - zoneOffsetMs(tz, naive)
    return naive - zoneOffsetMs(tz, first) // second pass settles DST transitions
  } catch {
    return new Date(wall).getTime()
  }
}

/** "YYYY-MM-DDTHH:mm" in `tz` for an epoch ms. */
export function epochToWallTime(at: number, tz: string): string {
  try {
    const d = new Date(at + zoneOffsetMs(tz, at))
    return d.toISOString().slice(0, 16)
  } catch {
    const d = new Date(at - new Date(at).getTimezoneOffset() * 60000)
    return d.toISOString().slice(0, 16)
  }
}

// ---- Google ------------------------------------------------------------------------------------

function query(a: TimetableArgs, departAt: number) {
  const transitOptions: google.maps.TransitOptions = {
    departureTime: new Date(departAt),
    routingPreference: 'FEWER_TRANSFERS' as google.maps.TransitRoutePreference,
  }
  // Match the map's route, which is computed train-only (see getDirections).
  if ((google.maps.TransitMode as any)?.TRAIN) transitOptions.modes = [google.maps.TransitMode.TRAIN]
  return requestDirections({
    origin: { lat: a.originLat, lng: a.originLng },
    destination: { lat: a.destLat, lng: a.destLng },
    travelMode: google.maps.TravelMode.TRANSIT,
    transitOptions,
  })
}

const stopOf = (s?: google.maps.TransitStop | null) => {
  const p = pointFromLocation(s?.location)
  return { name: s?.name ?? '', ...(p ? { lat: p.lat, lon: p.lon } : {}) }
}

function mapFocus(step: google.maps.DirectionsStep, travelMode: string, headline: string, lineColor?: string) {
  const start = pointFromLocation(step.start_location)
  const end = pointFromLocation(step.end_location)
  const path = pathFromStep(step, start, end)
  const focus = focusPoint(path) ?? start ?? end
  return {
    mode: travelMode === 'TRANSIT' ? 'transit' : travelMode.toLowerCase(), tabLabel: headline, headline,
    focusLat: focus?.lat, focusLon: focus?.lon, focusZoom: focusZoomForMode(travelMode), path, ...(lineColor ? { lineColor } : {}),
  }
}

function journeyFromLeg(leg: google.maps.DirectionsLeg): JourneyStep[] {
  const out: JourneyStep[] = []
  // Walks carry no clock times; chain them off the previous step so the timeline stays continuous.
  let clock = leg.departure_time?.value?.getTime()
  for (const step of leg.steps ?? []) {
    const travelMode = String((step as any).travel_mode ?? step.travel_mode ?? '')
    const t = step.transit
    if (travelMode === 'TRANSIT' && t?.line) {
      const line = t.line.short_name || t.line.name || ''
      const departAt = t.departure_time?.value?.getTime()
      const arriveAt = t.arrival_time?.value?.getTime()
      out.push({
        kind: 'ride', title: line || t.line.vehicle?.name || 'Transit', line: line || undefined,
        vehicleType: t.line.vehicle?.type ? String(t.line.vehicle.type) : undefined, vehicleName: t.line.vehicle?.name,
        headsign: t.headsign || undefined, agency: t.line.agencies?.[0]?.name, lineColor: t.line.color || undefined,
        numStops: t.num_stops || undefined, from: stopOf(t.departure_stop), to: stopOf(t.arrival_stop),
        departAt, arriveAt, durationText: step.duration?.text,
        focus: mapFocus(step, 'TRANSIT', [t.line.vehicle?.name, line].filter(Boolean).join(' '), t.line.color),
      })
      clock = arriveAt ?? clock
    } else {
      const title = stripHtml(step.instructions ?? '') || 'Walk'
      const arriveAt = clock != null ? clock + (step.duration?.value ?? 0) * 1000 : undefined
      out.push({
        kind: travelMode === 'WALKING' || !travelMode ? 'walk' : 'other', title, departAt: clock, arriveAt,
        distanceText: step.distance?.text, durationText: step.duration?.text, focus: mapFocus(step, travelMode || 'WALKING', title),
      })
      clock = arriveAt
    }
  }
  return out
}

// ---- platforms: Transitous (dev only, see config.transitPlatformProvider) ----------------------

const compact = (v: string) => v.toLowerCase().replace(/[^a-z0-9]/g, '')
const metersBetween = (aLat: number, aLon: number, bLat: number, bLon: number) => {
  const r = Math.PI / 180
  const x = (bLon - aLon) * r * Math.cos(((aLat + bLat) / 2) * r)
  return Math.hypot(x, (bLat - aLat) * r) * 6371000
}

async function addTransitousPlatforms(steps: JourneyStep[]): Promise<boolean> {
  const rides = steps.filter((s) => s.kind === 'ride' && s.departAt != null && s.from?.lat != null && s.to?.lat != null)
  const found = await Promise.all(rides.map(async (r) => {
    try {
      const q = new URLSearchParams({
        fromPlace: `${r.from!.lat},${r.from!.lon}`, toPlace: `${r.to!.lat},${r.to!.lon}`,
        time: new Date(r.departAt! - 5 * 60000).toISOString(), numItineraries: '4',
      })
      const res = await fetch(`https://api.transitous.org/api/v1/plan?${q}`, { signal: AbortSignal.timeout(8000) })
      if (!res.ok) return false
      const data = await res.json()
      const legs: any[] = (data?.itineraries ?? []).flatMap((it: any) => it?.legs ?? []).filter((l: any) => l?.mode !== 'WALK')
      const want = compact(r.line ?? '')
      let best: any = null
      let bestScore = -Infinity
      for (const l of legs) {
        const sched = Date.parse(l.scheduledStartTime ?? l.startTime)
        const minutesOff = Math.abs(sched - r.departAt!) / 60000
        const near = metersBetween(r.from!.lat!, r.from!.lon!, Number(l.from?.lat), Number(l.from?.lon))
        // Same departure (±3 min, within a big station's footprint) is required; the line name breaks ties.
        if (!(minutesOff <= 3 && near <= 700)) continue
        const names = [l.displayName, l.routeShortName, l.tripShortName, `${l.routeShortName ?? ''}${l.tripShortName ?? ''}`].map((n) => compact(String(n ?? '')))
        const score = (want && names.includes(want) ? 10 : 0) - minutesOff - near / 500
        if (score > bestScore) { best = l; bestScore = score }
      }
      if (!best) return false
      const track = (v: unknown) => String(v ?? '').trim() || undefined
      r.from = { ...r.from!, platform: track(best.from?.track), plannedPlatform: track(best.from?.scheduledTrack) }
      r.to = { ...r.to!, platform: track(best.to?.track), plannedPlatform: track(best.to?.scheduledTrack) }
      const before = (best.intermediateStops ?? []).at(-1)?.name
      if (before) r.stopBefore = String(before)
      if (best.realTime) {
        const delay = Math.round((Date.parse(best.startTime) - Date.parse(best.scheduledStartTime)) / 60000)
        if (delay > 0) r.delayMin = delay
      }
      if (best.cancelled) r.cancelled = true
      return true
    } catch {
      return false
    }
  }))
  return found.some(Boolean)
}

// ---- entry point -------------------------------------------------------------------------------

/** Null when Maps is unavailable or no service runs then (e.g. the date is beyond published schedules). */
export async function fetchTransitTimetable(a: TimetableArgs): Promise<Timetable | null> {
  if (!(await ensureDirectionsService())) return null
  let tz = a.timeZone || browserTimeZone()
  let res = await query(a, wallTimeToEpoch(a.wallTime, tz))
  // The request time must be read on the station's clock; re-ask once Google tells us its zone.
  const legTz = res?.routes?.[0]?.legs?.[0]?.departure_time?.time_zone
  if (legTz && legTz !== tz) {
    const corrected = wallTimeToEpoch(a.wallTime, legTz)
    if (corrected !== wallTimeToEpoch(a.wallTime, tz)) res = (await query(a, corrected)) ?? res
    tz = legTz
  }
  const leg = res?.routes?.[0]?.legs?.[0]
  if (!leg) return null
  const steps = journeyFromLeg(leg)
  if (!steps.some((s) => s.kind === 'ride')) return null

  const out: Timetable = {
    steps, timeZone: tz,
    departAt: leg.departure_time?.value?.getTime() ?? steps[0]?.departAt,
    arriveAt: leg.arrival_time?.value?.getTime() ?? steps.at(-1)?.arriveAt,
  }
  if (config.transitPlatformProvider === 'transitous' && (await addTransitousPlatforms(steps))) {
    out.platformSource = { name: 'Transitous', url: 'https://transitous.org/sources/' }
  }
  return out
}
