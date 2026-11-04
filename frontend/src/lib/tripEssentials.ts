import type { Partner } from '@/services/partners'

export type Region = 'europe' | 'asia' | 'other'

/** Coarse bounding boxes: only used to rank partners (Klook in Asia, Auto Europe in Europe), never to block content. */
export function regionOf(lat: number, lon: number): Region {
  if (lat >= 34 && lat <= 72 && lon >= -25 && lon <= 45) return 'europe'
  if (lat >= -12 && lat <= 60 && lon >= 60 && lon <= 180) return 'asia'
  return 'other'
}

const rad = (d: number) => (d * Math.PI) / 180
function distanceKm(aLat: number, aLon: number, bLat: number, bLon: number): number {
  const h = Math.sin(rad(bLat - aLat) / 2) ** 2 + Math.cos(rad(aLat)) * Math.cos(rad(bLat)) * Math.sin(rad(bLon - aLon) / 2) ** 2
  return 2 * 6371 * Math.asin(Math.sqrt(h))
}

export interface EssentialsContext {
  /** Travel modes used on the trip (driving, flying, transit, walking, biking, portaging, hiking). */
  modes: Set<string>
  regions: Set<Region>
  hasStays: boolean
  /** Distance from the first stop to the farthest one. */
  spanKm: number
}

const ADVENTURE = new Set(['hiking', 'portaging'])

/**
 * `legModes` are the per-leg modes when the trip has legs; with a single stop there are none, so the trip's
 * default mode is used instead (it is meaningless once legs exist, so it is not mixed in).
 */
export function essentialsContext(
  waypoints: { lat?: unknown; lon?: unknown; lng?: unknown }[],
  legModes: string[],
  defaultMode: string,
  stayCount: number,
): EssentialsContext {
  const points = waypoints
    .map((w) => ({ lat: Number(w.lat), lon: Number(w.lon ?? w.lng) }))
    .filter((p) => Number.isFinite(p.lat) && Number.isFinite(p.lon))
  const spanKm = points.reduce((m, p) => Math.max(m, distanceKm(points[0].lat, points[0].lon, p.lat, p.lon)), 0)
  return {
    modes: new Set(legModes.length ? legModes : [defaultMode]),
    regions: new Set(points.map((p) => regionOf(p.lat, p.lon))),
    hasStays: stayCount > 0,
    spanKm: points.length ? spanKm : 0,
  }
}

interface Rule {
  applies: (c: EssentialsContext) => boolean
  /** How many partners are shown up front; the rest of the category sits under "More options". */
  show: number
}

const flies = (c: EssentialsContext) => c.modes.has('flying')
const allAdventure = (c: EssentialsContext) => [...c.modes].every((m) => ADVENTURE.has(m))
const RULES: Record<string, Rule> = {
  activities: { applies: (c) => !allAdventure(c), show: 2 }, // museum tickets make no sense on a wilderness route
  car: { applies: (c) => c.modes.has('driving') || [...c.modes].some((m) => ADVENTURE.has(m)), show: 2 }, // adventure trips still need a ride to the trailhead
  flights: { applies: flies, show: 2 },
  transfer: { applies: flies, show: 2 },
  esim: { applies: (c) => flies(c) || c.spanKm > 1500, show: 2 }, // a flight or a very long trip usually means leaving the home network
  luggage: { applies: (c) => c.hasStays && !allAdventure(c), show: 1 },
  bike: { applies: (c) => c.modes.has('biking'), show: 1 },
  claims: { applies: flies, show: 1 },
}

export interface EssentialsGroup {
  category: string
  title: string
  /** Shown up front. */
  partners: Partner[]
  /** The remaining options for this category. */
  more: Partner[]
}

/** The partners worth showing for this trip, grouped by category. Region-matched partners rank first. */
export function essentialsGroups(partners: Partner[], ctx: EssentialsContext): EssentialsGroup[] {
  const order: string[] = []
  const byCategory = new Map<string, Partner[]>()
  for (const p of partners) {
    if (!byCategory.has(p.category)) { byCategory.set(p.category, []); order.push(p.category) }
    byCategory.get(p.category)!.push(p)
  }

  const groups: EssentialsGroup[] = []
  if (ctx.regions.size === 0) return groups // no located stops yet: nothing to tailor to
  for (const category of order) {
    const rule = RULES[category]
    if (!rule?.applies(ctx)) continue
    const eligible = byCategory.get(category)!
      .map((p, index) => ({ p, index }))
      .filter(({ p }) => !p.onlyRegions.length || p.onlyRegions.some((r) => ctx.regions.has(r as Region)))
    // Regional specialists lead where they are strong and trail everywhere else; worldwide partners sit in between.
    const rank = ({ p }: { p: Partner }) => (!p.preferRegions.length ? 1 : p.preferRegions.some((r) => ctx.regions.has(r as Region)) ? 0 : 2)
    eligible.sort((a, b) => rank(a) - rank(b) || a.index - b.index)
    const all = eligible.map(({ p }) => p)
    if (all.length) groups.push({ category, title: all[0].categoryTitle, partners: all.slice(0, rule.show), more: all.slice(rule.show) })
  }
  return groups
}
