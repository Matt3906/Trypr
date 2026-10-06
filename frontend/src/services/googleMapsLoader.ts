import { config } from '@/config'

let loadPromise: Promise<void> | null = null

export const hasMapsKey = () => config.googleMapsApiKey.length > 0

const isMapsLoaded = () => typeof window !== 'undefined' && !!(window as any).google?.maps?.importLibrary || (typeof window !== 'undefined' && !!(window as any).google?.maps?.Map)

/**
 * Dynamically loads the Google Maps JavaScript SDK (once). Resolves even when no
 * key is configured or loading fails, so callers can show a "not configured" state
 * by checking `isMapsLoaded()`/`hasMapsKey()`.
 */
export function ensureGoogleMapsLoaded(): Promise<void> {
  if (loadPromise) return loadPromise
  if (isMapsLoaded() && (window as any).google.maps.Map) return Promise.resolve()
  if (loadPromise) return loadPromise
  if (!hasMapsKey()) return Promise.resolve()

  loadPromise = new Promise<void>((resolve) => {
    const finish = () => resolve()
    // With loading=async the classic classes (Map, Marker, ...) only exist after importLibrary().
    const importLibs = async () => {
      try {
        const maps: any = (window as any).google.maps
        await Promise.all(['core', 'maps', 'marker', 'places', 'routes', 'geometry'].map((l) => maps.importLibrary(l)))
      } catch (e) {
        console.warn('Google Maps library import failed', e)
      }
      finish()
    }
    const poll = (attempt = 0) => {
      if (isMapsLoaded()) return void importLibs()
      if (attempt > 50) {
        loadPromise = null
        return finish()
      }
      setTimeout(() => poll(attempt + 1), 100)
    }

    const existing = document.querySelector('script[src*="maps.googleapis.com"]')
    if (existing) {
      poll()
      return
    }

    const script = document.createElement('script')
    script.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(
      config.googleMapsApiKey,
    )}&libraries=places,routes,geometry&loading=async&v=weekly`
    script.async = true
    script.onload = () => poll()
    script.onerror = () => {
      loadPromise = null // allow a retry on the next call
      finish()
    }
    document.head.appendChild(script)
  })
  return loadPromise
}

export const mapsReady = () => typeof window !== 'undefined' && !!(window as any).google?.maps?.Map
