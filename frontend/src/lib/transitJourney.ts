// Sequential, tourist-facing view of a transit leg: one ordered list of walk/ride steps plus
// plain-language hints for what to look for at each one.

export interface JourneyStop {
  name: string
  lat?: number
  lon?: number
  /** Platform / track / bay, when a data source knows it. */
  platform?: string
  /** Timetabled platform, when it differs from `platform` (a last-minute platform change). */
  plannedPlatform?: string
}

export interface JourneyStep {
  kind: 'walk' | 'ride' | 'other'
  /** Walk / other steps: the instruction itself ("Walk to Berlin Hauptbahnhof"). */
  title: string
  from?: JourneyStop
  to?: JourneyStop
  /** Ride steps: what is printed on the vehicle / departure board ("S5", "ICE 597"). */
  line?: string
  /** Google vehicle type, e.g. SUBWAY, COMMUTER_TRAIN, HIGH_SPEED_TRAIN, BUS. */
  vehicleType?: string
  vehicleName?: string
  headsign?: string
  agency?: string
  lineColor?: string
  numStops?: number
  /** Name of the stop just before `to`, so riders know when to get ready. */
  stopBefore?: string
  /** Epoch ms. */
  departAt?: number
  arriveAt?: number
  delayMin?: number
  cancelled?: boolean
  distanceText?: string
  durationText?: string
  /** The map-focus payload handed back through onStepSelected. */
  focus: Record<string, any>
}

const str = (v: unknown) => String(v ?? '').trim()

/** Adapt the cached per-leg route steps (no live times) into journey steps. */
export function journeyFromRouteSteps(steps: Record<string, any>[]): JourneyStep[] {
  const out: JourneyStep[] = []
  for (const s of steps) {
    const mode = str(s.mode).toLowerCase()
    const headline = str(s.headline)
    if (mode === 'transit' || mode === 'train') {
      // Older cached steps predate the structured fields: recover them from detail ("A → B") / caption (headsign).
      const [depFromDetail, arrFromDetail] = str(s.detail).split(' → ')
      const line = str(s.lineShortName) || str(s.tabLabel).replace(/^Train\s+/i, '')
      out.push({
        kind: 'ride',
        title: headline || line || 'Transit',
        line: line && line !== 'Transit' ? line : undefined,
        vehicleType: str(s.vehicleType) || undefined,
        headsign: str(s.headsign) || str(s.caption) || undefined,
        from: { name: str(s.departureStop) || str(depFromDetail) },
        to: { name: str(s.arrivalStop) || str(arrFromDetail) },
        lineColor: str(s.lineColor) || undefined,
        numStops: Number(s.numStops) > 0 ? Number(s.numStops) : undefined,
        durationText: str(s.durationText) || undefined,
        focus: s,
      })
    } else if (headline || str(s.tabLabel)) {
      out.push({
        kind: mode.startsWith('walk') ? 'walk' : 'other',
        title: headline || str(s.tabLabel),
        distanceText: str(s.detail) || undefined,
        durationText: str(s.durationText) || undefined,
        focus: s,
      })
    }
  }
  return out
}

// ---- station vocabulary ------------------------------------------------------------------------
// Signs are in the local language; a handful of words gets a tourist through most stations.

interface SignWords { platform: string; departures: string; exit: string }

const SIGN_WORDS: { test: RegExp; words: SignWords }[] = [
  { test: /hbf\b|bahnhof|\bbf\b|stra(ß|ss)e|platz\b/i, words: { platform: 'Gleis', departures: 'Abfahrt', exit: 'Ausgang' } },
  { test: /\bgare\b/i, words: { platform: 'Voie / Quai', departures: 'Départs', exit: 'Sortie' } },
  { test: /\bstazione\b|\bcentrale\b/i, words: { platform: 'Binario', departures: 'Partenze', exit: 'Uscita' } },
  { test: /\bestaci[oó]n\b|\bestaç[aã]o\b/i, words: { platform: 'Andén / Vía', departures: 'Salidas', exit: 'Salida' } },
  { test: /\bcentraal\b|\bstation\b.*\b(amsterdam|rotterdam|utrecht|den haag)\b/i, words: { platform: 'Spoor', departures: 'Vertrek', exit: 'Uitgang' } },
]

export function signWordsFor(steps: JourneyStep[]): SignWords | null {
  const names = steps.flatMap((s) => [s.from?.name, s.to?.name, s.headsign, s.title]).filter(Boolean).join(' | ')
  return SIGN_WORDS.find((w) => w.test.test(names))?.words ?? null
}

// ---- hints -------------------------------------------------------------------------------------

const isBus = (t = '') => /BUS|SHARE_TAXI/.test(t)
const isSubway = (t = '') => /SUBWAY|METRO_RAIL/.test(t)
const isTram = (t = '') => /TRAM|LIGHT_RAIL|MONORAIL/.test(t)
const isLongDistance = (s: JourneyStep) =>
  /HIGH_SPEED_TRAIN|LONG_DISTANCE_TRAIN|HEAVY_RAIL|INTERCITY_BUS/.test(s.vehicleType ?? '') || /^(ICE|IC|EC|TGV|RJX?|EST|AVE|FR|NJ|ES)\b/i.test(s.line ?? '')
const isBigStation = (name = '') => /\b(hbf|hauptbahnhof|central|centrale|centraal|gare|termini|station)\b/i.test(name)

/** A ride's next departure in plain words. */
export function boardingPhrase(s: JourneyStep): string {
  const what = s.line ? `${s.line}` : s.vehicleName || 'the train'
  return s.headsign ? `${what} towards ${s.headsign}` : what
}

/** Minutes between two epoch-ms times, or null when either is unknown. */
export const minutesBetween = (a?: number, b?: number) => (a != null && b != null ? Math.round((b - a) / 60000) : null)

/**
 * Up to ~4 short, concrete hints for step `i`: what to look for, what is easy to get wrong, and
 * when to act. Ordered most-important first so callers can truncate.
 */
export function stepHints(steps: JourneyStep[], i: number, destinationName: string): string[] {
  const s = steps[i]
  const prev = steps[i - 1]
  const next = steps[i + 1]
  const nextRide = steps.slice(i + 1).find((x) => x.kind === 'ride')
  const words = signWordsFor(steps)
  const hints: string[] = []

  if (s.kind === 'walk') {
    const betweenRides = prev?.kind === 'ride' && next?.kind === 'ride'
    if (betweenRides) {
      const gap = minutesBetween(prev.arriveAt, next.departAt)
      const toPlatform = next.from?.platform
      const fromPlatform = prev.to?.platform
      if (toPlatform && fromPlatform && toPlatform === fromPlatform) hints.push(`Same platform (${toPlatform}) — stay where you are and wait for ${boardingPhrase(next)}.`)
      else if (toPlatform) hints.push(`Follow the platform signs${words ? ` ("${words.platform}")` : ''} to platform ${toPlatform}.`)
      else hints.push(`Find ${boardingPhrase(next)} on the departure boards${words ? ` ("${words.departures}")` : ''} — it lists the platform.`)
      if (gap != null) {
        if (gap <= 4) hints.push(`Only ${gap} min to change — head straight there, don't stop for food or tickets.`)
        else if (gap >= 20) hints.push(`${gap} min to change — enough time for a snack or the restroom.`)
        else hints.push(`${gap} min to change.`)
      }
    } else if (nextRide) {
      const station = nextRide.from?.name || 'the station'
      if (isSubway(nextRide.vehicleType)) hints.push(`Look for the entrance to ${station} — subway entrances are often just a staircase down from the sidewalk.`)
      else if (isBus(nextRide.vehicleType)) hints.push(`Look for the stop sign or shelter named "${station}" — check it shows ${nextRide.line ?? 'your line'}.`)
      else hints.push(`Head into ${station}.${isBigStation(station) ? ' It is a big station — allow 10 min to find your platform.' : ''}`)
      if (!nextRide.from?.platform && !isBus(nextRide.vehicleType)) hints.push(`Once inside, find ${boardingPhrase(nextRide)} on the departure boards${words ? ` ("${words.departures}")` : ''} to get the platform.`)
      if (!isLongDistance(nextRide)) hints.push('Buy a ticket from the machine or app before you board — many systems fine riders without a validated ticket.')
    } else {
      hints.push(`Follow the exit signs${words ? ` ("${words.exit}")` : ''}, then walk to ${destinationName}.`)
    }
    return hints
  }

  if (s.kind === 'ride') {
    if (s.cancelled) hints.push('This service is reported cancelled — pick a later departure.')
    const pf = s.from?.platform
    if (pf && s.from?.plannedPlatform && s.from.plannedPlatform !== pf) hints.push(`Platform changed from ${s.from.plannedPlatform} to ${pf} — go to ${pf}.`)
    if (s.headsign) hints.push(`The front of the ${isBus(s.vehicleType) ? 'bus' : 'train'} shows "${s.headsign}" — that's the last stop, not yours. Check it before stepping on.`)
    if (isLongDistance(s)) hints.push('Have a seat reservation? Your ticket shows the car (coach) number; signs on the platform show where each car stops.')
    else if (isBus(s.vehicleType)) hints.push(`Press the stop button or signal the driver as you approach ${s.to?.name || 'your stop'}.`)
    else if (isTram(s.vehicleType) || isSubway(s.vehicleType)) hints.push('Doors may not open automatically — press the button on the door.')
    const getOff = s.to?.name ? `Get off at ${s.to.name}` : 'Get off at your stop'
    if (s.stopBefore) hints.push(`${getOff}. The stop before is ${s.stopBefore} — start getting ready when you leave it.`)
    else if (s.numStops) hints.push(`${getOff} after ${s.numStops} stop${s.numStops === 1 ? '' : 's'} — watch the screen inside or listen for the announcement.`)
    else hints.push(`${getOff} — watch the screen inside or listen for the announcement.`)
    return hints
  }

  return hints
}
