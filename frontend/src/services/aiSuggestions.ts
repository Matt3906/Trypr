import { httpsCallable } from 'firebase/functions'
import { functions } from '@/firebase'
import { canAccessPremium } from './premiumAccess'

export class PremiumRequiredError extends Error {}

export type Suggestion = Record<string, any>

export interface SuggestArgs {
  destinationName: string
  lat: number
  lon: number
  startDate: string
  endDate: string
  preferences?: Record<string, any>
}

export const suggestAccommodations = (a: SuggestArgs) => call('accommodations', a)
export const suggestItinerary = (a: SuggestArgs) => call('itinerary', a)

async function call(module: string, a: SuggestArgs): Promise<Suggestion[]> {
  try {
    const payload: Record<string, any> = {
      module,
      destinationName: a.destinationName,
      lat: a.lat,
      lon: a.lon,
      startDate: a.startDate,
      endDate: a.endDate,
    }
    if (a.preferences && Object.keys(a.preferences).length) payload.preferences = a.preferences

    const result = await Promise.race([
      httpsCallable<Record<string, any>, { suggestions?: Suggestion[] }>(functions, 'aiSuggest')(payload),
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error('timeout')), 18000)),
    ])
    return result.data?.suggestions ?? []
  } catch (e: any) {
    const code = String(e?.code ?? '').replace('functions/', '')
    const message = String(e?.message ?? '')
    if (code === 'permission-denied' && message.includes('PREMIUM_REQUIRED')) {
      if (await canAccessPremium()) return localFallback(module, a.destinationName, a.preferences)
      throw new PremiumRequiredError('Unlock AI Suggestions with Trypr Premium. Save time planning your trip.')
    }
    if (code === 'failed-precondition') {
      if (message.includes('Trip dates required') || message.includes('Waypoint coordinates required')) {
        throw new Error(message)
      }
      return localFallback(module, a.destinationName, a.preferences)
    }
    return localFallback(module, a.destinationName, a.preferences)
  }
}

function fallbackCategory(type: string): string {
  switch (type.toLowerCase()) {
    case 'adventure':
      return 'Adventure'
    case 'fooddrink':
    case 'food_drink':
    case 'food':
      return 'Restaurant'
    case 'culturemuseum':
    case 'culture':
    case 'museum':
      return 'Museum'
    case 'relaxation':
      return 'Free Time'
    case 'sightseeing':
    case 'attractions':
      return 'Sightseeing'
    default:
      return 'Exploring'
  }
}

function localFallback(module: string, destinationName: string, prefs?: Record<string, any>): Suggestion[] {
  let seed = 0
  for (let i = 0; i < destinationName.length; i++) seed = (seed + destinationName.charCodeAt(i)) % 100000
  const budgetTier = String(prefs?.budgetTier ?? 'moderate').toLowerCase()
  const type = String(prefs?.activityType ?? 'exploring')
  const multiplier = budgetTier === 'budget' ? 0.75 : budgetTier === 'luxury' ? 1.5 : 1.0
  const ratingFor = (i: number) => Math.min(4.9, Math.max(3.8, 3.8 + ((seed + i * 17) % 12) / 10))

  if (module === 'accommodations') {
    const stayType = String(prefs?.stayType ?? 'hotel').trim().toLowerCase()
    let names: string[]
    let basePrices: number[]
    switch (stayType) {
      case 'camping':
        names = [`${destinationName} Campground`, `${destinationName} RV & Tent Site`, `${destinationName} Nature Campsite`]
        basePrices = [45, 60, 75]
        break
      case 'hostel':
        names = [`${destinationName} Central Hostel`, `${destinationName} Backpacker House`, `${destinationName} Social Hostel`]
        basePrices = [50, 72, 95]
        break
      default:
        names = [`${destinationName} Central Hotel`, `${destinationName} Riverside Suites`, `${destinationName} Boutique Stay`]
        basePrices = [120, 165, 210]
    }
    return names.map((name, i) => ({
      name,
      address: `${i + 1} Main St, ${destinationName}`,
      price: Math.round(basePrices[i] * multiplier),
      rating: ratingFor(i),
      stayType,
      source: 'local_fallback',
    }))
  }

  const category = fallbackCategory(type)
  const activityNames = [
    'City highlights walk', 'Scenic viewpoint stop', 'Local food experience', 'Historic district exploration',
    'Cultural center visit', 'Neighborhood market stroll', 'Sunset photo session', 'Signature local attraction',
  ]
  const basePrices = [0, 12, 28, 15, 20, 10, 0, 25]
  return activityNames.map((n, i) => ({
    name: `${destinationName} ${n}`,
    address: `${10 + i} Center Ave, ${destinationName}`,
    estimatedPrice: Math.round(basePrices[i] * multiplier),
    rating: ratingFor(i),
    category,
    source: 'local_fallback',
  }))
}
