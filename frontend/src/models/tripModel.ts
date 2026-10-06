import { Timestamp } from 'firebase/firestore'

export function normalizeTripMode(raw?: string | null): string {
  let value = (raw ?? '').trim().toLowerCase()
  if (value === 'driving') value = 'car'
  if (value === 'flying' || value === 'flight') value = 'plane'
  if (value === 'rail' || value === 'public transit' || value === 'public_transit') value = 'train'
  if (value === 'walking') value = 'walk'
  if (value === 'bicycling' || value === 'biking' || value === 'bikepacking') value = 'bike'
  if (value === 'canoe' || value === 'canoeing' || value === 'portage') value = 'portaging'
  if (value === 'backpacking') value = 'hiking'
  if (value === 'gas/stops' || value === 'gas-stops') value = 'gas_stops'
  return value
}

export type TripType = 'road' | 'portage' | 'hiking' | 'mixed'

export function normalizeTripType(
  raw?: string | null,
  opts: { transportMode?: string | null; segmentTransportModes?: string[] | null } = {},
): TripType {
  const normalizedRaw = (raw ?? '').trim().toLowerCase()
  switch (normalizedRaw) {
    case 'road':
    case 'road_trip':
    case 'road trip':
      return 'road'
    case 'portage':
    case 'portaging':
    case 'canoe':
    case 'canoe_trip':
    case 'canoe trip':
    case 'backcountry':
    case 'backcountry_portage':
    case 'backcountry portage':
      return 'portage'
    case 'hiking':
    case 'backpacking':
    case 'hiking_trip':
    case 'hiking trip':
      return 'hiking'
    case 'mixed':
    case 'mixed_mode':
    case 'mixed mode':
      return 'mixed'
  }

  const modes = new Set<string>()
  const addMode = (m?: string | null) => {
    const n = normalizeTripMode(m)
    if (n) modes.add(n)
  }
  addMode(opts.transportMode)
  for (const m of opts.segmentTransportModes ?? []) addMode(m)

  const hasPortage = modes.has('portaging')
  const hasHiking = modes.has('hiking')
  const hasRoadMode = [...modes].some((m) => m === 'car' || m === 'plane' || m === 'train')
  const hasMixedSurface =
    (hasPortage && (hasRoadMode || hasHiking)) ||
    (hasHiking && hasRoadMode) ||
    [...modes].filter((m) => m).length >= 3

  if (hasMixedSurface) return 'mixed'
  if (hasPortage) return 'portage'
  if (hasHiking) return 'hiking'
  return 'road'
}

export function isAdventureTripType(raw?: string | null): boolean {
  const t = normalizeTripType(raw)
  return t === 'portage' || t === 'hiking'
}

export function tripTypeDisplayLabel(raw?: string | null): string {
  switch (normalizeTripType(raw)) {
    case 'portage':
      return 'Portage / Canoe Trip'
    case 'hiking':
      return 'Hiking / Backpacking Trip'
    case 'mixed':
      return 'Mixed Mode Trip'
    default:
      return 'Road Trip'
  }
}

export function tripTypeBadgeLabel(raw?: string | null): string {
  switch (normalizeTripType(raw)) {
    case 'portage':
      return 'BACKCOUNTRY PORTAGE'
    case 'hiking':
      return 'HIKING / BACKPACKING'
    case 'mixed':
      return 'MIXED MODE'
    default:
      return 'ROAD TRIP'
  }
}

export function tripTypeEmoji(raw?: string | null): string {
  switch (normalizeTripType(raw)) {
    case 'portage':
      return '🏕️'
    case 'hiking':
      return '🥾'
    case 'mixed':
      return '🧭'
    default:
      return '🚗'
  }
}

export function normalizeTripExperienceLevel(raw?: string | null): string {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'beginner':
    case 'easy':
    case 'novice':
      return 'beginner'
    case 'intermediate':
    case 'moderate':
      return 'intermediate'
    case 'advanced':
    case 'expert':
    case 'challenging':
      return 'advanced'
    default:
      return ''
  }
}

export function tripExperienceDisplayLabel(raw?: string | null): string {
  switch (normalizeTripExperienceLevel(raw)) {
    case 'intermediate':
      return 'Intermediate'
    case 'advanced':
      return 'Advanced'
    case 'beginner':
      return 'Beginner'
    default:
      return ''
  }
}

export function inferTripDifficultyLabel(opts: {
  tripType?: string | null
  experienceLevel?: string | null
  distanceKm?: number | null
  estimatedDurationMin?: number | null
  stopCount?: number
  segmentTransportModes?: string[] | null
}): string {
  const explicit = tripExperienceDisplayLabel(opts.experienceLevel)
  if (explicit) return explicit

  const type = normalizeTripType(opts.tripType, { segmentTransportModes: opts.segmentTransportModes })
  const km = opts.distanceKm ?? 0
  const minutes = opts.estimatedDurationMin ?? 0
  const stopCount = opts.stopCount ?? 0
  const stopWeight = stopCount <= 1 ? 0 : (stopCount - 1) * 1.2

  if (type === 'road') {
    if (km >= 1200 || stopCount >= 6) return 'Advanced'
    if (km >= 450 || stopCount >= 4) return 'Intermediate'
    return 'Beginner'
  }

  let score = km + minutes / 180 + stopWeight
  if (type === 'mixed') score += 3
  if (score >= 16) return 'Advanced'
  if (score >= 8) return 'Intermediate'
  return 'Beginner'
}

export function inferTripRequiredSkills(opts: {
  tripType?: string | null
  segmentTransportModes?: string[] | null
}): string[] {
  const type = normalizeTripType(opts.tripType, { segmentTransportModes: opts.segmentTransportModes })
  switch (type) {
    case 'portage':
      return ['Paddling', 'Portaging', 'Camp setup']
    case 'hiking':
      return ['Navigation', 'Camp setup', 'Trail travel']
    case 'mixed':
      return ['Route planning', 'Mode changes']
    default:
      return ['Trip planning']
  }
}

export interface Stop {
  placeName: string
  latitude: number
  longitude: number
  placeId?: string | null
}

function asNumber(value: unknown): number {
  if (typeof value === 'number') return value
  if (typeof value === 'string') {
    const n = parseFloat(value)
    return Number.isFinite(n) ? n : 0
  }
  return 0
}

export function stopFromMap(data: Record<string, any>): Stop {
  // Support both naming conventions:
  //   Firestore waypoints: name / lat / lon
  //   Legacy TripModel:    placeName / latitude / longitude
  return {
    placeName: String(data.name ?? data.placeName ?? data.title ?? ''),
    latitude: asNumber(data.lat ?? data.latitude),
    longitude: asNumber(data.lon ?? data.lng ?? data.longitude),
    placeId: typeof data.placeId === 'string' ? data.placeId : null,
  }
}

export function stopToMap(s: Stop): Record<string, any> {
  return { name: s.placeName, lat: s.latitude, lon: s.longitude, placeId: s.placeId ?? null }
}

export interface TripModel {
  id: string
  tripName: string
  stops: Stop[]
  startDate: Date
  endDate: Date
  distance?: number | null // km
  description?: string | null
  participants?: string[] | null
  transportMode?: string | null
  segmentTransportModes?: string[] | null
  segmentRoutingTypes?: string[] | null
  tripType?: string | null
  experienceLevel?: string | null
  difficultyLabel?: string | null
  estimatedDurationMin?: number | null
  requiredSkills?: string[] | null
}

function parseDate(v: unknown): Date {
  if (v instanceof Timestamp) return v.toDate()
  if (v instanceof Date) return v
  if (typeof v === 'string' && v) {
    const d = new Date(v)
    if (!Number.isNaN(d.getTime())) return d
  }
  return new Date()
}

function parseStringList(raw: unknown): string[] | null {
  if (!Array.isArray(raw)) return null
  const out = raw.map((e) => String(e).trim()).filter(Boolean)
  return out.length ? out : null
}

export function tripFromMap(data: Record<string, any>, id: string): TripModel {
  // Support both 'waypoints' (live Firestore) and 'stops' (legacy)
  const rawStops = data.waypoints ?? data.stops
  const stops: Stop[] = []
  if (Array.isArray(rawStops)) {
    for (const s of rawStops) if (s && typeof s === 'object') stops.push(stopFromMap(s))
  }

  const name = String(data.name ?? data.tripName ?? 'Untitled Trip')
  const rawTransport = String(data.transportMode ?? '').trim()
  const segmentModes = parseStringList(data.segmentTransportModes)
  const rawDistance = data.totalKm ?? data.distance
  const distance = stops.length >= 2 && typeof rawDistance === 'number' ? rawDistance : null
  const tripType = normalizeTripType(String(data.tripType ?? ''), {
    transportMode: rawTransport,
    segmentTransportModes: segmentModes,
  })
  const experience = normalizeTripExperienceLevel(String(data.experienceLevel ?? data.experience ?? ''))
  const estimatedDurationMin = typeof data.estimatedDurationMin === 'number' ? data.estimatedDurationMin : null
  const requiredSkills =
    parseStringList(data.requiredSkills) ??
    parseStringList(data.required_skills) ??
    inferTripRequiredSkills({ tripType, segmentTransportModes: segmentModes })
  const rawDifficulty = String(data.difficultyLabel ?? data.difficulty ?? '').trim()

  return {
    id,
    tripName: name,
    stops,
    startDate: parseDate(data.startDate),
    endDate: parseDate(data.endDate),
    distance,
    description: typeof data.description === 'string' ? data.description : null,
    participants: Array.isArray(data.sharedWith ?? data.participants)
      ? (data.sharedWith ?? data.participants).map(String)
      : [],
    transportMode: rawTransport || null,
    segmentTransportModes: segmentModes,
    segmentRoutingTypes: parseStringList(data.segmentRoutingTypes),
    tripType,
    experienceLevel: experience || null,
    difficultyLabel:
      rawDifficulty ||
      inferTripDifficultyLabel({
        tripType,
        experienceLevel: experience,
        distanceKm: distance,
        estimatedDurationMin,
        stopCount: stops.length,
        segmentTransportModes: segmentModes,
      }),
    estimatedDurationMin,
    requiredSkills,
  }
}

export function tripToMap(t: TripModel): Record<string, any> {
  const out: Record<string, any> = {
    name: t.tripName,
    waypoints: t.stops.map(stopToMap),
    startDate: t.startDate.toISOString(),
    endDate: t.endDate.toISOString(),
    totalKm: t.stops.length >= 2 ? (t.distance ?? null) : null,
    description: t.description ?? null,
    sharedWith: t.participants ?? [],
  }
  if (t.transportMode != null) out.transportMode = t.transportMode
  if (t.segmentTransportModes != null) out.segmentTransportModes = t.segmentTransportModes
  if (t.segmentRoutingTypes != null) out.segmentRoutingTypes = t.segmentRoutingTypes
  if (t.tripType != null) out.tripType = t.tripType
  if (t.experienceLevel != null) out.experienceLevel = t.experienceLevel
  if (t.difficultyLabel != null) out.difficultyLabel = t.difficultyLabel
  if (t.estimatedDurationMin != null) out.estimatedDurationMin = t.estimatedDurationMin
  if (t.requiredSkills != null) out.requiredSkills = t.requiredSkills
  return out
}

export const tripDurationDays = (t: TripModel) =>
  Math.floor((t.endDate.getTime() - t.startDate.getTime()) / 86400000) + 1

export const tripFormattedDates = (t: TripModel) => {
  const f = (d: Date) => `${d.getMonth() + 1}/${d.getDate()}/${d.getFullYear()}`
  return `${f(t.startDate)} - ${f(t.endDate)}`
}
