import { apiFetch, apiUrl } from '@/backend/api'

export interface Partner {
  id: string
  label: string
  category: string
  categoryTitle: string
  blurb: string
  preferRegions: string[]
  onlyRegions: string[]
}

let cached: Promise<Partner[]> | null = null

/** The partner list changes rarely; fetch it once per page load. A failure is not cached, so a later call retries. */
export function loadPartners(): Promise<Partner[]> {
  if (!cached) {
    cached = apiFetch<{ partners: Partner[] }>('/api/partners').then((r) => r.partners).catch((e) => {
      cached = null
      throw e
    })
  }
  return cached
}

/** Logged redirect to the partner's affiliate link. `placement` records where in the app the click happened. */
export const partnerUrl = (id: string, placement: string) => apiUrl(`/api/go/${encodeURIComponent(id)}?from=${encodeURIComponent(placement)}`)
