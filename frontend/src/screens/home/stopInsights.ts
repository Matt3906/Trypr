import { useCallback, useEffect, useRef, useState } from 'react'
import { PremiumRequiredError, suggestItinerary } from '@/services/aiSuggestions'
import { canAccessPremium } from '@/services/premiumAccess'
import { ensureGoogleMapsLoaded } from '@/services/googleMapsLoader'
import { reverseLocality, reverseNominatim } from '@/services/geocode'
import {
  activityRecommendationsFromSuggestions, cityFromStopFields, extractCityFromAddress, fallbackActivitiesForTown,
  fallbackActivityRecommendations, focusedStopTownSeed, formatDateForAi, isBackcountryStop, isSafeRemoteImageUrl,
  looksPoiLabel, looksRegionLabel, poiSummaryFromSuggestions, topCategoriesFromSuggestions, trimAddressNoise,
  type ActivityRecommendation, type StopMap,
} from '@/lib/tripInsights'
import { withTimeout } from '@/lib/async'

export interface PoiInsight {
  displayName: string
  cityName: string
  summary: string
  categories: string[]
  activityRecommendations: ActivityRecommendation[]
}

export const focusedStopKey = (stop: StopMap) => {
  const lat = typeof stop.lat === 'number' ? stop.lat : 0
  const lon = typeof stop.lon === 'number' ? stop.lon : 0
  const name = String(stop.name ?? stop.title ?? '').trim()
  return `${lat.toFixed(6)}|${lon.toFixed(6)}|${name.toLowerCase()}`
}

function photoSearchQuery(stop: StopMap, title: string, stopNumber: number, trip: StopMap | null): string {
  const parts: string[] = []
  const add = (raw: unknown) => {
    const v = raw == null ? '' : String(raw).trim()
    if (v && !parts.includes(v)) parts.push(v)
  }
  add(title)
  add(stop.formattedAddress)
  add(stop.formatted_address)
  add(stop.address)
  add(trip?.region)
  add(trip?.destination)
  const q = parts.slice(0, 3).join(' ').trim()
  return q || focusedStopTownSeed(stop, stopNumber)
}

/** Caches + loaders backing the globe's focused-stop card. */
export function useStopInsights(selectedTrip: StopMap | null) {
  const [insights, setInsights] = useState<Record<string, PoiInsight>>({})
  const [loading, setLoading] = useState<Set<string>>(new Set())
  const [photos, setPhotos] = useState<Record<string, string[]>>({})
  const [attribution, setAttribution] = useState<Record<string, string>>({})
  const [premium, setPremium] = useState<boolean | null>(null)

  const cityCache = useRef<Record<string, string>>({})
  const insightsRef = useRef(insights)
  insightsRef.current = insights
  const photosRef = useRef(photos)
  photosRef.current = photos
  const loadingRef = useRef<Set<string>>(new Set())
  const photoLoadingRef = useRef<Set<string>>(new Set())
  const premiumPromise = useRef<Promise<boolean> | null>(null)
  const tripRef = useRef(selectedTrip)
  tripRef.current = selectedTrip

  const premiumEnabled = useCallback((): Promise<boolean> => {
    if (premium != null) return Promise.resolve(premium)
    if (!premiumPromise.current) {
      premiumPromise.current = canAccessPremium()
        .then((v) => {
          setPremium(v)
          return v
        })
        .catch(() => {
          setPremium(false)
          return false
        })
        .finally(() => {
          premiumPromise.current = null
        })
    }
    return premiumPromise.current
  }, [premium])

  useEffect(() => {
    void premiumEnabled()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const setLoadingFlag = (key: string, on: boolean) => {
    if (on) loadingRef.current.add(key)
    else loadingRef.current.delete(key)
    setLoading(new Set(loadingRef.current))
  }

  const citySeed = async (stop: StopMap, stopNumber: number): Promise<string> => {
    const key = focusedStopKey(stop)
    const cached = (cityCache.current[key] ?? '').trim()
    if (cached) return cached
    const fromFields = cityFromStopFields(stop)
    if (fromFields) return (cityCache.current[key] = fromFields)

    const { lat, lon } = stop
    if (Number.isFinite(lat) && Number.isFinite(lon)) {
      try {
        const addr = await withTimeout({ operation: () => reverseNominatim(lat, lon), timeoutMs: 6000, fallback: () => null })
        const fromReverse = extractCityFromAddress(addr ?? '')
        if (fromReverse) return (cityCache.current[key] = fromReverse)
      } catch { /* ignore */ }
      try {
        const loc = await withTimeout({ operation: () => reverseLocality(lat, lon), timeoutMs: 5000, fallback: () => null })
        const cleaned = trimAddressNoise(loc ?? '')
        if (cleaned && !looksRegionLabel(cleaned) && !looksPoiLabel(cleaned)) return (cityCache.current[key] = cleaned)
      } catch { /* ignore */ }
    }
    const fb = focusedStopTownSeed(stop, stopNumber)
    if (!looksRegionLabel(fb) && !looksPoiLabel(fb)) return (cityCache.current[key] = fb)
    return (cityCache.current[key] = 'Nearby City')
  }

  const localFallbackInsight = (seed: string, includePlanning = true): PoiInsight => {
    const categories = fallbackActivitiesForTown(seed)
    return {
      displayName: seed,
      cityName: seed,
      summary: includePlanning ? `${seed} is a strong stop for ${categories.slice(0, 3).join(', ').toLowerCase()}.` : seed,
      categories: includePlanning ? categories : [],
      activityRecommendations: includePlanning ? fallbackActivityRecommendations(seed, categories) : [],
    }
  }

  const ensurePoiInsight = useCallback(async (stop: StopMap, stopIndex: number) => {
    const key = focusedStopKey(stop)
    const existing = insightsRef.current[key]
    if (existing) {
      const label = (existing.cityName || existing.displayName || '').trim()
      if (label && !looksRegionLabel(label)) return
    }
    if (loadingRef.current.has(key)) return
    const { lat, lon } = stop
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) return

    setLoadingFlag(key, true)
    const quickSeed = focusedStopTownSeed(stop, stopIndex + 1)
    if (!insightsRef.current[key]) setInsights((p) => ({ ...p, [key]: localFallbackInsight(quickSeed) }))

    try {
      const seed = await citySeed(stop, stopIndex + 1)
      const enabled = await premiumEnabled()
      const allowAi = enabled && !isBackcountryStop(stop, tripRef.current)
      if (!allowAi) {
        setInsights((p) => ({ ...p, [key]: localFallbackInsight(focusedStopTownSeed(stop, stopIndex + 1), false) }))
        return
      }

      const now = new Date()
      const fmt = (d: Date) => d.toISOString().slice(0, 10)
      const sel = tripRef.current
      const startDate = formatDateForAi(sel?.startDate, fmt(now))
      const endDate = formatDateForAi(sel?.endDate, fmt(new Date(now.getTime() + 2 * 86400000)))
      try {
        const suggestions = await withTimeout({
          operation: () =>
            suggestItinerary({
              destinationName: seed, lat, lon, startDate, endDate,
              preferences: { activityType: 'sightseeing', maxTravelMinutes: 30, scope: 'nearby' },
            }),
          timeoutMs: 16000,
          fallback: () => { throw new Error('timeout') },
        })
        const categories = topCategoriesFromSuggestions(suggestions)
        const displayName = trimAddressNoise(seed) || seed
        const recs = activityRecommendationsFromSuggestions(suggestions)
        setInsights((p) => ({
          ...p,
          [key]: {
            displayName,
            cityName: displayName,
            summary: poiSummaryFromSuggestions(displayName, categories, suggestions),
            categories,
            activityRecommendations: recs.length ? recs : fallbackActivityRecommendations(displayName, categories),
          },
        }))
      } catch (e) {
        if (!(e instanceof PremiumRequiredError)) console.debug('poi insight failed', e)
        setInsights((p) => ({ ...p, [key]: localFallbackInsight(seed) }))
      }
    } finally {
      setLoadingFlag(key, false)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [premiumEnabled])

  const ensurePhotos = useCallback(async (stop: StopMap, stopIndex: number, title: string) => {
    const key = focusedStopKey(stop)
    if (photosRef.current[key] || photoLoadingRef.current.has(key)) return
    photoLoadingRef.current.add(key)
    try {
      await Promise.race([ensureGoogleMapsLoaded(), new Promise((r) => setTimeout(r, 8000))])
      const maps = (window as any).google?.maps
      if (!maps) return
      const lib = await maps.importLibrary('places')
      const request: Record<string, any> = {
        textQuery: photoSearchQuery(stop, title, stopIndex + 1, tripRef.current),
        fields: ['displayName', 'photos'],
        maxResultCount: 4,
        language: 'en',
      }
      if (Number.isFinite(stop.lat) && Number.isFinite(stop.lon)) request.locationBias = { lat: stop.lat, lng: stop.lon }
      const { places } = await lib.Place.searchByText(request)

      const out: string[] = []
      const seen = new Set<string>()
      const attrs: Record<string, string> = {}
      for (const place of places ?? []) {
        for (const photo of place.photos ?? []) {
          let url = ''
          for (const m of ['getURI', 'getUrl']) {
            try {
              const v = String(photo[m]?.({ maxWidth: 900, maxHeight: 520 }) ?? '').trim()
              if (isSafeRemoteImageUrl(v)) { url = v; break }
            } catch { /* try next */ }
          }
          if (!url || seen.has(url.toLowerCase())) continue
          seen.add(url.toLowerCase())
          out.push(url)
          const names: string[] = []
          for (const a of photo.authorAttributions ?? []) {
            const n = String(a.displayName ?? '').trim()
            if (n && !names.includes(n)) names.push(n)
            if (names.length >= 2) break
          }
          if (names.length) attrs[url] = names.join(', ')
          if (out.length >= 6) break
        }
        if (out.length >= 6) break
      }
      setAttribution((p) => ({ ...p, ...attrs }))
      setPhotos((p) => ({ ...p, [key]: out }))
    } catch {
      setPhotos((p) => ({ ...p, [key]: [] }))
    } finally {
      photoLoadingRef.current.delete(key)
    }
  }, [])

  return { insights, loading, photos, attribution, premium, ensurePoiInsight, ensurePhotos }
}
