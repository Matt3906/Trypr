/** Build-time configuration (Vite env vars). Mirrors the old --dart-define flags. */
const env = import.meta.env

const str = (v: unknown): string => (typeof v === 'string' ? v.trim() : '')

export const config = {
  googleMapsApiKey: str(env.VITE_GOOGLE_MAPS_API_KEY),
  googleMapsMapId: str(env.VITE_GOOGLE_MAPS_MAP_ID),
  openRouteServiceApiKey: str(env.VITE_OPENROUTESERVICE_API_KEY),
  graphHopperApiKey: str(env.VITE_GRAPHHOPPER_API_KEY),
  strictRouting: str(env.VITE_STRICT_ROUTING).toLowerCase() === 'true',
  routingProxyUrl: str(env.VITE_ROUTING_PROXY_URL),
  overpassProxyUrl: str(env.VITE_OVERPASS_PROXY_URL),
  campsiteInfoMarkerId: str(env.VITE_CAMPSITE_INFO_MARKER_ID),
  /** Backend origin, e.g. https://api.tryprtravel.com. Empty = same origin (Vite proxies /api in dev). */
  apiBaseUrl: str(env.VITE_API_BASE_URL).replace(/\/+$/, ''),
}
