import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { MdAccessTime, MdDirectionsBike, MdDirectionsBus, MdDirectionsSubway, MdDirectionsTransit, MdDirectionsWalk, MdFlag, MdTrain, MdTram } from 'react-icons/md'
import { cx } from './ui'
import { journeyFromRouteSteps, minutesBetween, signWordsFor, stepHints, type JourneyStep } from '@/lib/transitJourney'
import { browserTimeZone, epochToWallTime, fetchTransitTimetable, type Timetable } from '@/services/transitTimetable'

interface Props {
  originName: string
  destinationName: string
  origin: { lat: number; lon: number }
  destination: { lat: number; lon: number }
  /** Cached route steps for the leg (no clock times). */
  steps: Record<string, any>[]
  arrivalStopName?: string
  /** "YYYY-MM-DD" the itinerary leaves the origin, used as the default departure day. */
  departureDate?: string
  onStepSelected?: (step: Record<string, any>) => void
}

function stepIcon(s: JourneyStep, size = 18) {
  if (s.kind === 'walk') return <MdDirectionsWalk size={size} />
  if (s.kind === 'other') return /bik|cycl/i.test(s.title) ? <MdDirectionsBike size={size} /> : <MdDirectionsWalk size={size} />
  const t = s.vehicleType ?? ''
  if (/BUS/.test(t)) return <MdDirectionsBus size={size} />
  if (/SUBWAY|METRO/.test(t)) return <MdDirectionsSubway size={size} />
  if (/TRAM|LIGHT_RAIL/.test(t)) return <MdTram size={size} />
  return <MdTrain size={size} />
}

const parseHex = (hex?: string): string | null => {
  const v = (hex ?? '').trim().replace('#', '')
  return /^[0-9a-f]{6}$/i.test(v) ? `#${v}` : null
}

const todayYmd = () => epochToWallTime(Date.now(), browserTimeZone()).slice(0, 10)

/** Trip day at 09:00, or the next whole hour today when the trip day is missing or already past. */
function defaultWallTime(departureDate?: string): string {
  if (departureDate && /^\d{4}-\d{2}-\d{2}$/.test(departureDate) && departureDate > todayYmd()) return `${departureDate}T09:00`
  return epochToWallTime(Math.ceil(Date.now() / 3600000) * 3600000, browserTimeZone())
}

interface Saved { wall: string; tz?: string; basedOn?: string }

function readSaved(key: string): Saved | null {
  try {
    const raw = JSON.parse(localStorage.getItem(key) ?? 'null')
    return raw && typeof raw.wall === 'string' ? raw : null
  } catch {
    return null
  }
}

function writeSaved(key: string, v: Saved) {
  try { localStorage.setItem(key, JSON.stringify(v)) } catch { /* storage unavailable */ }
}

function durationLabel(ms?: number | null) {
  if (ms == null || ms <= 0) return ''
  const min = Math.round(ms / 60000)
  return min < 60 ? `${min} min` : `${Math.floor(min / 60)} h ${String(min % 60).padStart(2, '0')} min`
}

/** Step-by-step transit directions for one leg, with live times and platforms for a chosen departure. */
export default function TransitLegCard({ originName, destinationName, origin, destination, steps, arrivalStopName, departureDate, onStepSelected }: Props) {
  const storageKey = `trypr.transitDepart.v1:${origin.lat.toFixed(4)},${origin.lon.toFixed(4)}>${destination.lat.toFixed(4)},${destination.lon.toFixed(4)}`
  const [wall, setWall] = useState(() => defaultWallTime(departureDate))
  const [timetable, setTimetable] = useState<Timetable | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [active, setActive] = useState<number | null>(null)

  const load = useCallback(async (when: string, tzHint?: string) => {
    setLoading(true)
    setError('')
    const res = await fetchTransitTimetable({ originLat: origin.lat, originLng: origin.lon, destLat: destination.lat, destLng: destination.lon, wallTime: when, timeZone: tzHint })
    setLoading(false)
    if (!res) {
      setTimetable(null)
      setError('No departures found for that time. Operators usually publish timetables only a few months ahead — try a nearer date to see a typical day.')
      return
    }
    setTimetable(res)
    setActive(null)
    writeSaved(storageKey, { wall: when, tz: res.timeZone, basedOn: departureDate })
  }, [origin.lat, origin.lon, destination.lat, destination.lon, storageKey, departureDate])

  // Restore the traveller's chosen departure for this leg (unless the trip dates moved since).
  useEffect(() => {
    setTimetable(null)
    setError('')
    const saved = readSaved(storageKey)
    if (saved && (saved.basedOn ?? '') === (departureDate ?? '') && saved.wall.slice(0, 10) >= todayYmd()) {
      setWall(saved.wall)
      void load(saved.wall, saved.tz)
    } else {
      setWall(defaultWallTime(departureDate))
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [storageKey, departureDate])

  const routeJourney = useMemo(() => journeyFromRouteSteps(steps), [steps])
  const journey = timetable?.steps ?? routeJourney
  const tz = timetable?.timeZone
  const words = useMemo(() => signWordsFor(journey), [journey])
  if (!journey.length) return null

  const clockParts = (at?: number): { time: string; period: string } => {
    if (at == null || !tz) return { time: '', period: '' }
    try {
      const parts = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit', timeZone: tz }).formatToParts(at)
      const period = parts.find((p) => p.type === 'dayPeriod')?.value ?? ''
      return { time: parts.filter((p) => p.type !== 'dayPeriod').map((p) => p.value).join('').trim(), period }
    } catch {
      return { time: '', period: '' }
    }
  }
  const clock = (at?: number) => Object.values(clockParts(at)).filter(Boolean).join(' ')
  // Narrow time column: AM/PM sits under the digits instead of wrapping mid-time.
  const timeCell = (at?: number, extra?: ReactNode) => {
    const { time, period } = clockParts(at)
    return <div className="journey-time">{time}{period && <span className="journey-period">{period}</span>}{extra}</div>
  }
  const rides = journey.filter((s) => s.kind === 'ride')
  const changes = Math.max(0, rides.length - 1)
  const changesText = changes === 0 ? 'direct' : `${changes} change${changes === 1 ? '' : 's'}`
  const tzCity = tz ? tz.split('/').pop()!.replace(/_/g, ' ') : ''
  const requestedDay = wall.slice(0, 10)
  const actualDay = timetable?.departAt != null && tz ? epochToWallTime(timetable.departAt, tz).slice(0, 10) : ''
  const firstRide = rides[0]

  const later = () => {
    if (!timetable || firstRide?.departAt == null) return
    const next = epochToWallTime(firstRide.departAt + 60000, timetable.timeZone)
    setWall(next)
    void load(next, timetable.timeZone)
  }

  const select = (i: number) => {
    setActive((cur) => (cur === i ? null : i))
    onStepSelected?.({ ...journey[i].focus })
  }

  const platformChip = (label: string, platform?: string, arriving = false) =>
    platform ? (
      <span className={cx('journey-platform', arriving && 'arriving')} title={words ? `Signs say "${words.platform}"` : undefined}>{label} {platform}</span>
    ) : null

  return (
    <div className="transit-leg">
      <div className="row gap-md" style={{ alignItems: 'flex-start' }}>
        <div className="center transit-leg-icon"><MdDirectionsTransit size={22} /></div>
        <div className="grow" style={{ minWidth: 0 }}>
          <div style={{ fontWeight: 800, color: '#111827' }}>{originName} → {destinationName}</div>
          <div className="transit-leg-sub">
            {timetable?.departAt != null
              ? `${clock(timetable.departAt)} – ${clock(timetable.arriveAt)} · ${durationLabel((timetable.arriveAt ?? 0) - timetable.departAt)} · ${changesText}`
              : `${journey.length} steps · ${changesText}${arrivalStopName?.trim() ? ` · arrive at ${arrivalStopName.trim()}` : ''}`}
          </div>
        </div>
      </div>

      <div className="transit-when">
        <label className="transit-when-label" htmlFor={`${storageKey}-when`}><MdAccessTime size={15} /> Leave at</label>
        <input
          id={`${storageKey}-when`}
          type="datetime-local"
          className="transit-when-input"
          value={wall}
          min={`${todayYmd()}T00:00`}
          onChange={(e) => setWall(e.target.value)}
        />
        <button type="button" className="transit-when-go" disabled={loading || !wall} onClick={() => void load(wall, timetable?.timeZone)}>
          {loading ? 'Checking…' : timetable ? 'Update' : 'Get live times'}
        </button>
      </div>
      <div className="transit-when-note">
        {timetable
          ? <>Times are local to {tzCity || 'the station'}.{' '}{firstRide?.departAt != null && <button type="button" className="link-btn" onClick={later} disabled={loading}>Next departure →</button>}</>
          : 'Pick when you want to set off to see real departure times and platforms.'}
      </div>
      {actualDay && actualDay !== requestedDay && <div className="transit-when-warn">No service then — the first departure is on {actualDay}.</div>}
      {error && <div className="transit-when-warn">{error}</div>}

      <ol className={cx('journey', !!timetable && 'timed')}>
        {journey.map((s, i) => {
          const color = s.kind === 'ride' ? parseHex(s.lineColor) ?? '#0f766e' : '#9ca3af'
          const hints = stepHints(journey, i, destinationName)
          const shown = active === i ? hints : hints.slice(0, 2)
          const ride = s.kind === 'ride'
          const gap = ride ? null : minutesBetween(s.departAt, s.arriveAt)
          return (
            <li key={i} className={cx('journey-step', s.kind, active === i && 'active')} style={{ ['--line' as any]: color }}>
              {timetable && timeCell(s.departAt, s.delayMin ? <span className="journey-late">+{s.delayMin} min</span> : null)}
              <div className="journey-rail"><span className="journey-dot">{i + 1}</span></div>
              <button type="button" className="journey-body" onClick={() => select(i)} aria-expanded={active === i}>
                <div className="journey-title">
                  <span className="journey-mode" style={{ color }}>{stepIcon(s)}</span>
                  <span>
                    {ride ? <>Take <b className="journey-line" style={{ background: color }}>{s.line ?? s.vehicleName ?? 'train'}</b>{s.headsign ? <> towards {s.headsign}</> : null}</> : s.title}
                  </span>
                </div>
                {ride && (
                  <div className="journey-meta">
                    {s.from?.name && <span>Board at <b>{s.from.name}</b></span>}
                    {platformChip('Platform', s.from?.platform)}
                    {s.cancelled && <span className="journey-cancelled">Cancelled</span>}
                  </div>
                )}
                {ride && (
                  <div className="journey-meta">
                    <span>
                      Get off at <b>{s.to?.name || 'your stop'}</b>
                      {s.arriveAt != null && tz ? ` · ${clock(s.arriveAt)}` : ''}
                    </span>
                    {platformChip('Arrives on', s.to?.platform, true)}
                  </div>
                )}
                {(s.numStops || s.durationText || s.distanceText) && (
                  <div className="journey-facts">
                    {[s.numStops ? `${s.numStops} stop${s.numStops === 1 ? '' : 's'}` : '', s.durationText ?? (gap ? `${gap} min` : ''), s.kind !== 'ride' ? s.distanceText ?? '' : '', s.agency ?? '']
                      .filter(Boolean).join(' · ')}
                  </div>
                )}
                {shown.length > 0 && (
                  <ul className="journey-hints">
                    {shown.map((h, hi) => <li key={hi}>{h}</li>)}
                  </ul>
                )}
                {hints.length > shown.length && <span className="journey-more">{hints.length - shown.length} more tip{hints.length - shown.length === 1 ? '' : 's'}</span>}
              </button>
            </li>
          )
        })}
        <li className="journey-step end">
          {timetable && timeCell(timetable.arriveAt)}
          <div className="journey-rail"><span className="journey-dot"><MdFlag size={13} /></span></div>
          <div className="journey-body static"><div className="journey-title"><span>Arrive at {destinationName}</span></div></div>
        </li>
      </ol>

      {words && (
        <div className="journey-words">
          Station signs: <b>{words.platform}</b> = platform · <b>{words.departures}</b> = departures · <b>{words.exit}</b> = exit
        </div>
      )}
      {timetable && (
        <div className="journey-source">
          Times from Google{timetable.platformSource ? <> · platforms from <a href={timetable.platformSource.url} target="_blank" rel="noreferrer">{timetable.platformSource.name}</a> (dev preview)</> : ' · check the station boards for platforms'}. Always confirm on the departure board.
        </div>
      )}
    </div>
  )
}
