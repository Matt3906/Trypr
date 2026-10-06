// Pure helpers for the trip planning workspace (ported from trip_planning_screen.dart).
import { budgetPersonById, customBudgetPerson, type BudgetPerson } from '@/models/budgetPerson'
import type { TravelRouteOption } from '@/services/routeOptions'
import { isValidLatLon, labelsMatch, mapList, toNum, topActivityCategories } from './tripDetail'

export type Row = Record<string, any>

export const TAB_DEFS = ['Itinerary', 'Notes', 'Budget', 'Checklists', 'Documents'] as const

export const TRAVEL_CATEGORIES: Record<string, string> = {
  Hiking: '#2E7D32', Biking: '#1565C0', Walking: '#00796B', Museum: '#6A1B9A', Sightseeing: '#F57C00',
  Exploring: '#C62828', Restaurant: '#D32F2F', Shopping: '#7B1FA2', Photography: '#0277BD', Adventure: '#FBC02D',
  Driving: '#448AFF', Transit: '#546E7A', 'Free Time': '#78909C',
}
export const CATEGORY_EMOJIS: Record<string, string> = {
  Hiking: '🥾', Biking: '🚴', Walking: '🚶', Museum: '🏛️', Sightseeing: '📸', Exploring: '🧭', Restaurant: '🍽️',
  Shopping: '🛍️', Photography: '📷', Adventure: '🏔️', Driving: '🚗', Transit: '🚆', 'Free Time': '☕',
}
export const NOTE_COLORS = ['#FFFFFF', '#FFF9C4', '#B2DFDB', '#BBDEFB', '#F8BBD0', '#D1C4E9', '#FFCCBC', '#C8E6C9']
export const BUDGET_CATEGORIES = ['Transport', 'Accommodation', 'Food & Drink', 'Activities', 'Shopping', 'Insurance', 'Visa & Documents', 'Other']
export const CURRENCIES = ['USD', 'EUR', 'GBP', 'CAD', 'AUD', 'JPY', 'SEK', 'NOK', 'CHF']
export const DOCUMENT_CATEGORIES = ['Flight', 'Hotel', 'Car Rental', 'Insurance', 'Emergency', 'Visa', 'Other']
export const DOC_CATEGORY_EMOJIS: Record<string, string> = {
  Flight: '✈️', Hotel: '🏨', 'Car Rental': '🚗', Insurance: '🛡️', Emergency: '🆘', Visa: '🛂', Other: '📄',
}

const CURRENCY_SYMBOLS: Record<string, string> = { USD: '$', EUR: '€', GBP: '£', CAD: 'CA$', AUD: 'A$', JPY: '¥', SEK: 'kr', NOK: 'kr', CHF: 'CHF ' }
export const currencySymbol = (code: string) => CURRENCY_SYMBOLS[code] ?? '$'

export const newId = () => `${Date.now()}${Math.floor(Math.random() * 1e6)}`

// ---- dates ---------------------------------------------------------------------------------------

/** Parses `yyyy-mm-dd` (optionally followed by a time) as a LOCAL date, like Dart's DateTime.parse. */
export function tryParseDate(raw: string): Date | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?/.exec((raw ?? '').trim())
  if (!m) return null
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4] ?? 0), Number(m[5] ?? 0), Number(m[6] ?? 0))
  return Number.isNaN(d.getTime()) ? null : d
}
export const stripDate = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate())
export const isSameDate = (a: Date, b: Date) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
export const ymdOf = (d: Date) => `${String(d.getFullYear()).padStart(4, '0')}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
export const addDaysTo = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n)
export const daysBetween = (a: Date, b: Date) => Math.round((stripDate(a).getTime() - stripDate(b).getTime()) / 86400000)

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
export function formatDisplayDate(s: string): string {
  const d = tryParseDate(s)
  return d ? `${WEEKDAYS[d.getDay()]}, ${MONTHS[d.getMonth()]} ${d.getDate()}` : s
}

// ---- itinerary -----------------------------------------------------------------------------------

export function timeToSortValue(v: string): number {
  const parts = (v ?? '').trim().split(':')
  if (parts.length !== 2) return 1 << 30
  const h = parseInt(parts[0], 10)
  const m = parseInt(parts[1], 10)
  if (Number.isNaN(h) || Number.isNaN(m) || h < 0 || h > 23 || m < 0 || m > 59) return 1 << 30
  return h * 60 + m
}

export function sortActivitiesByStartTime(activities: Row[]): Row[] {
  return activities
    .map((a, i) => ({ a, i }))
    .sort((x, y) => {
      const xv = timeToSortValue(String(x.a.startTime ?? ''))
      const yv = timeToSortValue(String(y.a.startTime ?? ''))
      return xv !== yv ? xv - yv : x.i - y.i
    })
    .map((e) => e.a)
}

export const normalizeItineraryDays = (days: Row[]): Row[] =>
  days.map((d) => ({ ...d, activities: sortActivitiesByStartTime(mapList(d.activities)) }))

export function shortName(name: string): string {
  if (name.length <= 40) return name
  const comma = name.indexOf(',')
  if (comma > 0) return name.slice(0, comma)
  return `${name.slice(0, 37)}…`
}

export const waypointNights = (w: Row): number => {
  const raw = w.nights
  if (typeof raw === 'number') return Math.trunc(raw)
  return parseInt(String(raw ?? ''), 10) || 0
}

export function waypointCountsAsStay(waypoints: Row[], index: number): boolean {
  if (index < 0 || index >= waypoints.length) return false
  if (index === 0 || index === waypoints.length - 1) return true
  const raw = waypoints[index].isStop
  if (typeof raw === 'boolean') return raw
  return waypointNights(waypoints[index]) > 0
}

/** Existing unified itinerary, or one generated from the trip dates + waypoint stays. */
export function loadOrGenerateItinerary(tripData: Row, opts: { forceRegenerate?: boolean; carryFromDays?: Row[] } = {}): Row[] {
  const existing = tripData.tripItinerary
  if (!opts.forceRegenerate && Array.isArray(existing) && existing.length) return mapList(existing)

  const carry = new Map<string, Row>()
  for (const d of opts.carryFromDays ?? mapList(existing)) {
    const key = String(d.date ?? '').trim()
    if (key) carry.set(key, { ...d })
  }

  const start = tryParseDate(String(tripData.startDate ?? ''))
  const end = tryParseDate(String(tripData.endDate ?? ''))
  if (!start || !end) return []
  const totalDays = daysBetween(end, start) + 1
  if (totalDays <= 0) return []

  const waypoints = mapList(tripData.waypoints)
  const waypointForDate = (date: Date): [string, number] => {
    for (let w = 0; w < waypoints.length; w++) {
      if (!waypointCountsAsStay(waypoints, w)) continue
      const ws = tryParseDate(String(waypoints[w].startDate ?? ''))
      const we = tryParseDate(String(waypoints[w].endDate ?? ''))
      if (ws && we && stripDate(date) >= stripDate(ws) && stripDate(date) <= stripDate(we)) {
        return [String(waypoints[w].name ?? `Stop ${w + 1}`), w]
      }
    }
    return ['', -1]
  }

  const rawDays: Row[] = []
  for (let i = 0; i < totalDays; i++) {
    const date = addDaysTo(start, i)
    const [locName, wpIdx] = waypointForDate(date)
    let activities: Row[] = []
    if (wpIdx >= 0 && wpIdx < waypoints.length) {
      const wpItin = waypoints[wpIdx].itinerary
      const wpStart = tryParseDate(String(waypoints[wpIdx].startDate ?? ''))
      if (Array.isArray(wpItin) && wpStart) {
        const dayInWp = daysBetween(date, wpStart)
        if (dayInWp >= 0 && dayInWp < wpItin.length) {
          const dayData = wpItin[dayInWp]
          if (dayData && typeof dayData === 'object' && Array.isArray(dayData.activities)) activities = mapList(dayData.activities)
        }
      }
    }
    rawDays.push({ date: ymdOf(date), dayNumber: i + 1, locationName: locName, waypointIndex: wpIdx, activities, notes: '' })
  }

  const days: Row[] = rawDays.map((day, i) => {
    const loc = String(day.locationName)
    const nextLoc = i + 1 < rawDays.length ? String(rawDays[i + 1].locationName) : null
    const isTravel = !!loc && nextLoc != null && !!nextLoc && loc !== nextLoc
    if (isTravel) {
      day.isTravel = true
      day.travelFrom = shortName(loc)
      day.travelTo = shortName(nextLoc!)
      day.title = `Day ${day.dayNumber} – Travel`
    } else {
      day.isTravel = false
      day.title = loc ? `Day ${day.dayNumber} – ${loc}` : `Day ${day.dayNumber}`
    }
    return day
  })

  for (const day of days) {
    const previous = carry.get(String(day.date ?? ''))
    if (!previous) continue
    if (Array.isArray(previous.activities)) day.activities = sortActivitiesByStartTime(mapList(previous.activities))
    day.notes = String(previous.notes ?? '')
  }
  return days
}

// ---- map pins & insights --------------------------------------------------------------------------

export function mapItineraryActivityPins(days: Row[]): Row[] {
  const pins: Row[] = []
  days.forEach((day, dayIndex) => {
    mapList(day.activities).forEach((act, activityIndex) => {
      const lat = toNum(act.locationLat)
      const lon = toNum(act.locationLon)
      if (!isValidLatLon(lat, lon)) return
      pins.push({ lat, lon, kind: 'activity', category: String(act.category ?? 'Exploring'), name: String(act.title ?? 'Activity'), dayIndex, activityIndex })
    })
  })
  return pins
}

export function activitiesForWaypointPoint(days: Row[], waypointIndex: number, waypointName?: string): Row[] {
  const out: Row[] = []
  const seen = new Set<string>()
  const safeName = (waypointName ?? '').trim()
  for (const day of days) {
    const dayWp = typeof day.waypointIndex === 'number' ? day.waypointIndex : null
    const matchesWp = waypointIndex >= 0 && dayWp === waypointIndex
    const matchesName = !!safeName && labelsMatch(String(day.locationName ?? ''), safeName)
    if (!matchesWp && !matchesName) continue
    for (const a of mapList(day.activities)) {
      const key = [a.title, a.startTime, a.location, a.category].map((v) => String(v ?? '').trim().toLowerCase()).join('|')
      if (seen.has(key)) continue
      seen.add(key)
      out.push(a)
    }
  }
  return out
}

export const itineraryMapPointKind = (p: Row): string => {
  const kind = String(p.kind ?? p.pointType ?? '').trim().toLowerCase()
  if (kind) return kind
  return p.waypointIndex != null ? 'waypoint' : 'location'
}

export function itineraryMapPointTitle(p: Row): string {
  const title = String(p.name ?? p.title ?? '').trim()
  if (title) return title
  const wi = typeof p.waypointIndex === 'number' ? p.waypointIndex : null
  return wi != null && wi >= 0 ? `Stop ${wi + 1}` : 'Selected place'
}

export function categoriesForMapPoint(days: Row[], p: Row): string[] {
  const kind = itineraryMapPointKind(p)
  const category = String(p.category ?? '').trim()
  if (kind === 'activity') {
    const out: string[] = []
    if (category) out.push(category)
    const di = typeof p.dayIndex === 'number' ? p.dayIndex : null
    if (di != null && di >= 0 && di < days.length) {
      for (const c of topActivityCategories(mapList(days[di].activities))) if (!out.includes(c)) out.push(c)
    }
    return out.slice(0, 6)
  }
  const wi = typeof p.waypointIndex === 'number' ? p.waypointIndex : -1
  const cats = topActivityCategories(activitiesForWaypointPoint(days, wi, String(p.name ?? '')))
  if (cats.length) return cats
  return category ? [category] : []
}

export function itineraryMapPointSubtitle(days: Row[], p: Row): string {
  const kind = itineraryMapPointKind(p)
  const category = String(p.category ?? '').trim()
  const di = typeof p.dayIndex === 'number' ? p.dayIndex : null
  if (kind === 'activity') {
    const dayText = di != null && di >= 0 && di < days.length ? `Day ${days[di].dayNumber ?? di + 1}` : ''
    return [dayText, category].filter(Boolean).join(' • ')
  }
  if (kind === 'waypoint') {
    const wi = typeof p.waypointIndex === 'number' ? p.waypointIndex : null
    if (wi != null && wi >= 0) return `Stop ${wi + 1}`
  }
  return category || 'Map selection'
}

export function itineraryAiSummary(days: Row[], p: Row, categories: string[]): string {
  const kind = itineraryMapPointKind(p)
  const title = itineraryMapPointTitle(p)
  if (kind === 'activity') {
    const di = typeof p.dayIndex === 'number' ? p.dayIndex : null
    const dayText = di != null && di >= 0 && di < days.length ? `on Day ${days[di].dayNumber ?? di + 1}` : 'in your itinerary'
    const category = String(p.category ?? (categories[0] ?? '')).trim()
    return `${title} is planned ${dayText} and fits a ${category || 'general exploration'} focus. Keep this near your other stops to reduce transit time.`
  }
  const wi = typeof p.waypointIndex === 'number' ? p.waypointIndex : -1
  const activities = activitiesForWaypointPoint(days, wi, title)
  if (!activities.length) return `${title} is currently a routing anchor. Add activities here to build a stronger day plan.`
  const dayCount = days.filter((d) => (wi >= 0 && d.waypointIndex === wi) || labelsMatch(String(d.locationName ?? ''), title)).length
  const catText = categories.length ? categories.slice(0, 3).join(', ') : 'mixed activities'
  const dayText = dayCount > 0 ? `${dayCount} planned day${dayCount === 1 ? '' : 's'}` : 'this stop'
  return `${title} has ${activities.length} planned activit${activities.length === 1 ? 'y' : 'ies'} across ${dayText}, focused on ${catText}.`
}

// ---- travel recommendations ----------------------------------------------------------------------

export function normalizePlanningMode(raw: string): string {
  const mode = (raw ?? '').trim().toLowerCase()
  switch (mode) {
    case 'flying': return 'flying'
    case 'train': case 'rail': case 'public_transit': case 'public transit': case 'transit': return 'transit'
    case 'walking': case 'hiking': case 'portaging': case 'biking': case 'bikepacking': case 'backpacking': case 'driving': return mode
    case 'canoe': case 'canoeing': case 'portage': return 'portaging'
    default: return 'driving'
  }
}

export function segmentTransportModeFor(tripData: Row, segmentIndex: number): string {
  const fallback = normalizePlanningMode(String(tripData.transportMode ?? 'driving'))
  if (segmentIndex < 0) return fallback
  const raw = tripData.segmentTransportModes
  if (!Array.isArray(raw) || segmentIndex >= raw.length) return fallback
  return normalizePlanningMode(String(raw[segmentIndex]))
}

export function resolveWaypointIndexForDay(day: Row, waypoints: Row[]): number {
  const direct = typeof day.waypointIndex === 'number' ? day.waypointIndex : null
  if (direct != null && direct >= 0 && direct < waypoints.length) return direct

  const date = tryParseDate(String(day.date ?? ''))
  if (date) {
    for (let i = 0; i < waypoints.length; i++) {
      if (!waypointCountsAsStay(waypoints, i)) continue
      const ws = tryParseDate(String(waypoints[i].startDate ?? ''))
      const we = tryParseDate(String(waypoints[i].endDate ?? ''))
      if (!ws || !we) continue
      const ds = stripDate(date)
      if (ds >= stripDate(ws) && ds <= stripDate(we)) return i
    }
  }
  const loc = String(day.locationName ?? '').trim().toLowerCase()
  if (loc) {
    for (let i = 0; i < waypoints.length; i++) {
      if (!waypointCountsAsStay(waypoints, i)) continue
      const wp = String(waypoints[i].name ?? '').trim().toLowerCase()
      if (!wp) continue
      if (wp === loc || wp.includes(loc) || loc.includes(wp)) return i
    }
  }
  return -1
}

export function waypointCoords(waypoints: Row[], index: number): { lat: number; lon: number } | null {
  if (index < 0 || index >= waypoints.length) return null
  const wp = waypoints[index]
  const lat = toNum(wp.lat ?? wp.latitude)
  const lon = toNum(wp.lon ?? wp.lng ?? wp.longitude)
  return isValidLatLon(lat, lon) ? { lat, lon } : null
}

export function segmentIndexForTravel(fromIndex: number, toIndex: number, waypointCount: number): number {
  if (waypointCount < 2) return -1
  if (fromIndex >= 0 && toIndex >= 0) {
    if (toIndex === fromIndex + 1) return fromIndex
    if (fromIndex === toIndex + 1) return toIndex
  }
  if (fromIndex >= 0 && fromIndex < waypointCount - 1) return fromIndex
  if (toIndex > 0 && toIndex - 1 < waypointCount - 1) return toIndex - 1
  return -1
}

export function travelModeLabel(mode: string): string {
  switch (normalizePlanningMode(mode)) {
    case 'transit': return 'Transit'
    case 'walking': case 'hiking': case 'backpacking': return 'Walking'
    case 'portaging': return 'Portaging'
    case 'biking': case 'bikepacking': return 'Biking'
    case 'flying': return 'Flight'
    default: return 'Driving'
  }
}

export function travelCategoryForMode(mode: string): string {
  switch (normalizePlanningMode(mode)) {
    case 'transit': return 'Transit'
    case 'walking': case 'hiking': case 'backpacking': return 'Walking'
    case 'portaging': return 'Adventure'
    case 'biking': case 'bikepacking': return 'Biking'
    default: return 'Driving'
  }
}

export function formatDurationShort(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return ''
  const mins = Math.round(seconds / 60)
  const h = Math.floor(mins / 60)
  const m = mins % 60
  if (h > 0 && m > 0) return `${h}h ${m}m`
  if (h > 0) return `${h}h`
  return `${m}m`
}

export function formatDistanceShort(meters: number): string {
  if (!Number.isFinite(meters) || meters <= 0) return ''
  if (meters < 1000) return `${Math.round(meters)} m`
  return `${(meters / 1000).toFixed(1)} km`
}

const jsonEq = (a: unknown, b: unknown) => {
  try {
    return JSON.stringify(a) === JSON.stringify(b)
  } catch {
    return false
  }
}
export { jsonEq as jsonValueEquals }

export function timeTextTo24Hour(raw: string): string {
  const value = (raw ?? '').trim()
  if (!value) return ''
  const hhmm = /^(\d{1,2}):(\d{2})$/.exec(value)
  if (hhmm) {
    const h = parseInt(hhmm[1], 10)
    const m = parseInt(hhmm[2], 10)
    if (h >= 0 && h < 24 && m >= 0 && m < 60) return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`
  }
  const amPm = /(\d{1,2})(?::(\d{2}))?\s*([APap][Mm])/.exec(value)
  if (!amPm) return ''
  const hRaw = parseInt(amPm[1], 10)
  const mRaw = parseInt(amPm[2] ?? '0', 10)
  if (hRaw < 1 || hRaw > 12 || mRaw < 0 || mRaw > 59) return ''
  let hour = hRaw % 12
  if (amPm[3].toLowerCase() === 'pm') hour += 12
  return `${String(hour).padStart(2, '0')}:${String(mRaw).padStart(2, '0')}`
}

export function shiftTimeBySeconds(hhmm: string, seconds: number): string {
  const m = /^(\d{2}):(\d{2})$/.exec((hhmm ?? '').trim())
  if (!m) return ''
  let total = parseInt(m[1], 10) * 60 + parseInt(m[2], 10) + Math.round(seconds / 60)
  total = ((total % 1440) + 1440) % 1440
  return `${String(Math.floor(total / 60)).padStart(2, '0')}:${String(total % 60).padStart(2, '0')}`
}

export function recommendedTravelWindow(rec: Row): { start: string; end: string } {
  const durationSec = toNum(rec.durationSeconds)
  let start = timeTextTo24Hour(String(rec.departureTimeText ?? ''))
  let end = timeTextTo24Hour(String(rec.arrivalTimeText ?? ''))
  if (!start && !end && durationSec > 0) {
    start = '09:00'
    end = shiftTimeBySeconds(start, durationSec)
  } else if (start && !end && durationSec > 0) end = shiftTimeBySeconds(start, durationSec)
  else if (!start && end && durationSec > 0) start = shiftTimeBySeconds(end, -durationSec)
  return { start, end }
}

export function recommendedTravelNotes(mode: string, rec: Row): string {
  const parts: string[] = []
  const summary = String(rec.summary ?? '').trim()
  if (summary) parts.push(`Recommended route: ${summary}`)
  parts.push(`Mode: ${travelModeLabel(mode)}`)
  const duration = formatDurationShort(toNum(rec.durationSeconds))
  if (duration) parts.push(`Duration: ${duration}`)
  const distance = formatDistanceShort(toNum(rec.distanceMeters))
  if (distance) parts.push(`Distance: ${distance}`)
  if (normalizePlanningMode(mode) === 'transit') {
    parts.push(`Transfers: ${Math.trunc(Number(rec.transferCount) || 0)}`)
    const layoverMins = toNum(rec.layoverMinutes)
    parts.push(`Layovers: ${Math.trunc(Number(rec.layoverCount) || 0)} (${layoverMins > 0 ? Math.round(layoverMins) : 0} min)`)
  }
  const dep = String(rec.departureTimeText ?? '').trim()
  const arr = String(rec.arrivalTimeText ?? '').trim()
  if (dep || arr) parts.push(`Window: ${dep || '?'} -> ${arr || '?'}`)
  return parts.join('\n')
}

export function clearTravelRecommendationFields(day: Row): boolean {
  let changed = false
  for (const key of ['travelOptions', 'recommendedTravelOptionIndex', 'recommendedTravel', 'travelRecommendationStatus', 'travelRecommendationUpdatedAt', 'travelMode']) {
    if (key in day && day[key] != null) {
      delete day[key]
      changed = true
    }
  }
  const activities = mapList(day.activities)
  const filtered = activities.filter((a) => a.isAutoTravel !== true)
  if (filtered.length !== activities.length) {
    day.activities = sortActivitiesByStartTime(filtered)
    changed = true
  }
  return changed
}

export function upsertAutoTravelActivity(day: Row, mode: string, recommended: Row | null): boolean {
  const activities = mapList(day.activities)
  const existingIndex = activities.findIndex((a) => a.isAutoTravel === true)

  if (!recommended) {
    if (existingIndex >= 0) {
      activities.splice(existingIndex, 1)
      day.activities = sortActivitiesByStartTime(activities)
      return true
    }
    return false
  }

  const from = String(day.travelFrom ?? '')
  const to = String(day.travelTo ?? '')
  const { start, end } = recommendedTravelWindow(recommended)
  const activity: Row = {
    title: from && to ? `Travel: ${from} -> ${to}` : 'Travel',
    startTime: start,
    endTime: end,
    location: [from, to].filter((v) => v.trim()).join(' -> '),
    notes: recommendedTravelNotes(mode, recommended),
    category: travelCategoryForMode(mode),
    isAutoTravel: true,
    travelMode: mode,
    travelScore: toNum(recommended.score),
  }
  let changed = false
  if (existingIndex >= 0) {
    if (!jsonEq(activities[existingIndex], activity)) {
      activities[existingIndex] = activity
      changed = true
    }
  } else {
    activities.unshift(activity)
    changed = true
  }
  if (changed) day.activities = sortActivitiesByStartTime(activities)
  return changed
}

export function travelOptionScore(o: TravelRouteOption): number {
  const durationMins = o.durationSeconds > 0 ? o.durationSeconds / 60 : 100000
  return durationMins + o.transferCount * 18 + (o.layoverCount * 12 + o.layoverMinutes)
}

// ---- budget ---------------------------------------------------------------------------------------

export function parseBudgetFinalSplitCount(raw: unknown): number {
  if (typeof raw === 'number' && raw > 0) return Math.round(raw)
  const parsed = parseInt(String(raw ?? ''), 10)
  return Number.isNaN(parsed) || parsed <= 0 ? 0 : parsed
}

export function normalizedBudgetItems(items: Row[], people: BudgetPerson[]): Row[] {
  return items.map((raw) => {
    const item: Row = { ...raw }
    const paidById = String(item.paidByPersonId ?? '').trim()
    const fallbackName = String(item.paidByPersonName ?? '').trim()
    const paidBy = budgetPersonById(people, paidById)
    item.id = String(item.id ?? '').trim() || newId()
    item.description = String(item.description ?? '')
    item.category = String(item.category ?? 'Other')
    item.estimated = Number(item.estimated) || 0
    item.actual = Number(item.actual) || 0
    item.notes = String(item.notes ?? '')
    delete item.splitByCount
    if (!paidById) {
      delete item.paidByPersonId
      delete item.paidByPersonName
    } else {
      item.paidByPersonId = paidById
      item.paidByPersonName = paidBy?.name ?? fallbackName
    }
    return item
  })
}

export function budgetPeopleForItem(item: Row, people: BudgetPerson[]): BudgetPerson[] {
  const selectedId = String(item.paidByPersonId ?? '').trim()
  const fallbackName = String(item.paidByPersonName ?? '').trim()
  if (!selectedId || budgetPersonById(people, selectedId)) return people
  return [...people, customBudgetPerson(fallbackName || selectedId, selectedId)]
}

export const defaultChecklist = (): Row => ({
  id: newId(),
  title: 'Pre-Trip Preparation',
  items: [
    'Book transportation', 'Reserve accommodations', 'Get travel insurance',
    'Check passport / visa requirements', 'Notify bank of travel dates', 'Download offline maps',
  ].map((text) => ({ id: newId(), text, done: false })),
})

// ---- files ----------------------------------------------------------------------------------------

export const sanitizeFileName = (raw: string) => {
  const t = raw.trim()
  return t ? t.replace(/[^A-Za-z0-9._-]/g, '_') : 'document.bin'
}

export function formatBytes(bytes: number): string {
  if (bytes <= 0) return '0 B'
  if (bytes < 1024) return `${bytes} B`
  const kb = bytes / 1024
  if (kb < 1024) return `${kb.toFixed(1)} KB`
  const mb = kb / 1024
  if (mb < 1024) return `${mb.toFixed(1)} MB`
  return `${(mb / 1024).toFixed(2)} GB`
}

export function documentAttachmentsFor(doc: Row): Row[] {
  const out: Row[] = []
  const seen = new Set<string>()
  const add = (raw: unknown) => {
    if (!raw || typeof raw !== 'object') return
    const m = { ...(raw as Row) }
    const url = String(m.url ?? '').trim()
    if (!url || seen.has(url)) return
    seen.add(url)
    out.push(m)
  }
  if (Array.isArray(doc.attachments)) doc.attachments.forEach(add)
  add(doc.attachment)
  return out
}

/** Quill delta ops from a note (stored as a JSON list, `{ops}` map, or JSON string). */
export function parseNoteDelta(raw: unknown): any[] | null {
  if (Array.isArray(raw)) return raw
  if (raw && typeof raw === 'object' && Array.isArray((raw as any).ops)) return (raw as any).ops
  if (typeof raw === 'string') {
    try {
      const d = JSON.parse(raw)
      if (Array.isArray(d)) return d
      if (d && Array.isArray(d.ops)) return d.ops
    } catch {
      /* fall through */
    }
  }
  return null
}

export const normalizeNotePlainText = (text: string) => text.replace(/\n+$/, '')
