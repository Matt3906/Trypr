import { apiFetch } from '@/backend/api'

export interface StayOffer {
  provider: string
  providerLabel: string
  totalCents: number
  perNightCents: number
  currency: string
  taxesIncluded: boolean | null
  freeCancellation: boolean | null
  breakfast: boolean | null
  /** false = cached "from" price the partner re-checks after the click. */
  live: boolean
  /** Same-origin path on our API; opening it logs the click and redirects to the partner. */
  url: string
}

export interface StayHotel {
  id: string
  name: string
  lat: number
  lon: number
  stars: number | null
  address: string | null
  image: string | null
  distanceKm: number
  best: StayOffer
  /** Cheapest first, one per provider. */
  offers: StayOffer[]
  savingsCents: number
  savingsPct: number
  sample: boolean
}

export interface StayProviderStatus {
  id: string
  label: string
  status: 'ok' | 'error' | 'pending'
  count: number
}

export interface StaySearchResult {
  configured: boolean
  /** Some providers are still answering; ask again shortly and they will be in the cache. */
  pending: boolean
  providers: StayProviderStatus[]
  hotels: StayHotel[]
  nights: number
  currency: string
  /** True when any hotel is demo data (dev only). */
  sample: boolean
  /** Affiliate-tagged results page for these dates (via our click-out), present whenever a marker is configured. */
  searchLink?: { label: string; url: string } | null
}

export interface StaySearchArgs {
  lat: number
  lon: number
  checkIn: string
  checkOut: string
  adults: number
  currency: string
  name?: string
  radiusKm?: number
}

export function searchStays(a: StaySearchArgs, signal?: AbortSignal): Promise<StaySearchResult> {
  const p = new URLSearchParams({
    lat: String(a.lat), lon: String(a.lon), check_in: a.checkIn, check_out: a.checkOut,
    adults: String(a.adults), currency: a.currency,
  })
  if (a.name) p.set('name', a.name)
  if (a.radiusKm) p.set('radius_km', String(a.radiusKm))
  return apiFetch<StaySearchResult>(`/api/stays/search?${p}`, { signal })
}

export function formatMoney(cents: number, currency: string): string {
  try {
    return new Intl.NumberFormat(undefined, { style: 'currency', currency, maximumFractionDigits: cents % 100 === 0 ? 0 : 2 }).format(cents / 100)
  } catch {
    return `${currency} ${(cents / 100).toFixed(0)}`
  }
}
