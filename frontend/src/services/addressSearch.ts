export interface AddressSuggestion {
  displayName: string
  lat: number
  lon: number
}

/** Lightweight address search using OpenStreetMap Nominatim (no key; rate limited). */
export async function searchAddress(query: string): Promise<AddressSuggestion[]> {
  if (!query.trim()) return []
  const url = new URL('https://nominatim.openstreetmap.org/search')
  url.search = new URLSearchParams({ q: query, format: 'json', addressdetails: '0', limit: '8' }).toString()
  try {
    const resp = await fetch(url)
    if (!resp.ok) return []
    const data = (await resp.json()) as any[]
    return data.map((item) => ({
      displayName: String(item.display_name ?? 'Unknown'),
      lat: parseFloat(item.lat) || 0,
      lon: parseFloat(item.lon) || 0,
    }))
  } catch {
    return []
  }
}
