import { useState } from 'react'
import { MdAutoAwesome, MdClose, MdTitle } from 'react-icons/md'
import { Dialog } from '@/components/Dialog'
import { Button, cx } from '@/components/ui'
import { normalizeTripType, tripTypeDisplayLabel } from '@/models/tripModel'
import {
  EXPERIENCE_OPTIONS, TRIP_TYPE_OPTIONS, defaultRoutingTypeForMode, normalizeBuilderMode, normalizeBuilderRoutingType,
  parseYmd, primaryRoutingLabelForMode, routingDescription, transportLabelForMode, tripNameValidationMessage,
  tripTypeSummary, ymd, isPlaceholderWaypointName,
} from '@/lib/tripBuilder'

// ---- Date range ---------------------------------------------------------------------------------

export function DateRangeDialog({ initialStart, initialEnd, onResult }: { initialStart: Date; initialEnd: Date; onResult: (r: { start: Date; end: Date } | null) => void }) {
  const [start, setStart] = useState(ymd(initialStart))
  const [end, setEnd] = useState(ymd(initialEnd))
  const s = parseYmd(start)
  const e = parseYmd(end)
  const valid = !!s && !!e && e >= s
  return (
    <Dialog
      title="Trip dates"
      onClose={() => onResult(null)}
      actions={
        <>
          <Button variant="text" onClick={() => onResult(null)}>Cancel</Button>
          <Button variant="text" disabled={!valid} onClick={() => onResult({ start: s!, end: e! })}>Apply</Button>
        </>
      }
    >
      <div className="row gap-sm" style={{ alignItems: 'center' }}>
        <input className="input" type="date" value={start} onChange={(ev) => { setStart(ev.target.value); const ns = parseYmd(ev.target.value); if (ns && e && e < ns) setEnd(ev.target.value) }} />
        <span>→</span>
        <input className="input" type="date" value={end} min={start} onChange={(ev) => setEnd(ev.target.value)} />
      </div>
      {!valid && <div style={{ color: 'var(--error)', marginTop: 8 }}>Pick a valid start and end date.</div>}
    </Dialog>
  )
}

// ---- Trip basics --------------------------------------------------------------------------------

export interface TripBasics { name: string; start: Date; end: Date; tripType: string; experience: string }

export function TripBasicsDialog({ initial, normalizeExperience, onResult }: { initial: TripBasics; normalizeExperience: (raw?: string) => string; onResult: (r: TripBasics | null) => void }) {
  const [name, setName] = useState(initial.name)
  const [start, setStart] = useState(ymd(initial.start))
  const [end, setEnd] = useState(ymd(initial.end))
  const [tripType, setTripType] = useState(normalizeTripType(initial.tripType))
  const [experience, setExperience] = useState(normalizeExperience(initial.experience))

  const nameError = tripNameValidationMessage(name)
  const s = parseYmd(start)
  const e = parseYmd(end)
  const hasDates = !!s && !!e && e >= s
  const canContinue = !nameError && hasDates
  const showExperience = tripType === 'portage' || tripType === 'hiking'

  return (
    <Dialog
      size="wide"
      onClose={() => onResult(null)}
      title={
        <div className="row between" style={{ alignItems: 'center' }}>
          <span>Start your trip</span>
          <button className="icon-btn" title="Close" onClick={() => onResult(null)}><MdClose size={20} /></button>
        </div>
      }
      actions={
        <>
          <Button variant="text" onClick={() => onResult(null)}>Not now</Button>
          <Button variant="text" disabled={!canContinue} onClick={() => onResult({ name: name.trim(), start: s!, end: e!, tripType, experience })}>Continue</Button>
        </>
      }
    >
      <div className="muted" style={{ fontSize: 12, fontWeight: 700, marginBottom: 8 }}>1. Choose a trip style</div>
      <div className="row wrap gap-sm">
        {TRIP_TYPE_OPTIONS.map((o) => (
          <button key={o.id} className={cx('chip', tripType === o.id && 'selected')} onClick={() => setTripType(o.id as any)}>{o.emoji} {o.label}</button>
        ))}
      </div>
      <div style={{ marginTop: 10, padding: 12, borderRadius: 14, background: '#f8fafc', border: '1px solid #e2e8f0' }}>
        <div style={{ fontWeight: 800 }}>{tripTypeDisplayLabel(tripType)}</div>
        <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>{tripTypeSummary(tripType)}</div>
        {tripType === 'portage' && (
          <div style={{ fontSize: 12, fontWeight: 600, marginTop: 10 }}>
            Portage trips start at access points like Brent Access Point, Shall Lake, or Magnetawan Lake. After that, search for campsites and portages reachable from your launch.
          </div>
        )}
        {tripType === 'hiking' && (
          <div style={{ fontSize: 12, fontWeight: 600, marginTop: 10 }}>
            Hiking trips work best when you start at a trailhead or campsite, then add only the overnights that should consume trip nights.
          </div>
        )}
      </div>

      {showExperience && (
        <>
          <div className="muted" style={{ fontSize: 12, fontWeight: 700, margin: '16px 0 8px' }}>2. Choose your experience level</div>
          <div className="row wrap gap-sm">
            {EXPERIENCE_OPTIONS.map((o) => (
              <button key={o.id} className={cx('chip', normalizeExperience(experience) === o.id && 'selected')} onClick={() => setExperience(o.id)}>{o.label}</button>
            ))}
          </div>
          <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>
            {(EXPERIENCE_OPTIONS.find((o) => o.id === normalizeExperience(experience)) ?? EXPERIENCE_OPTIONS[0]).summary}
          </div>
        </>
      )}

      <div style={{ marginTop: 16 }}>
        <div className="input-wrap">
          <span className="input-icon"><MdTitle size={18} /></span>
          <input className={cx('input', nameError && name.length > 0 && 'error')} placeholder="Trip name" value={name} onChange={(ev) => setName(ev.target.value)} autoFocus />
        </div>
        {name.length > 0 && nameError && <div style={{ color: 'var(--error)', fontSize: 12, marginTop: 4 }}>{nameError}</div>}
      </div>

      <div className="muted" style={{ fontSize: 12, fontWeight: 700, margin: '12px 0 6px' }}>3. Trip dates</div>
      <div className="row gap-sm" style={{ alignItems: 'center' }}>
        <input className="input" type="date" value={start} onChange={(ev) => { setStart(ev.target.value); const ns = parseYmd(ev.target.value); if (ns && e && e < ns) setEnd(ev.target.value) }} />
        <span>→</span>
        <input className="input" type="date" value={end} min={start} onChange={(ev) => setEnd(ev.target.value)} />
      </div>
      {!hasDates && <div style={{ color: 'var(--error)', marginTop: 8 }}>Dates are required to plan your itinerary.</div>}
    </Dialog>
  )
}

// ---- Destination --------------------------------------------------------------------------------

export interface DestinationDraft { name: string; isStop: boolean; nights: number; routingType: string }

export interface DestinationDialogProps {
  initialName: string
  lat: number
  lon: number
  segmentMode: string
  preferredRoutingType?: string
  campsiteData?: Record<string, any> | null
  preferStop?: boolean
  confirmLabel?: string
  totalTripNights: number
  availableNights: number
  onResult: (r: DestinationDraft | null) => void
}

export function DestinationDialog(p: DestinationDialogProps) {
  const mode = normalizeBuilderMode(p.segmentMode)
  const details = p.campsiteData ?? {}
  const suggestedName = isPlaceholderWaypointName(p.initialName) ? '' : p.initialName.trim()
  const primaryRouting = defaultRoutingTypeForMode(mode)
  const canCreateStay = p.totalTripNights > 0 && p.availableNights > 0

  const [name, setName] = useState(suggestedName)
  const [isStop, setIsStop] = useState((p.preferStop ?? true) && canCreateStay)
  const [nights, setNights] = useState(canCreateStay ? 1 : 0)
  const [routing, setRouting] = useState(normalizeBuilderRoutingType(p.preferredRoutingType ?? primaryRouting, mode))

  const facts: [string, string][] = []
  const addFact = (label: string, raw: unknown) => {
    const v = String(raw ?? '').trim()
    if (v) facts.push([label, v])
  }
  const distanceKm = typeof details.distanceKmFromRoute === 'number' ? details.distanceKmFromRoute : null
  addFact('Mode', transportLabelForMode(mode))
  if (distanceKm != null && Number.isFinite(distanceKm)) addFact('From route', `${distanceKm.toFixed(1)} km`)
  addFact('Area', details.lakeName ?? details.lake ?? details.waterBody ?? details.park ?? details.region)
  addFact('Access', details.access)
  addFact('Capacity', details.capacity)
  addFact('Amenities', details.amenities)
  addFact('Operator', details.operator)
  addFact('Accessible from', details.accessibleFrom)
  addFact('Route fit', details.routeDifficulty ?? details.difficulty)
  addFact('Est. time', details.estimatedTime)
  const routeWarning = String(details.warning ?? '').trim()

  const trimmed = name.trim()
  const nameError = isPlaceholderWaypointName(trimmed) ? 'Enter a custom stop name.' : null
  const previewRemaining = p.availableNights - (isStop ? nights : 0)
  const previewColor = previewRemaining < 0 ? '#c62828' : previewRemaining === 0 ? '#2E7D32' : 'rgba(0,0,0,0.54)'

  return (
    <Dialog
      onClose={() => p.onResult(null)}
      title={
        <div>
          <div>{Object.keys(details).length ? 'Add campsite to trip' : 'Add destination'}</div>
          <div className="muted" style={{ fontSize: 12, fontWeight: 400, marginTop: 6 }}>Choose the stop type, nights, and routing in one place.</div>
        </div>
      }
      actions={
        <>
          <Button variant="text" onClick={() => p.onResult(null)}>Cancel</Button>
          <Button
            variant="solid"
            disabled={!!nameError}
            onClick={() => p.onResult({ name: trimmed, isStop, nights: isStop ? Math.max(1, nights) : 0, routingType: routing })}
          >
            {p.confirmLabel ?? 'Add to Trip'}
          </Button>
        </>
      }
    >
      <div className="field">
        <label>Stop name</label>
        <input className={cx('input', nameError && 'error')} placeholder="Lake Louise Campground" value={name} autoFocus={!Object.keys(details).length} onChange={(e) => setName(e.target.value)} />
        {nameError && <div style={{ color: 'var(--error)', fontSize: 12 }}>{nameError}</div>}
      </div>

      <div style={{ marginTop: 12 }}>
        {facts.length ? (
          <div className="row wrap gap-sm">{facts.map(([k, v]) => <span key={k} className="chip">{k}: {v}</span>)}</div>
        ) : (
          <div className="muted" style={{ fontSize: 12 }}>Lat {p.lat.toFixed(5)}, Lon {p.lon.toFixed(5)}</div>
        )}
      </div>

      <div style={{ fontWeight: 800, margin: '18px 0 8px' }}>How should we treat this stop?</div>
      <label className="row gap-sm" style={{ alignItems: 'flex-start', opacity: canCreateStay ? 1 : 0.5, marginBottom: 8 }}>
        <input type="radio" name="role" checked={isStop} disabled={!canCreateStay} onChange={() => { setIsStop(true); if (nights <= 0) setNights(1) }} />
        <span>
          <div style={{ fontWeight: 600 }}>Stay stop</div>
          <div className="muted" style={{ fontSize: 12 }}>
            {canCreateStay ? 'Overnight stay that uses trip nights and gets dated automatically.' : 'No trip nights are left yet, so overnight stays are disabled for now.'}
          </div>
        </span>
      </label>
      <label className="row gap-sm" style={{ alignItems: 'flex-start' }}>
        <input type="radio" name="role" checked={!isStop} onChange={() => setIsStop(false)} />
        <span>
          <div style={{ fontWeight: 600 }}>Waypoint</div>
          <div className="muted" style={{ fontSize: 12 }}>Transit-only stop for navigation, resupply, or route shaping. Uses no nights.</div>
        </span>
      </label>

      <div style={{ marginTop: 10 }}>
        {isStop ? (
          <>
            <div className="field">
              <label>How many nights here?</label>
              <select className="select" value={Math.max(1, nights)} disabled={!canCreateStay} onChange={(e) => setNights(Number(e.target.value))}>
                {Array.from({ length: Math.max(1, p.availableNights) }, (_, i) => i + 1).map((v) => (
                  <option key={v} value={v}>{v} night{v === 1 ? '' : 's'}</option>
                ))}
              </select>
            </div>
            <div style={{ fontSize: 12, marginTop: 8, fontWeight: 700, color: previewColor }}>
              Remaining nights after this stop: {Math.min(999, Math.max(0, previewRemaining))}{previewRemaining === 0 ? '  Perfect fit.' : ''}
            </div>
          </>
        ) : (
          <div className="muted" style={{ fontSize: 12 }}>
            {p.totalTripNights <= 0
              ? 'This trip currently has 0 overnight nights, so new destinations will stay as waypoints until the date range changes.'
              : 'Waypoints skip night allocation and only shape the route.'}
          </div>
        )}
      </div>

      <div style={{ fontWeight: 800, margin: '18px 0 8px' }}>Routing for this leg</div>
      <label className="row gap-sm" style={{ alignItems: 'flex-start', marginBottom: 8 }}>
        <input type="radio" name="routing" checked={routing === primaryRouting} onChange={() => setRouting(primaryRouting)} />
        <span>
          <div style={{ fontWeight: 600 }}>{primaryRoutingLabelForMode(mode)} routing (recommended)</div>
          <div className="muted" style={{ fontSize: 12 }}>{routingDescription(primaryRouting, mode)}</div>
        </span>
      </label>
      <label className="row gap-sm" style={{ alignItems: 'flex-start' }}>
        <input type="radio" name="routing" checked={routing === 'direct'} onChange={() => setRouting('direct')} />
        <span>
          <div style={{ fontWeight: 600 }}>Direct line</div>
          <div className="muted" style={{ fontSize: 12 }}>{routingDescription('direct', mode)}</div>
        </span>
      </label>

      {routeWarning && (
        <div style={{ marginTop: 8, padding: 10, borderRadius: 12, background: '#FFF4E5', border: '1px solid #FFCC80', fontSize: 12, fontWeight: 600, color: '#8A5A00' }}>
          {routeWarning}
        </div>
      )}
    </Dialog>
  )
}

// ---- Portage access point boundary --------------------------------------------------------------

export function AccessPointDialog(p: {
  name: string
  lat: number
  lon: number
  routeKm: number
  currentStart: string
  currentEnd: string
  startLabel: string
  endLabel: string
  onResult: (r: 'start' | 'end' | null) => void
}) {
  return (
    <Dialog
      title={p.name}
      onClose={() => p.onResult(null)}
      actions={
        <>
          <Button variant="text" onClick={() => p.onResult(null)}>Cancel</Button>
          <Button variant="text" onClick={() => p.onResult('start')}>{p.startLabel}</Button>
          <Button variant="solid" onClick={() => p.onResult('end')}>{p.endLabel}</Button>
        </>
      }
    >
      <div>Use this portage access point as your trip boundary.</div>
      <div style={{ marginTop: 8 }}>About {p.routeKm.toFixed(1)} km from the visible route network</div>
      <div className="muted" style={{ fontSize: 12, marginTop: 8 }}>Lat {p.lat.toFixed(5)}, Lon {p.lon.toFixed(5)}</div>
      {p.currentStart && <div className="muted" style={{ fontSize: 12, marginTop: 8 }}>Current start: {p.currentStart}</div>}
      {p.currentEnd && <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>Current end: {p.currentEnd}</div>}
    </Dialog>
  )
}

// ---- Route tap options --------------------------------------------------------------------------

export function RouteOptionsDialog(p: { afterIndex: number; onResult: (r: 'pin' | 'find' | null) => void }) {
  return (
    <Dialog
      title="Route Options"
      onClose={() => p.onResult(null)}
      actions={
        <>
          <Button variant="text" onClick={() => p.onResult(null)}>Cancel</Button>
          <Button variant="text" onClick={() => p.onResult('pin')}>Drop pin here</Button>
          <Button variant="solid" icon={<MdAutoAwesome size={16} />} style={{ background: '#00897B' }} onClick={() => p.onResult('find')}>Find Stay Stop Between</Button>
        </>
      }
    >
      <div className="muted">Between stop {p.afterIndex + 1} and {p.afterIndex + 2}</div>
    </Dialog>
  )
}
