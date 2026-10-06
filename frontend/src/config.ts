/** Build-time configuration (Vite env vars). Mirrors the old --dart-define flags. */
const env = import.meta.env

const str = (v: unknown): string => (typeof v === 'string' ? v.trim() : '')

export const config = {
  googleMapsApiKey: str(env.VITE_GOOGLE_MAPS_API_KEY),
  googleMapsMapId: str(env.VITE_GOOGLE_MAPS_MAP_ID),
  recaptchaSiteKey: str(env.VITE_RECAPTCHA_SITE_KEY),
  openRouteServiceApiKey: str(env.VITE_OPENROUTESERVICE_API_KEY),
  graphHopperApiKey: str(env.VITE_GRAPHHOPPER_API_KEY),
  strictRouting: str(env.VITE_STRICT_ROUTING).toLowerCase() === 'true',
  routingProxyUrl: str(env.VITE_ROUTING_PROXY_URL),
  overpassProxyUrl: str(env.VITE_OVERPASS_PROXY_URL),
  campsiteInfoMarkerId: str(env.VITE_CAMPSITE_INFO_MARKER_ID),
  functionsRegion: str(env.VITE_FIREBASE_FUNCTIONS_REGION) || 'us-central1',
  useFirebaseEmulators: str(env.VITE_USE_FIREBASE_EMULATORS) === 'true',
}

export const firebaseOptions = {
  apiKey: 'AIzaSyCV43kvtfDcmmikbLqC5TXEHJAnupZt-lA',
  authDomain: 'trypr-5ee47.firebaseapp.com',
  projectId: 'trypr-5ee47',
  storageBucket: 'trypr-5ee47.firebasestorage.app',
  messagingSenderId: '39789168828',
  appId: '1:39789168828:web:35dc72dce890271c9e68b9',
  measurementId: 'G-1KRHR1T6D2',
}
