import { config } from '@/config'
import { ensureGoogleMapsLoaded, hasMapsKey } from './googleMapsLoader'

export interface PlaceResult {
  name: string
  display_name: string
  lat: number
  lon: number
}

const MAX_RESULTS = 8

const timeout = <T,>(p: Promise<T>, ms: number, fallback: T): Promise<T> =>
  Promise.race([p, new Promise<T>((r) => setTimeout(() => r(fallback), ms))])

function item(query: string, displayName: string, formattedAddress: string, lat?: number, lon?: number): PlaceResult | null {
  if (lat == null || lon == null || Number.isNaN(lat) || Number.isNaN(lon)) return null
  const display = formattedAddress.trim() || displayName.trim() || query
  return { name: displayName.trim() || display, display_name: display, lat, lon }
}

let geocoder: google.maps.Geocoder | null = null

async function ensureServices(): Promise<boolean> {
  if (!hasMapsKey()) return false
  await ensureGoogleMapsLoaded()
  const maps = (window as any).google?.maps
  if (!maps) return false
  try {
    await maps.importLibrary?.('places')
  } catch {
    /* non-fatal */
  }
  if (!geocoder) geocoder = new google.maps.Geocoder()
  return true
}

async function searchViaGeocoder(query: string): Promise<PlaceResult[]> {
  if (!geocoder) return []
  try {
    const res = await timeout(geocoder.geocode({ address: query }), 8000, null)
    if (!res) return []
    const out: PlaceResult[] = []
    for (const r of res.results) {
      const loc = r.geometry?.location
      const it = item(query, r.formatted_address, r.formatted_address, loc?.lat(), loc?.lng())
      if (it) out.push(it)
      if (out.length >= MAX_RESULTS) break
    }
    return out
  } catch {
    return []
  }
}

async function searchAutocompleteNew(query: string): Promise<PlaceResult[]> {
  try {
    const lib: any = await (google.maps as any).importLibrary('places')
    const Suggestion = lib?.AutocompleteSuggestion
    if (!Suggestion) return []
    const { suggestions } = await Suggestion.fetchAutocompleteSuggestions({ input: query, language: 'en' })
    if (!suggestions?.length) return []

    const out: PlaceResult[] = []
    for (const s of suggestions) {
      const prediction = s.placePrediction
      if (!prediction) continue
      const predictionText = String(prediction.text?.text ?? prediction.text ?? '').trim()
      let place: any
      try {
        place = prediction.toPlace()
      } catch {
        continue
      }
      try {
        await place.fetchFields({ fields: ['displayName', 'formattedAddress', 'location'] })
      } catch {
        /* read any preloaded fields */
      }
      const displayName = String(place.displayName ?? '').trim()
      const formatted = String(place.formattedAddress ?? '').trim()
      const loc = place.location
      const it = item(query, displayName || predictionText || query, formatted, loc?.lat?.(), loc?.lng?.())
      if (it) out.push(it)
      else {
        const text = formatted || displayName || predictionText || query
        const resolved = await searchViaGeocoder(text)
        if (resolved.length) out.push({ ...resolved[0], name: displayName || text, display_name: text })
      }
      if (out.length >= MAX_RESULTS) break
    }
    return out
  } catch {
    return []
  }
}

async function searchPlacesNew(query: string): Promise<PlaceResult[]> {
  try {
    const lib: any = await (google.maps as any).importLibrary('places')
    const { places } = await lib.Place.searchByText({
      textQuery: query,
      fields: ['displayName', 'formattedAddress', 'location'],
      maxResultCount: MAX_RESULTS,
      language: 'en',
    })
    const out: PlaceResult[] = []
    for (const p of places ?? []) {
      const it = item(query, String(p.displayName ?? ''), String(p.formattedAddress ?? ''), p.location?.lat?.(), p.location?.lng?.())
      if (it) out.push(it)
      if (out.length >= MAX_RESULTS) break
    }
    return out
  } catch {
    return []
  }
}

async function searchNominatimFallback(query: string): Promise<PlaceResult[]> {
  try {
    const url = new URL('https://nominatim.openstreetmap.org/search')
    url.search = new URLSearchParams({ q: query, format: 'json', limit: String(MAX_RESULTS) }).toString()
    const resp = await fetch(url)
    if (!resp.ok) return []
    const data = (await resp.json()) as any[]
    return data.map((e) => {
      const display = String(e.display_name ?? '')
      return { name: display, display_name: display, lat: parseFloat(e.lat) || 0, lon: parseFloat(e.lon) || 0 }
    })
  } catch {
    return []
  }
}

async function searchPhotonFallback(query: string): Promise<PlaceResult[]> {
  try {
    const url = new URL('https://photon.komoot.io/api/')
    url.search = new URLSearchParams({ q: query, limit: String(MAX_RESULTS), lang: 'en' }).toString()
    const resp = await fetch(url)
    if (!resp.ok) return []
    const data = await resp.json()
    const out: PlaceResult[] = []
    for (const f of data?.features ?? []) {
      const props = f.properties ?? {}
      const coords = f.geometry?.coordinates
      if (!Array.isArray(coords) || coords.length < 2) continue
      const name = String(props.name ?? props.street ?? '').trim()
      const city = String(props.city ?? props.state ?? '').trim()
      const country = String(props.country ?? '').trim()
      const display = [name, city, country].filter(Boolean).join(', ')
      if (!display) continue
      out.push({ name: name || display, display_name: display, lat: coords[1], lon: coords[0] })
      if (out.length >= MAX_RESULTS) break
    }
    return out
  } catch {
    return []
  }
}

/** Location search. Google Places/Geocoder when a Maps key exists, else Nominatim/Photon. */
export async function searchPlaces(query: string): Promise<PlaceResult[]> {
  const q = query.trim()
  if (!q) return []

  if (!hasMapsKey()) {
    const n = await searchNominatimFallback(q)
    return n.length ? n : searchPhotonFallback(q)
  }

  try {
    const ready = await timeout(ensureServices(), 1000, false)
    if (!ready) return searchPhotonFallback(q)
    const a = await searchAutocompleteNew(q)
    if (a.length) return a
    const p = await searchPlacesNew(q)
    if (p.length) return p
    const g = await searchViaGeocoder(q)
    if (g.length) return g
    return searchPhotonFallback(q)
  } catch {
    return searchPhotonFallback(q)
  }
}

// Kept under the legacy name for easier cross-referencing with the Dart code.
export const searchNominatim = searchPlaces

async function reverseNominatimFallback(lat: number, lon: number): Promise<string | null> {
  try {
    const url = new URL('https://nominatim.openstreetmap.org/reverse')
    url.search = new URLSearchParams({
      format: 'json', lat: String(lat), lon: String(lon), zoom: '14', addressdetails: '0',
    }).toString()
    const resp = await fetch(url)
    if (!resp.ok) return null
    return ((await resp.json()).display_name as string) ?? null
  } catch {
    return null
  }
}

export async function reverseGeocode(lat: number, lon: number): Promise<string | null> {
  if (!hasMapsKey()) return reverseNominatimFallback(lat, lon)
  try {
    const ready = await timeout(ensureServices(), 1000, false)
    if (!ready || !geocoder) return null
    const res = await timeout(geocoder.geocode({ location: { lat, lng: lon } }), 8000, null)
    const formatted = res?.results?.[0]?.formatted_address
    return formatted || null
  } catch {
    return null
  }
}
export const reverseNominatim = reverseGeocode

function looksBroadArea(value: string): boolean {
  const s = value.trim().toLowerCase()
  if (!s) return true
  if (s === 'canada' || s === 'united states' || s === 'usa') return true
  return ['county', 'region', 'district', 'province', 'state', 'territory'].some((w) => s.includes(w))
}

export async function reverseLocality(lat: number, lon: number): Promise<string | null> {
  try {
    const url = new URL('https://nominatim.openstreetmap.org/reverse')
    url.search = new URLSearchParams({
      format: 'json', lat: String(lat), lon: String(lon), zoom: '14', addressdetails: '1',
    }).toString()
    const resp = await fetch(url)
    if (!resp.ok) return null
    const address = (await resp.json())?.address
    if (!address || typeof address !== 'object') return null
    for (const key of ['city', 'town', 'village', 'municipality', 'city_district', 'borough', 'suburb', 'hamlet']) {
      const raw = String(address[key] ?? '').trim()
      if (!raw || looksBroadArea(raw)) continue
      return raw
    }
    return null
  } catch {
    return null
  }
}

/** Geocoding REST fallback (used when the JS SDK is unavailable but a key is set). */
export async function searchViaGeocodingRest(query: string): Promise<PlaceResult[]> {
  if (!config.googleMapsApiKey) return []
  try {
    const url = new URL('https://maps.googleapis.com/maps/api/geocode/json')
    url.search = new URLSearchParams({ address: query, key: config.googleMapsApiKey }).toString()
    const resp = await fetch(url)
    if (!resp.ok) return []
    const data = await resp.json()
    if (String(data.status).toUpperCase() !== 'OK') return []
    const out: PlaceResult[] = []
    for (const r of data.results ?? []) {
      const loc = r.geometry?.location
      if (loc?.lat == null || loc?.lng == null) continue
      const formatted = String(r.formatted_address ?? '').trim() || query
      out.push({ name: formatted, display_name: formatted, lat: loc.lat, lon: loc.lng })
      if (out.length >= MAX_RESULTS) break
    }
    return out
  } catch {
    return []
  }
}
