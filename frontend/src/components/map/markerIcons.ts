import { createElement, type ComponentType } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import {
  MdCameraAlt, MdDirectionsBike, MdDirectionsCar, MdDirectionsTransit, MdDirectionsWalk, MdExplore, MdFlightTakeoff,
  MdFreeBreakfast, MdHotel, MdKayaking, MdLocalActivity, MdLocalGasStation, MdLocationOn, MdMuseum,
  MdPhotoCamera, MdRestaurant, MdShoppingBag, MdTerrain,
} from 'react-icons/md'
import { categoryColor } from './mapStyles'

type IconComp = ComponentType<{ size?: number; color?: string }>

export function iconFor(kindRaw: string, categoryRaw: string): IconComp {
  const kind = kindRaw.trim().toLowerCase()
  const category = categoryRaw.trim().toLowerCase()
  if (kind === 'accommodation') return MdHotel
  switch (category) {
    case 'car': case 'driving': return MdDirectionsCar
    case 'train': case 'transit': return MdDirectionsTransit
    case 'plane': case 'flight': return MdFlightTakeoff
    case 'gas_stops': case 'gas': return MdLocalGasStation
    case 'bike': case 'biking': return MdDirectionsBike
    case 'walk': case 'pedestrian': case 'foot': case 'walking': return MdDirectionsWalk
    case 'hiking': return MdTerrain
    case 'portaging': return MdKayaking
    case 'museum': return MdMuseum
    case 'sightseeing': return MdCameraAlt
    case 'exploring': return MdExplore
    case 'restaurant': return MdRestaurant
    case 'shopping': return MdShoppingBag
    case 'photography': return MdPhotoCamera
    case 'adventure': return MdLocalActivity
    case 'free time': return MdFreeBreakfast
    default: return MdLocationOn
  }
}

/** Inner <path> markup of a react-icons component (24x24 viewBox). */
function iconInner(Icon: IconComp): string {
  const svg = renderToStaticMarkup(createElement(Icon, { size: 24 }))
  const m = svg.match(/<svg[^>]*>([\s\S]*)<\/svg>/)
  return m ? m[1] : ''
}

const cache = new Map<string, google.maps.Icon>()
const toUrl = (svg: string) => `data:image/svg+xml;charset=UTF-8,${encodeURIComponent(svg)}`

function circleBadge(opts: { key: string; size: number; bg: string; text?: string; icon?: IconComp; border?: number }): google.maps.Icon {
  const cached = cache.get(opts.key)
  if (cached) return cached
  const { size, bg, text, icon, border = 2 } = opts
  const r = size / 2
  const body = icon
    ? `<g transform="translate(${size * 0.2} ${size * 0.2}) scale(${(size * 0.6) / 24})" fill="#fff">${iconInner(icon)}</g>`
    : text
      ? `<text x="${r}" y="${r}" text-anchor="middle" dominant-baseline="central" font-family="Inter,Arial,sans-serif" font-weight="800" font-size="${size * 0.45}" fill="#fff">${text}</text>`
      : ''
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}"><circle cx="${r}" cy="${r}" r="${r - 1}" fill="${bg}" stroke="rgba(255,255,255,.85)" stroke-width="${border}"/>${body}</svg>`
  const out: google.maps.Icon = { url: toUrl(svg), scaledSize: new google.maps.Size(size, size), anchor: new google.maps.Point(r, r) }
  cache.set(opts.key, out)
  return out
}

export const numberedIcon = (n: number, color: string) => circleBadge({ key: `num:${n}:${color}`, size: 40, bg: color, text: String(n) })
export const viaDotIcon = () => circleBadge({ key: 'via', size: 24, bg: '#1565c0', border: 3 })
export const iconBadge = (kind: string, category: string) =>
  circleBadge({ key: `ic:${kind}:${category}`, size: 40, bg: categoryColor(kind, category), icon: iconFor(kind, category) })
export const trailheadIcon = () => circleBadge({ key: 'trailhead', size: 20, bg: '#00897b', icon: MdTerrain, border: 2 })
export const portageAccessIcon = () => circleBadge({ key: 'portageAccess', size: 22, bg: '#1565c0', icon: MdKayaking, border: 2.2 })

export function campsiteTriangleIcon(): google.maps.Icon {
  const key = 'campTri'
  const cached = cache.get(key)
  if (cached) return cached
  const w = 16, h = 18
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}"><path d="M${w / 2} 1.2 L${w - 1.2} ${h - 1.2} L1.2 ${h - 1.2} Z" fill="#ef6c00" stroke="rgba(255,255,255,.9)" stroke-width="1.8" stroke-linejoin="round"/></svg>`
  const out: google.maps.Icon = { url: toUrl(svg), scaledSize: new google.maps.Size(w, h), anchor: new google.maps.Point(w / 2, h / 2) }
  cache.set(key, out)
  return out
}
