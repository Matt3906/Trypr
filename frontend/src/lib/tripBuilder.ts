// Pure helpers for the trip builder (ported from trip_builder_screen.dart).
import { normalizeTripType } from '@/models/tripModel'

export interface Waypoint {
  name: string
  lat: number
  lon: number
  nights: number
  isStop: boolean
}

export interface TransportOption { mode: string; label: string; emoji: string }
export interface TripTypeOption { id: string; label: string; emoji: string; summary: string }
export interface ExperienceOption { id: string; label: string; summary: string }

export const BUILDER_TRANSPORT_OPTIONS: TransportOption[] = [
  { mode: 'car', label: 'Road', emoji: '🚗' },
  { mode: 'plane', label: 'Flight', emoji: '✈️' },
  { mode: 'train', label: 'Rail', emoji: '🚆' },
  { mode: 'walk', label: 'Walk', emoji: '🚶' },
  { mode: 'bike', label: 'Bike', emoji: '🚲' },
  { mode: 'portaging', label: 'Paddle / Portage', emoji: '🛶' },
  { mode: 'hiking', label: 'Hiking', emoji: '🥾' },
  { mode: 'gas_stops', label: 'Road Stops', emoji: '⛽' },
]

export const TRIP_TYPE_OPTIONS: TripTypeOption[] = [
  { id: 'road', label: 'Road Trip', emoji: '🚗', summary: 'Drive between towns, parks, hotels, and regular stops.' },
  { id: 'portage', label: 'Portage / Canoe', emoji: '🏕️', summary: 'Start at an access point, then plan campsites along water and portage routes.' },
  { id: 'hiking', label: 'Hiking / Backpacking', emoji: '🥾', summary: 'Build a trail-first itinerary with campsites and trailheads.' },
  { id: 'mixed', label: 'Mixed Mode', emoji: '🧭', summary: 'Combine road, rail, hiking, and backcountry legs in one trip.' },
]

export const EXPERIENCE_OPTIONS: ExperienceOption[] = [
  { id: 'beginner', label: 'Beginner', summary: 'First-time or short, lower-commitment routes.' },
  { id: 'intermediate', label: 'Intermediate', summary: 'Some outdoor experience and comfort with longer days.' },
  { id: 'advanced', label: 'Advanced', summary: 'Remote, technical, or high-effort itineraries.' },
]

export const SAMPLE_LOOKUP: Record<string, Waypoint> = {
  banff: { name: 'Banff, AB', lat: 51.1784, lon: -115.5708, nights: 1, isStop: true },
  calgary: { name: 'Calgary, AB', lat: 51.0447, lon: -114.0719, nights: 1, isStop: true },
  vancouver: { name: 'Vancouver, BC', lat: 49.2827, lon: -123.1207, nights: 1, isStop: true },
  victoria: { name: 'Victoria, BC', lat: 48.4284, lon: -123.3656, nights: 1, isStop: true },
  tofino: { name: 'Tofino, BC', lat: 49.1526, lon: -125.9033, nights: 1, isStop: true },
}

export const HIKING_SEARCH_KEYWORDS = [
  'trail', 'trailhead', 'hiking', 'hike', 'backcountry', 'camp_site', 'camp site', 'campsite', 'campground',
  'portage', 'provincial park', 'national park', 'conservation area', 'wilderness', 'forest', 'trek',
  'footpath', 'loop', 'summit', 'lookout', 'canoe', 'paddle',
]

const PORTAGE_ACCESS_KEYWORDS = [
  'access point', 'put in', 'put-in', 'take out', 'take-out', 'boat launch', 'canoe launch', 'landing',
  'boat ramp', 'dock', 'launch',
]

export const isAdventureMode = (mode: string) => {
  const m = mode.trim().toLowerCase()
  return m === 'hiking' || m === 'portaging'
}

export function normalizeBuilderMode(raw: string): string {
  let m = (raw ?? '').trim().toLowerCase()
  if (m === 'driving') m = 'car'
  if (m === 'flying' || m === 'flight') m = 'plane'
  if (m === 'rail' || m === 'public_transit' || m === 'public transit') m = 'train'
  if (m === 'walking') m = 'walk'
  if (m === 'bicycling' || m === 'biking' || m === 'bikepacking') m = 'bike'
  if (m === 'canoe' || m === 'portage' || m === 'canoeing') m = 'portaging'
  if (m === 'backpacking') m = 'hiking'
  if (m === 'gas/stops' || m === 'gas-stops' || m === 'gasstops') m = 'gas_stops'
  return BUILDER_TRANSPORT_OPTIONS.some((o) => o.mode === m) ? m : 'car'
}

export const defaultRoutingTypeForMode = (mode: string) => {
  switch (normalizeBuilderMode(mode)) {
    case 'hiking': return 'trails'
    case 'portaging': return 'waterway'
    default: return 'calculated'
  }
}

export function normalizeBuilderRoutingType(raw: string, mode: string): string {
  if ((raw ?? '').trim().toLowerCase() === 'direct') return 'direct'
  return defaultRoutingTypeForMode(mode)
}

export const primaryRoutingLabelForMode = (mode: string) => {
  switch (normalizeBuilderMode(mode)) {
    case 'hiking': return 'Trail'
    case 'portaging': return 'Waterway'
    default: return 'Calculated'
  }
}

export function routingDescription(routingType: string, mode: string): string {
  const type = normalizeBuilderRoutingType(routingType, mode)
  if (type === 'direct') return 'Straight-line preview. Fast for rough planning, but it ignores mapped routes.'
  switch (normalizeBuilderMode(mode)) {
    case 'hiking': return 'Follows mapped trails and trail connectors for a more realistic hiking line.'
    case 'portaging': return 'Follows mapped waterways and portage links instead of a crow-flies shortcut.'
    default: return 'Uses the normal routed path for this leg instead of a straight line.'
  }
}

export const transportLabelForMode = (mode: string) =>
  BUILDER_TRANSPORT_OPTIONS.find((o) => o.mode === normalizeBuilderMode(mode))?.label ?? 'Route'

export const defaultTransportModeForTripType = (tripType: string) => {
  switch (normalizeTripType(tripType)) {
    case 'portage': return 'portaging'
    case 'hiking': return 'hiking'
    default: return 'car'
  }
}

export function availableTransportOptionsForTripType(tripType: string): TransportOption[] {
  const pick = (modes: string[]) => BUILDER_TRANSPORT_OPTIONS.filter((o) => modes.includes(o.mode))
  switch (normalizeTripType(tripType)) {
    case 'portage': return pick(['portaging', 'hiking', 'walk'])
    case 'hiking': return pick(['hiking', 'walk', 'bike'])
    case 'mixed': return BUILDER_TRANSPORT_OPTIONS
    default: return pick(['car', 'plane', 'train', 'walk', 'bike', 'gas_stops'])
  }
}

export const tripTypeSummary = (raw: string) =>
  TRIP_TYPE_OPTIONS.find((o) => o.id === normalizeTripType(raw))?.summary ??
  'Plan your route with the right transport and overnight context from the start.'

export function modeSelectionHelperText(tripType: string): string {
  switch (normalizeTripType(tripType)) {
    case 'portage': return 'Portage trips default to waterway routing. Change a leg to Hiking if it should follow a trail instead.'
    case 'hiking': return 'Hiking trips default to trail routing. Change the selected leg only if one segment needs a different surface.'
    case 'mixed': return 'Top pills set the selected leg. Use Mixed Mode when one itinerary genuinely combines road, rail, and backcountry travel.'
    default: return 'Top pills only set the selected leg. Tap a destination card to change which leg is active.'
  }
}

export function tripTypeSearchHint(tripType: string, hasWaypoints: boolean): string {
  switch (normalizeTripType(tripType)) {
    case 'portage': return hasWaypoints ? 'Search campsites, lakes & portages' : 'Search access points, put-ins & canoe launches'
    case 'hiking': return 'Search trailheads, campsites & trails'
    case 'mixed': return 'Search locations, campsites & transfer points'
    default: return 'Search locations'
  }
}

export function tripTypeGuide(tripType: string, hasWaypoints: boolean): { title: string; body: string } {
  switch (normalizeTripType(tripType)) {
    case 'portage':
      return hasWaypoints
        ? { title: 'Step 2: Add reachable campsites', body: 'Now add mapped campsites reachable from your access point, or use Suggested to get the next realistic stay stop. You can also click campsite and access-point markers on the map.' }
        : { title: 'Step 1: Choose your access point', body: 'Portage trips usually begin at an access point or boat launch. Try Brent Access Point, Shall Lake, or Magnetawan Lake, or click a blue access marker on the map.' }
    case 'hiking':
      return { title: 'Trail-first trip planning', body: 'Start with a trailhead or campsite, then add only the overnight stops that should use your trip nights.' }
    case 'mixed':
      return { title: 'Blend modes as needed', body: 'Pick the main trip type here, then switch individual legs below when a segment should be rail, road, or backcountry.' }
    default:
      return { title: 'Add towns, parks, and stays', body: 'Search naturally for towns, parks, and addresses, or click the map to add a custom stop.' }
  }
}

export interface GuideStep { title: string; detail: string; active: boolean; done: boolean }

export function guideSteps(tripType: string, waypointCount: number): GuideStep[] {
  const defs: [string, string][] = (() => {
    switch (normalizeTripType(tripType)) {
      case 'portage': return [
        ['Pick an access point', 'Start from a real launch, put-in, or blue access marker.'],
        ['Add reachable campsites', 'Stay on mapped waterways and portage links when building the route.'],
        ['Tune each leg', 'Only switch a leg away from water when it should truly become hiking.'],
      ]
      case 'hiking': return [
        ['Start at a trailhead', 'Choose the first trail access or campsite anchor for the trip.'],
        ['Stack overnight stops', 'Add only the campsites that should count toward trip nights.'],
        ['Refine the route', 'Adjust leg mode and difficulty once the basic overnight flow exists.'],
      ]
      case 'mixed': return [
        ['Drop in the anchors', 'Start with the major places that define the trip.'],
        ['Switch leg modes', 'Set the segments that should be rail, road, or backcountry.'],
        ['Polish and save', 'Check nights, tune routing, then save or share the itinerary.'],
      ]
      default: return [
        ['Add the first stop', 'Search naturally for towns, parks, hotels, and addresses.'],
        ['Chain the route', 'Stack more destinations to build the full road trip flow.'],
        ['Adjust and save', 'Fine-tune legs, route shape, and trip nights before saving.'],
      ]
    }
  })()
  return defs.map(([title, detail], i) => ({
    title,
    detail,
    active: i === 0 ? waypointCount === 0 : i === 1 ? waypointCount > 0 && waypointCount < 2 : waypointCount >= 2,
    done: i === 0 ? waypointCount > 0 : i === 1 ? waypointCount >= 2 : false,
  }))
}

// ---- search helpers ----------------------------------------------------------------------------

export interface SearchResult { name?: string; display_name?: string; address?: string; lat: number | string; lon: number | string; [k: string]: any }

export const searchResultText = (r: SearchResult) =>
  [r.name, r.display_name, r.address].map((s) => String(s ?? '').trim()).filter(Boolean).join(' ').toLowerCase()

export const looksLikePortageAccessResult = (r: SearchResult) => {
  const t = searchResultText(r)
  return !!t && PORTAGE_ACCESS_KEYWORDS.some((k) => t.includes(k))
}

export const looksLikeHikingResult = (r: SearchResult) => {
  const t = searchResultText(r)
  return !!t && HIKING_SEARCH_KEYWORDS.some((k) => t.includes(k))
}

export const containsHikingKeyword = (raw: string) => {
  const t = raw.trim().toLowerCase()
  return !!t && HIKING_SEARCH_KEYWORDS.some((k) => t.includes(k))
}

export function portageAccessBiasedQuery(q: string): string {
  const t = q.trim()
  if (!t) return t
  const l = t.toLowerCase()
  if (looksLikePortageAccessResult({ name: l, display_name: l, lat: 0, lon: 0 })) return t
  return `${t} access point canoe launch boat launch put in landing`
}

export function hikingBiasedQuery(q: string): string {
  const t = q.trim()
  if (!t) return t
  const l = t.toLowerCase()
  if (HIKING_SEARCH_KEYWORDS.some((k) => l.includes(k))) return t
  return `${t} hiking trail campsite portage canoe`
}

export const coerceCoord = (raw: unknown): number | null => {
  const n = typeof raw === 'number' ? raw : typeof raw === 'string' ? parseFloat(raw) : NaN
  return Number.isFinite(n) ? n : null
}

function filterByKeyword(results: SearchResult[], predicate: (r: SearchResult) => boolean): SearchResult[] {
  const out: SearchResult[] = []
  const seen = new Set<string>()
  for (const r of results) {
    if (!predicate(r)) continue
    const lat = coerceCoord(r.lat)
    const lon = coerceCoord(r.lon)
    if (lat == null || lon == null) continue
    const key = `${lat.toFixed(5)},${lon.toFixed(5)}`
    if (seen.has(key)) continue
    seen.add(key)
    out.push(r)
    if (out.length >= 8) break
  }
  return out
}
export const filterPortageAccessResults = (r: SearchResult[]) => filterByKeyword(r, looksLikePortageAccessResult)
export const filterHikingResults = (r: SearchResult[]) => filterByKeyword(r, looksLikeHikingResult)

export function searchResultCategory(r: SearchResult): { label: string; color: string; kind: 'access' | 'camp' | 'trail' | 'place' } {
  const text = searchResultText(r)
  if (looksLikePortageAccessResult(r)) return { label: 'Access point', color: '#1565C0', kind: 'access' }
  if (text.includes('campsite') || text.includes('campground') || text.includes('camp site')) return { label: 'Campsite', color: '#2E7D32', kind: 'camp' }
  if (text.includes('portage') || text.includes('trail') || text.includes('trailhead')) return { label: 'Trail / portage', color: '#6D4C41', kind: 'trail' }
  return { label: 'Location', color: '#FF7043', kind: 'place' }
}

export function rawLocationFromResult(r: SearchResult, fallbackQuery: string): string {
  const name = String(r.name ?? '').trim()
  const display = String(r.display_name ?? r.address ?? '').trim()
  if (!name && !display) return fallbackQuery
  if (!display) return name
  if (!name) return display
  if (display.toLowerCase().includes(name.toLowerCase())) return display
  return `${name}, ${display}`
}

// ---- adventure leg hints ------------------------------------------------------------------------

export function adventureDifficultyForDistance(km: number | null | undefined, mode: string): string {
  const d = km ?? 0
  const m = normalizeBuilderMode(mode)
  if (m === 'portaging') return d >= 10 ? 'Advanced' : d >= 5 ? 'Intermediate' : 'Beginner-friendly'
  if (m === 'hiking') return d >= 16 ? 'Advanced' : d >= 8 ? 'Intermediate' : 'Beginner-friendly'
  return d >= 12 ? 'Intermediate' : 'Beginner-friendly'
}

export function adventureEstimatedTime(km: number | null | undefined, mode: string): string {
  const d = km ?? 0
  const speed = normalizeBuilderMode(mode) === 'portaging' ? 3.2 : 4.2
  if (d <= 0) return 'Route time updates after you add it'
  const hours = d / speed
  if (hours < 1) return `${Math.max(20, Math.round(hours * 60))} min`
  const whole = Math.floor(hours)
  const minutes = Math.round((hours - whole) * 60)
  return minutes === 0 ? `${whole} hr` : `${whole} hr ${String(minutes).padStart(2, '0')} min`
}

export function adventureWarning(km: number | null | undefined, mode: string): string | null {
  const d = km ?? 0
  const m = normalizeBuilderMode(mode)
  if (m === 'portaging' && d >= 10) return 'This is a long backcountry leg. Make sure your group is comfortable with a full day of paddling and portaging.'
  if (m === 'hiking' && d >= 18) return 'This is a long hiking leg. Double-check daylight, pack weight, and campsite spacing before saving.'
  return null
}

// ---- validation ----------------------------------------------------------------------------------

export const isPlaceholderWaypointName = (name: string) => {
  const n = name.trim().toLowerCase()
  return !n || n === 'dropped pin'
}

export function looksLikeTestTripName(value: string): boolean {
  const n = value.trim().toLowerCase()
  if (!n) return false
  if (/^(test|testing|demo|sample|untitled|new trip|trip|my trip|asdf|qwer|zxcv)$/.test(n)) return true
  const tokens = n.split(/\s+/).filter(Boolean)
  if (tokens.length !== 1) return false
  const token = tokens[0]
  if (/\d/.test(token) && token.length <= 12) return true
  const letters = token.replace(/[^a-z]/g, '')
  if (letters.length < 5) return false
  if (!/[aeiouy]/.test(letters)) return true
  let longest = 0
  let run = 0
  for (const ch of letters) {
    if ('aeiouy'.includes(ch)) run = 0
    else { run++; if (run > longest) longest = run }
  }
  return letters.length >= 7 && longest >= 5
}

export function tripNameValidationMessage(name: string): string | null {
  const t = name.trim()
  if (!t) return 'Trip name is required.'
  if (t.length < 3) return 'Trip name must be at least 3 characters.'
  if (looksLikeTestTripName(t)) return 'Use a more descriptive trip name before saving.'
  return null
}

export const waypointValidationMessage = (wps: Waypoint[]) =>
  wps.some((w) => isPlaceholderWaypointName(w.name)) ? 'Please name all your stops before saving.' : null

// ---- dates & geometry ---------------------------------------------------------------------------

export const stripTime = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate())
export const ymd = (d: Date) =>
  `${String(d.getFullYear()).padStart(4, '0')}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
export const parseYmd = (s: string): Date | null => {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s)
  return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : null
}
export const addDays = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n)
export const diffDays = (a: Date, b: Date) => Math.round((stripTime(a).getTime() - stripTime(b).getTime()) / 86400000)

export function haversineKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const r = 6371
  const rad = (d: number) => d * (Math.PI / 180)
  const dLat = rad(lat2 - lat1)
  const dLon = rad(lon2 - lon1)
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLon / 2) ** 2
  return r * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}
