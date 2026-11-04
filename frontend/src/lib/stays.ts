import { formatLocationDisplay } from './locationDisplay'

/** One place to look for a hotel: where, and for which nights. */
export interface StayStop {
  name: string
  lat: number
  lon: number
  checkIn: string // YYYY-MM-DD
  checkOut: string // YYYY-MM-DD
}

const DAY_MS = 86_400_000
const parse = (iso: string) => new Date(`${iso}T12:00:00`) // noon: immune to DST shifts
export const isoDay = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
export const addIsoDays = (iso: string, n: number) => {
  const d = parse(iso)
  d.setDate(d.getDate() + n)
  return isoDay(d)
}
export const isoNightsBetween = (a: string, b: string) => Math.round((parse(b).getTime() - parse(a).getTime()) / DAY_MS)
const validIso = (s: unknown): s is string => typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s) && !Number.isNaN(parse(s).getTime())

export const stayPlaceName = (raw: unknown): string => formatLocationDisplay({ raw: String(raw ?? '') }).title || String(raw ?? '').trim()

export interface TripStayChoices {
  stops: StayStop[]
  /** For each entry in `stops`, the index of the waypoint it came from. */
  waypointIndexes: number[]
}

/**
 * Stay searches for a saved trip. A stop counts when it has nights; its dates come from the stored
 * startDate/checkoutDate, or, for older trips without them, from the trip start plus the nights before it.
 * A trip with dates but no stay stops still gets one search, at its final destination.
 */
export function stayChoicesForTrip(waypoints: Record<string, any>[], tripStart: unknown, tripEnd: unknown): TripStayChoices {
  const stops: StayStop[] = []
  const waypointIndexes: number[] = []
  const hasCoords = (w: Record<string, any>) => Number.isFinite(Number(w.lat)) && Number.isFinite(Number(w.lon ?? w.lng))
  const nightsOf = (w: Record<string, any>) => {
    const n = typeof w.nights === 'number' ? Math.trunc(w.nights) : parseInt(String(w.nights ?? ''), 10)
    return Number.isFinite(n) ? n : 0
  }

  let elapsed = 0
  waypoints.forEach((w, i) => {
    const nights = nightsOf(w)
    const counts = (typeof w.isStop === 'boolean' ? w.isStop : nights > 0) && nights > 0
    if (counts && hasCoords(w)) {
      const checkIn = validIso(w.startDate) ? w.startDate : validIso(tripStart) ? addIsoDays(tripStart, elapsed) : ''
      const checkOut = validIso(w.checkoutDate) && checkIn && w.checkoutDate > checkIn ? w.checkoutDate : checkIn ? addIsoDays(checkIn, nights) : ''
      if (checkIn && checkOut) {
        stops.push({ name: stayPlaceName(w.name), lat: Number(w.lat), lon: Number(w.lon ?? w.lng), checkIn, checkOut })
        waypointIndexes.push(i)
      }
    }
    if (counts) elapsed += nights
  })

  if (!stops.length && waypoints.length && validIso(tripStart)) {
    const last = waypoints[waypoints.length - 1]
    if (hasCoords(last)) {
      const out = validIso(tripEnd) && isoNightsBetween(tripStart, tripEnd) >= 1 ? tripEnd : addIsoDays(tripStart, 1)
      stops.push({ name: stayPlaceName(last.name), lat: Number(last.lat), lon: Number(last.lon ?? last.lng), checkIn: tripStart, checkOut: out })
      waypointIndexes.push(waypoints.length - 1)
    }
  }
  return { stops, waypointIndexes }
}
