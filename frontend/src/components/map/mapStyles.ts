export type MapStyle = google.maps.MapTypeStyle[]

const roadsOnly: MapStyle = [
  { featureType: 'poi', stylers: [{ visibility: 'off' }] },
  { featureType: 'transit', stylers: [{ visibility: 'off' }] },
  { featureType: 'administrative', elementType: 'labels', stylers: [{ visibility: 'off' }] },
]
const bike: MapStyle = [
  { featureType: 'poi', stylers: [{ visibility: 'off' }] },
  { featureType: 'transit', stylers: [{ visibility: 'off' }] },
  { featureType: 'road.highway', stylers: [{ saturation: -80 }] },
  { featureType: 'road.arterial', stylers: [{ hue: '#2e7d32' }, { saturation: 20 }] },
]
const walk: MapStyle = [
  { featureType: 'poi', stylers: [{ visibility: 'off' }] },
  { featureType: 'transit', stylers: [{ visibility: 'off' }] },
  { featureType: 'road.highway', stylers: [{ visibility: 'off' }] },
  { featureType: 'road.local', stylers: [{ hue: '#00897b' }, { saturation: 10 }] },
]
const hiking: MapStyle = [
  { featureType: 'poi', stylers: [{ visibility: 'off' }] },
  { featureType: 'transit', stylers: [{ visibility: 'off' }] },
  { featureType: 'road.highway', stylers: [{ saturation: -70 }, { lightness: -15 }] },
  { featureType: 'road.arterial', stylers: [{ saturation: -55 }, { lightness: -10 }] },
]
const portaging: MapStyle = [
  ...hiking,
  { featureType: 'water', stylers: [{ saturation: 30 }, { lightness: -10 }] },
]
const plane: MapStyle = [
  { featureType: 'road', stylers: [{ visibility: 'off' }] },
  { featureType: 'poi', stylers: [{ visibility: 'off' }] },
  { featureType: 'transit', stylers: [{ visibility: 'off' }] },
]

export function mapStyleForMode(mode: string): MapStyle {
  switch (mode) {
    case 'bike': return bike
    case 'walk': return walk
    case 'hiking': return hiking
    case 'portaging': return portaging
    case 'plane': return plane
    default: return roadsOnly
  }
}

export const PORTAGE_CARRY_COLOR = '#8d6e63'

/** Normalizes the many transport-mode spellings used across trips (car/plane/train/walk/bike/...). */
export function normalizeMapMode(raw: string): string {
  let mode = raw.trim().toLowerCase()
  if (mode === 'driving') mode = 'car'
  if (mode === 'flying' || mode === 'flight') mode = 'plane'
  if (['rail', 'public_transit', 'public transit', 'transit'].includes(mode)) mode = 'train'
  if (mode === 'walking') mode = 'walk'
  if (['biking', 'bicycling', 'bikepacking'].includes(mode)) mode = 'bike'
  if (['canoe', 'canoeing', 'portage'].includes(mode)) mode = 'portaging'
  if (mode === 'backpacking') mode = 'hiking'
  if (['gas/stops', 'gas-stops', 'gasstops'].includes(mode)) mode = 'gas_stops'
  switch (mode) {
    case 'car': case 'plane': case 'train': case 'walk': case 'bike': case 'portaging': case 'hiking': case 'gas_stops':
      return mode
    default:
      return 'car'
  }
}

export function standardRouteColor(mode: string): string {
  switch (normalizeMapMode(mode)) {
    case 'plane': return '#3949ab'
    case 'train': return '#546e7a'
    case 'walk': return '#00897b'
    case 'bike': return '#1565c0'
    case 'hiking': return '#8e24aa'
    case 'portaging': return '#d81b60'
    case 'gas_stops': return '#ef6c00'
    default: return '#1e88e5'
  }
}

export function categoryColor(kindRaw: string, categoryRaw: string): string {
  const kind = kindRaw.trim().toLowerCase()
  const category = categoryRaw.trim().toLowerCase()
  if (kind === 'accommodation') return '#8e24aa'
  switch (category) {
    case 'car': case 'driving': return '#448aff'
    case 'train': case 'transit': return '#546e7a'
    case 'plane': case 'flight': return '#3949ab'
    case 'gas_stops': case 'gas': return '#ef6c00'
    case 'bike': case 'biking': return '#1565c0'
    case 'walk': case 'walking': return '#00796b'
    case 'hiking': return '#2e7d32'
    case 'portaging': return '#00897b'
    case 'museum': return '#6a1b9a'
    case 'sightseeing': return '#f57c00'
    case 'exploring': return '#c62828'
    case 'restaurant': return '#d32f2f'
    case 'shopping': return '#7b1fa2'
    case 'photography': return '#0277bd'
    case 'adventure': return '#fbc02d'
    case 'free time': return '#78909c'
    default: return '#f57c00'
  }
}
