/** Heuristics for the globe's "Location Insight" card (ported from home_screen.dart). */
export type StopMap = Record<string, any>

export const isSafeRemoteImageUrl = (value: string): boolean => {
  try {
    const u = new URL(value.trim())
    return u.protocol === 'https:' && !!u.host
  } catch {
    return false
  }
}

export function looksRegionLabel(value: string): boolean {
  const lower = value.trim().toLowerCase()
  if (!lower) return false
  const exact = new Set(['golden horseshoe', 'greater toronto area', 'gta', 'ontario', 'canada', 'united states', 'usa', 'north america'])
  if (exact.has(lower)) return true
  return [' region', ' county', ' district', ' province', ' state'].some((t) => lower.includes(t))
}

const POI_TOKENS = ['church', 'cathedral', 'mosque', 'temple', 'museum', 'gallery', 'park', 'hotel', 'resort', 'restaurant', 'cafe', 'mall', 'plaza', 'school', 'university', 'college', 'station', 'airport', 'hospital', 'clinic', 'arena', 'stadium', 'library', 'theatre', 'theater']
export const looksPoiLabel = (value: string) => {
  const lower = value.trim().toLowerCase()
  return !!lower && POI_TOKENS.some((t) => lower.includes(t))
}

export function trimAddressNoise(raw: string): string {
  const input = raw.trim()
  if (!input) return ''
  const parts = input.split(',').map((e) => e.trim()).filter(Boolean)
  if (!parts.length) return input

  const roadTokens = ['road', 'rd', 'street', 'st', 'avenue', 'ave', 'drive', 'dr', 'blvd', 'boulevard', 'highway', 'hwy', 'route', 'lane', 'ln']
  const looksLikeAddressDetail = (seg: string) => {
    const s = seg.toLowerCase()
    return /\d/.test(s) || roadTokens.some((t) => s.includes(t))
  }
  const ignored = new Set(['canada', 'united states', 'usa', 'golden horseshoe', 'greater toronto area', 'gta', 'ontario', 'quebec', 'british columbia', 'alberta', 'manitoba', 'saskatchewan', 'nova scotia', 'new brunswick', 'newfoundland and labrador', 'pei', 'prince edward island'])
  const isRegionOrCountry = (seg: string) => {
    const s = seg.toLowerCase()
    return ignored.has(s) || ['region', 'county', 'district', 'province', 'state'].some((t) => s.includes(t))
  }

  for (let i = parts.length - 1; i >= 0; i--) {
    const seg = parts[i]
    if (seg.length < 2) continue
    if (looksRegionLabel(seg) || isRegionOrCountry(seg) || looksLikeAddressDetail(seg)) continue
    return seg
  }
  if (parts[0] && !looksRegionLabel(parts[0])) return parts[0]
  return looksRegionLabel(input) ? '' : input
}

export function extractCityFromAddress(raw: string): string {
  const value = raw.trim()
  if (!value) return ''
  const parts = value.split(',').map((e) => e.trim()).filter(Boolean)
  const looksStreet = (seg: string) => {
    const s = seg.toLowerCase()
    return (
      /\d/.test(s) ||
      s.includes(' street') || s.endsWith(' st') || s.includes(' road') || s.endsWith(' rd') ||
      s.includes(' avenue') || s.endsWith(' ave') || s.includes(' boulevard') || s.endsWith(' blvd') ||
      s.includes(' drive') || s.endsWith(' dr') || s.includes(' highway') || s.endsWith(' hwy')
    )
  }
  for (const seg of parts) {
    if (seg.length < 2 || looksRegionLabel(seg) || looksStreet(seg)) continue
    const cleaned = trimAddressNoise(seg)
    if (cleaned && !looksRegionLabel(cleaned) && !looksPoiLabel(cleaned)) return cleaned
  }
  return ''
}

export function cityFromStopFields(stop: StopMap): string {
  for (const key of ['city', 'locality', 'town', 'municipality', 'village', 'hamlet']) {
    const raw = String(stop[key] ?? '').trim()
    if (raw && !looksRegionLabel(raw) && !looksPoiLabel(raw)) {
      const cleaned = trimAddressNoise(raw)
      if (cleaned && !looksRegionLabel(cleaned) && !looksPoiLabel(cleaned)) return cleaned
    }
  }
  for (const key of ['formattedAddress', 'formatted_address', 'display_name', 'address']) {
    const c = extractCityFromAddress(String(stop[key] ?? ''))
    if (c) return c
  }
  const itinerary = stop.itinerary
  if (Array.isArray(itinerary)) {
    for (const day of itinerary) {
      if (!day || typeof day !== 'object') continue
      const dayCity = extractCityFromAddress(String(day.location ?? day.address ?? ''))
      if (dayCity) return dayCity
      if (!Array.isArray(day.activities)) continue
      for (const a of day.activities) {
        if (!a || typeof a !== 'object') continue
        const c = extractCityFromAddress(String(a.address ?? a.location ?? a.formattedAddress ?? ''))
        if (c) return c
      }
    }
  }
  return ''
}

export function focusedStopTownSeed(stop: StopMap, stopNumber: number): string {
  const explicit = String(stop.name ?? stop.title ?? '').trim()
  const cleaned = trimAddressNoise(explicit)
  if (cleaned && !looksPoiLabel(cleaned)) return cleaned
  return `Stop ${stopNumber}`
}

export function normalizeTransportModeForInsights(raw: string): string {
  let mode = raw.trim().toLowerCase()
  if (mode === 'car' || mode === 'driving') mode = 'car'
  if (['plane', 'flying', 'flight'].includes(mode)) mode = 'plane'
  if (['train', 'rail', 'public_transit', 'public transit', 'transit'].includes(mode)) mode = 'train'
  if (mode === 'walk' || mode === 'walking') mode = 'walk'
  if (['bike', 'biking', 'bicycling', 'cycling', 'bikepacking'].includes(mode)) mode = 'bike'
  if (mode === 'hiking' || mode === 'backpacking') mode = 'hiking'
  if (['portaging', 'portage', 'canoe', 'canoeing'].includes(mode)) mode = 'portaging'
  return mode
}

const isBackcountryMode = (mode: string) => {
  const n = normalizeTransportModeForInsights(mode)
  return n === 'hiking' || n === 'portaging'
}

const BACKCOUNTRY_TOKENS = ['portage', 'canoe', 'paddle', 'backcountry', 'campsite', 'camp site', 'campground', 'trail', 'trailhead', 'hiking', 'trek', 'put in', 'take out', 'lake', 'river', 'island', 'bay', 'unorganized']
export const isBackcountryToken = (raw: string) => {
  const text = raw.trim().toLowerCase()
  return !!text && BACKCOUNTRY_TOKENS.some((t) => text.includes(t))
}

export function tripUsesBackcountryMode(trip: StopMap | null): boolean {
  if (!trip) return false
  const titleSignals = [trip.title, trip.name, trip.description].map((v) => String(v ?? '')).join(' ')
  if (isBackcountryToken(titleSignals)) return true

  if (Array.isArray(trip.waypoints)) {
    for (const s of trip.waypoints) {
      if (!s || typeof s !== 'object') continue
      const signals = ['name', 'title', 'display_name', 'formattedAddress', 'formatted_address', 'address'].map((k) => String(s[k] ?? '')).join(' ')
      if (isBackcountryToken(signals)) return true
    }
  }
  if (isBackcountryMode(String(trip.transportMode ?? ''))) return true
  if (Array.isArray(trip.segmentTransportModes)) {
    for (const m of trip.segmentTransportModes) if (isBackcountryMode(String(m))) return true
  }
  return false
}

export function isBackcountryStop(stop: StopMap, trip: StopMap | null): boolean {
  if (isBackcountryToken(String(stop.name ?? stop.title ?? ''))) return true
  const displayName = String(stop.display_name ?? stop.formattedAddress ?? stop.formatted_address ?? stop.address ?? '')
  if (isBackcountryToken(displayName)) return true
  const cats = stop.activityCategories ?? stop.categories
  if (Array.isArray(cats)) {
    for (const c of cats) if (isBackcountryToken(String(c))) return true
  } else if (typeof cats === 'string' && isBackcountryToken(cats)) return true
  return tripUsesBackcountryMode(trip)
}

export function fallbackActivitiesForTown(title: string): string[] {
  const lower = title.toLowerCase()
  const out = new Set<string>()
  const addWhen = (keys: string[], acts: string[]) => {
    if (keys.some((k) => lower.includes(k))) acts.forEach((a) => out.add(a))
  }
  addWhen(['banff'], ['Hiking', 'Camping', 'Skiing/Snowboarding'])
  addWhen(['niagara'], ['Waterfall', 'Casino', 'Vineyards', 'Boat Tours'])
  addWhen(['mountain', 'alps', 'rockies', 'peak', 'ridge'], ['Hiking', 'Scenic Views', 'Camping'])
  addWhen(['beach', 'coast', 'island', 'bay'], ['Beach', 'Boating', 'Sunset Views'])
  addWhen(['falls', 'waterfall', 'lake', 'river'], ['Waterfront Walks', 'Photography', 'Boat Tours'])
  addWhen(['city', 'downtown', 'old town', 'village', 'metro'], ['Walking Tours', 'Food', 'Museums'])
  addWhen(['wine', 'vineyard', 'napa'], ['Vineyards', 'Wine Tasting', 'Local Food'])
  addWhen(['vegas', 'casino'], ['Casino', 'Nightlife', 'Shows'])
  addWhen(['park', 'forest', 'trail'], ['Hiking', 'Wildlife', 'Camping'])
  addWhen(['ski', 'snow'], ['Skiing/Snowboarding', 'Lodges', 'Mountain Views'])
  if (!out.size) ['Sightseeing', 'Local Food', 'Photography'].forEach((a) => out.add(a))
  return [...out].slice(0, 6)
}

export function topCategoriesFromSuggestions(suggestions: StopMap[], max = 6): string[] {
  const counts = new Map<string, number>()
  for (const s of suggestions) {
    const c = String(s.category ?? '').trim()
    if (c) counts.set(c, (counts.get(c) ?? 0) + 1)
  }
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, max)
    .map(([k]) => k)
}

export function poiSummaryFromSuggestions(displayName: string, categories: string[], suggestions: StopMap[]): string {
  const placeNames: string[] = []
  for (const s of suggestions) {
    let clean = String(s.name ?? '').trim()
    if (!clean) continue
    if (clean.toLowerCase().startsWith(displayName.toLowerCase())) clean = clean.slice(displayName.length).trimStart()
    clean = clean.replace(/^[-–—:]+/, '').trim()
    if (!clean) continue
    if (!placeNames.includes(clean)) placeNames.push(clean)
    if (placeNames.length >= 3) break
  }
  const categoryText = categories.length ? categories.slice(0, 3).join(', ').toLowerCase() : 'sightseeing and local experiences'
  const highlights = placeNames.length ? placeNames.join(', ') : 'a mix of curated local spots'
  return `${displayName} is a strong base for ${categoryText}, with highlights like ${highlights}.`
}

const num = (v: unknown): number => {
  if (typeof v === 'number') return v
  if (typeof v === 'string') return parseFloat(v)
  return NaN
}

export interface ActivityRecommendation {
  name: string
  category?: string
  rating?: number
  estimatedPrice?: number
}

export function activityRecommendationsFromSuggestions(suggestions: StopMap[], max = 5): ActivityRecommendation[] {
  const out: ActivityRecommendation[] = []
  const seen = new Set<string>()
  for (const s of suggestions) {
    const name = String(s.name ?? s.title ?? '').trim()
    if (!name || seen.has(name.toLowerCase())) continue
    seen.add(name.toLowerCase())
    const category = String(s.category ?? '').trim()
    const rating = num(s.rating)
    const price = num(s.estimatedPrice ?? s.price_estimate ?? s.price)
    out.push({
      name,
      ...(category ? { category } : {}),
      ...(Number.isFinite(rating) ? { rating } : {}),
      ...(Number.isFinite(price) && price >= 0 ? { estimatedPrice: Math.round(price) } : {}),
    })
    if (out.length >= max) break
  }
  return out
}

export function fallbackActivityRecommendations(title: string, categories: string[], max = 5): ActivityRecommendation[] {
  const seeds = categories.length ? categories : fallbackActivitiesForTown(title).slice(0, max)
  const out: ActivityRecommendation[] = []
  const seen = new Set<string>()
  for (const category of seeds) {
    const clean = category.trim()
    if (!clean || seen.has(clean.toLowerCase())) continue
    seen.add(clean.toLowerCase())
    out.push({ name: `${clean} around ${title}`, category: clean })
    if (out.length >= max) break
  }
  if (!out.length) out.push({ name: `Explore the top local highlights around ${title}`, category: 'Sightseeing' })
  return out
}

export function activityRecommendationMeta(r: ActivityRecommendation): string {
  const parts: string[] = []
  if (r.category?.trim()) parts.push(r.category.trim())
  if (r.rating != null && Number.isFinite(r.rating)) parts.push(`⭐ ${r.rating.toFixed(1)}`)
  if (r.estimatedPrice != null && Number.isFinite(r.estimatedPrice) && r.estimatedPrice > 0) parts.push(`$${Math.round(r.estimatedPrice)}`)
  return parts.join(' • ')
}

export function activityEmoji(label: string): string {
  const l = label.toLowerCase()
  if (l.includes('hiking') || l.includes('trail')) return '🥾'
  if (l.includes('camp')) return '⛺'
  if (l.includes('ski') || l.includes('snow')) return '🎿'
  if (l.includes('waterfall')) return '💧'
  if (l.includes('boat')) return '🚤'
  if (l.includes('vineyard') || l.includes('wine')) return '🍷'
  if (l.includes('casino')) return '🎰'
  if (l.includes('museum')) return '🏛️'
  if (l.includes('food') || l.includes('restaurant')) return '🍽️'
  if (l.includes('photo')) return '📸'
  if (l.includes('walk')) return '🚶'
  return '📌'
}

const isNatureAreaLabel = (value: string) =>
  ['park', 'forest', 'trail', 'falls', 'waterfall', 'lake', 'river', 'beach', 'mountain', 'valley', 'reserve', 'national', 'conservation'].some((t) => value.toLowerCase().includes(t))

export function normalizePhotoTag(value: string): string {
  const cleaned = value.toLowerCase().replace(/[^a-z0-9\s]/g, ' ').replace(/\s+/g, ' ').trim()
  if (!cleaned) return 'travel'
  const parts = cleaned.split(' ').filter((p) => p.length >= 3).slice(0, 2)
  return parts.length ? parts.join(',') : 'travel'
}

export function realisticFallbackPhotoUrl(seed: string, index: number, natureBias?: boolean): string {
  const looksNature = natureBias ?? isNatureAreaLabel(seed)
  const baseTags = looksNature ? 'nature,landscape,travel' : 'city,travel,landmark'
  const locationTag = normalizePhotoTag(seed)
  let lock = 0
  for (let i = 0; i < seed.length; i++) lock = (lock + seed.charCodeAt(i)) % 100000
  lock += index * 37
  return `https://loremflickr.com/900/520/${baseTags},${locationTag}?lock=${Math.abs(lock)}`
}

export const fallbackGalleryImageUrl = (title: string, index: number) =>
  realisticFallbackPhotoUrl(title ? `${title}-gallery-${index + 1}` : 'travel-town', index)

export const fallbackTownImageUrl = (title: string) =>
  `https://source.unsplash.com/900x520/?${encodeURIComponent(`${normalizePhotoTag(title || 'travel-city').replace(/,/g, ' ')}, travel`)}`

export function addImageCandidate(out: string[], seen: Set<string>, raw: unknown) {
  if (raw == null) return
  if (typeof raw === 'string') {
    const v = raw.trim()
    if (!isSafeRemoteImageUrl(v)) return
    const key = v.toLowerCase()
    if (!seen.has(key)) {
      seen.add(key)
      out.push(v)
    }
    return
  }
  if (Array.isArray(raw)) {
    raw.forEach((e) => addImageCandidate(out, seen, e))
    return
  }
  if (typeof raw === 'object') {
    for (const k of ['url', 'imageUrl', 'photoUrl', 'src']) addImageCandidate(out, seen, (raw as StopMap)[k])
  }
}

export function stopImageUrls(stop: StopMap, title: string, placePhotos: string[]): string[] {
  const out: string[] = []
  const seen = new Set<string>()
  placePhotos.forEach((u) => addImageCandidate(out, seen, u))
  for (const k of ['imageUrl', 'photoUrl', 'coverImage', 'thumbnailUrl', 'heroImage']) addImageCandidate(out, seen, stop[k])
  for (const k of ['photos', 'images', 'photoUrls', 'imageUrls', 'gallery', 'galleryImages', 'pictures']) addImageCandidate(out, seen, stop[k])

  if (Array.isArray(stop.itinerary)) {
    for (const day of stop.itinerary) {
      if (!day || typeof day !== 'object') continue
      addImageCandidate(out, seen, day.imageUrl)
      addImageCandidate(out, seen, day.photoUrl)
      if (!Array.isArray(day.activities)) continue
      for (const a of day.activities) {
        if (!a || typeof a !== 'object') continue
        addImageCandidate(out, seen, a.imageUrl)
        addImageCandidate(out, seen, a.photoUrl)
        addImageCandidate(out, seen, a.images)
      }
    }
  }

  const base = title || 'travel-town'
  for (const seed of [base, `${base}-overlook`, `${base}-travel`, `${base}-city`, `${base}-night`, `${base}-food`, `${base}-viewpoint`]) {
    if (out.length >= 6) break
    addImageCandidate(out, seen, realisticFallbackPhotoUrl(seed, out.length))
  }
  return out.slice(0, 6)
}

export function formatDateForAi(raw: unknown, fallback: string): string {
  if (raw && typeof (raw as any).toDate === 'function') return (raw as any).toDate().toISOString().slice(0, 10)
  if (raw instanceof Date) return raw.toISOString().slice(0, 10)
  const s = raw == null ? '' : String(raw).trim()
  if (!s) return fallback
  const d = new Date(s)
  if (!Number.isNaN(d.getTime())) return d.toISOString().slice(0, 10)
  return s.length >= 10 ? s.slice(0, 10) : fallback
}
