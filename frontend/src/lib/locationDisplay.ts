export interface LocationDisplay {
  title: string
  subtitle: string
}

const caPostal = /\b[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTVXY][ -]?\d[ABCEGHJ-NPRSTVXY]\d\b/i
const usZip = /\b\d{5}(-\d{4})?\b/
const looksNumeric = /^\d+[A-Za-z]?$/

const provinceToAbbr: Record<string, string> = {
  alberta: 'AB', 'british columbia': 'BC', manitoba: 'MB', 'new brunswick': 'NB',
  'newfoundland and labrador': 'NL', newfoundland: 'NL', labrador: 'NL',
  'northwest territories': 'NT', 'nova scotia': 'NS', nunavut: 'NU', ontario: 'ON',
  'prince edward island': 'PE', quebec: 'QC', saskatchewan: 'SK', yukon: 'YT',
  alabama: 'AL', alaska: 'AK', arizona: 'AZ', arkansas: 'AR', california: 'CA',
  colorado: 'CO', connecticut: 'CT', delaware: 'DE', 'district of columbia': 'DC',
  florida: 'FL', georgia: 'GA', hawaii: 'HI', idaho: 'ID', illinois: 'IL', indiana: 'IN',
  iowa: 'IA', kansas: 'KS', kentucky: 'KY', louisiana: 'LA', maine: 'ME', maryland: 'MD',
  massachusetts: 'MA', michigan: 'MI', minnesota: 'MN', mississippi: 'MS', missouri: 'MO',
  montana: 'MT', nebraska: 'NE', nevada: 'NV', 'new hampshire': 'NH', 'new jersey': 'NJ',
  'new mexico': 'NM', 'new york': 'NY', 'north carolina': 'NC', 'north dakota': 'ND',
  ohio: 'OH', oklahoma: 'OK', oregon: 'OR', pennsylvania: 'PA', 'rhode island': 'RI',
  'south carolina': 'SC', 'south dakota': 'SD', tennessee: 'TN', texas: 'TX', utah: 'UT',
  vermont: 'VT', virginia: 'VA', washington: 'WA', 'west virginia': 'WV', wisconsin: 'WI',
  wyoming: 'WY',
}

const normalizeToken = (s: string) => s.trim().replace(/\s+/g, ' ')
const isPostal = (t: string) => caPostal.test(t.trim()) || usZip.test(t.trim())

function isNoiseAdmin(token: string): boolean {
  const t = token.toLowerCase()
  if (/\b(district|county|region)\b/i.test(t)) return true
  return /\b(horseshoe|metropolitan|metro|greater|area|census division)\b/i.test(t)
}

function isCountry(token: string): boolean {
  const t = token.toLowerCase()
  return t === 'canada' || t === 'united states' || t === 'usa' || t === 'us'
}

function abbrProvince(token: string): string {
  const norm = token.trim()
  const lower = norm.toLowerCase()
  if (provinceToAbbr[lower]) return provinceToAbbr[lower]
  const stripped = norm.replace(/\./g, '').trim()
  if (stripped.length === 2 && /^[A-Za-z]{2}$/.test(stripped)) return stripped.toUpperCase()
  return norm
}

const streetSuffix: Record<string, string> = {
  boulevard: 'Blvd', avenue: 'Ave', street: 'St', road: 'Rd', drive: 'Dr', lane: 'Ln',
  court: 'Ct', place: 'Pl', terrace: 'Ter', highway: 'Hwy', trail: 'Trl', circle: 'Cir',
}

function abbrStreetSuffix(street: string): string {
  const s = street.trim()
  const parts = s.split(/\s+/)
  if (!parts.length) return s
  const ab = streetSuffix[parts[parts.length - 1].toLowerCase()]
  if (!ab) return s
  parts[parts.length - 1] = ab
  return parts.join(' ')
}

/**
 * "Clean but Verified" formatter.
 * - Title: Place name (preferred). If none, street address.
 * - Subtitle: [Street Address] (if not used in title), [City], [Prov/State]
 * - Strips: District/County/Region and postal codes.
 */
export function formatLocationDisplay(opts: { placeName?: string | null; raw?: string | null }): LocationDisplay {
  const rawText = (opts.raw ?? '').trim()
  const pn = (opts.placeName ?? '').trim()
  if (!rawText && !pn) return { title: '', subtitle: '' }

  const tokens = rawText
    .split(',')
    .map(normalizeToken)
    .filter((t) => t && !isCountry(t) && !isNoiseAdmin(t) && !isPostal(t))

  const cleaned: string[] = []
  for (const t of tokens) {
    if (cleaned.length && cleaned[cleaned.length - 1].toLowerCase() === t.toLowerCase()) continue
    cleaned.push(t)
  }

  let place = ''
  if (pn && !pn.includes(',')) {
    place = pn
  } else if (cleaned.length >= 3 && !looksNumeric.test(cleaned[0])) {
    if (looksNumeric.test(cleaned[1])) place = cleaned[0]
  }

  let prov = ''
  let provIndex = -1
  for (let i = cleaned.length - 1; i >= 0; i--) {
    const ab = abbrProvince(cleaned[i])
    if (ab.length === 2 && /^[A-Z]{2}$/.test(ab)) {
      prov = ab
      provIndex = i
      break
    }
    if (provinceToAbbr[cleaned[i].toLowerCase()]) {
      prov = abbrProvince(cleaned[i])
      provIndex = i
      break
    }
  }

  let city = ''
  if (provIndex > 0) {
    for (let i = provIndex - 1; i >= 0; i--) {
      const t = cleaned[i]
      if (isNoiseAdmin(t) || isPostal(t) || isCountry(t)) continue
      city = t
      break
    }
  } else if (cleaned.length >= 2) {
    city = cleaned[cleaned.length - 1]
  }

  let street = ''
  if (cleaned.length >= 2) {
    if (place) {
      const after = cleaned.slice(1)
      if (after.length && looksNumeric.test(after[0])) {
        const road = after.length >= 2 ? after[1] : ''
        street = normalizeToken([after[0], road].filter(Boolean).join(' '))
      } else {
        street = after[0]
      }
    } else if (looksNumeric.test(cleaned[0])) {
      const road = cleaned.length >= 2 ? cleaned[1] : ''
      street = normalizeToken([cleaned[0], road].filter(Boolean).join(' '))
    }
  }
  if (street) street = abbrStreetSuffix(street)

  const title = (place || street || (cleaned.length ? cleaned[0] : pn)).trim()

  const subParts: string[] = []
  if (street && title.toLowerCase() !== street.toLowerCase()) subParts.push(street)
  if (city && city.toLowerCase() !== title.toLowerCase()) subParts.push(city)
  if (prov) subParts.push(prov)

  return { title, subtitle: subParts.join(', ') }
}
