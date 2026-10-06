import { useEffect, useMemo, useRef, useState, type ReactElement } from 'react'
import {
  MdAddCircleOutline, MdAltRoute, MdArrowForward, MdAutoAwesome, MdChevronLeft, MdChevronRight, MdDateRange, MdDeleteOutline,
  MdDirectionsBike, MdDirectionsCar, MdDirectionsTransit, MdDirectionsWalk, MdEditCalendar, MdFlight, MdKayaking, MdLocalActivity,
  MdLocationCity, MdLocationOn, MdOutlineMap, MdPlace,
} from 'react-icons/md'
import MapEmbed from '@/components/map/MapEmbed'
import { Dialog } from '@/components/Dialog'
import { Button, SoftCard, Spinner, cx } from '@/components/ui'
import { searchAddress, type AddressSuggestion } from '@/services/addressSearch'
import { mapList } from '@/lib/tripDetail'
import { mapRoutePoints } from '@/lib/tripDetail'
import {
  CATEGORY_EMOJIS, TRAVEL_CATEGORIES, categoriesForMapPoint, formatDisplayDate, formatDurationShort, isSameDate,
  itineraryAiSummary, itineraryMapPointKind, itineraryMapPointSubtitle, itineraryMapPointTitle, mapItineraryActivityPins,
  normalizePlanningMode, shortName, sortActivitiesByStartTime, stripDate, tryParseDate, travelModeLabel, ymdOf, type Row,
} from '@/lib/planning'
import { addDaysTo } from '@/lib/planning'

// ---- small helpers ------------------------------------------------------------------------------

function travelModeIcon(mode: string, size = 15) {
  switch (normalizePlanningMode(mode)) {
    case 'transit': return <MdDirectionsTransit size={size} />
    case 'walking': case 'hiking': case 'backpacking': return <MdDirectionsWalk size={size} />
    case 'portaging': return <MdKayaking size={size} />
    case 'biking': case 'bikepacking': return <MdDirectionsBike size={size} />
    case 'flying': return <MdFlight size={size} />
    default: return <MdDirectionsCar size={size} />
  }
}

const num = (v: unknown) => {
  const n = typeof v === 'number' ? v : parseFloat(String(v ?? ''))
  return Number.isFinite(n) ? n : 0
}

// ---- Activity form dialog -----------------------------------------------------------------------

export interface ActivityDialogState { dayIndex: number; activityIndex: number | null; existing: Row | null }

function ActivityDialog({ state, onClose, onSave, onDelete, notify }: {
  state: ActivityDialogState
  onClose: () => void
  onSave: (activity: Row) => void
  onDelete: () => void
  notify: (m: string) => void
}) {
  const ex = state.existing
  const isEdit = !!ex
  const [title, setTitle] = useState(String(ex?.title ?? ''))
  const [startTime, setStartTime] = useState(String(ex?.startTime ?? ''))
  const [endTime, setEndTime] = useState(String(ex?.endTime ?? ''))
  const [location, setLocation] = useState(String(ex?.location ?? ''))
  const [notes, setNotes] = useState(String(ex?.notes ?? ''))
  const [category, setCategory] = useState(String(ex?.category ?? 'Exploring'))
  const [lat, setLat] = useState<number | null>(typeof ex?.locationLat === 'number' ? ex.locationLat : null)
  const [lon, setLon] = useState<number | null>(typeof ex?.locationLon === 'number' ? ex.locationLon : null)
  const [suggestions, setSuggestions] = useState<AddressSuggestion[]>([])
  const [locLoading, setLocLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const debounce = useRef<ReturnType<typeof setTimeout>>(undefined)
  useEffect(() => () => clearTimeout(debounce.current), [])

  const onLocationChange = (v: string) => {
    setLocation(v)
    setLat(null)
    setLon(null)
    clearTimeout(debounce.current)
    if (!v.trim()) {
      setSuggestions([])
      setLocLoading(false)
      return
    }
    debounce.current = setTimeout(async () => {
      setLocLoading(true)
      const results = await searchAddress(v.trim())
      setSuggestions(results)
      setLocLoading(false)
    }, 350)
  }

  const save = async () => {
    clearTimeout(debounce.current)
    if (!title.trim()) return notify('Please enter an activity title')
    setSaving(true)
    const locationText = location.trim()
    let rLat = lat
    let rLon = lon
    if (locationText && (rLat == null || rLon == null)) {
      try {
        const results = await searchAddress(locationText)
        if (results.length) {
          rLat = results[0].lat
          rLon = results[0].lon
        }
      } catch {
        /* location stays unresolved */
      }
    }
    const activity: Row = { title: title.trim(), startTime, endTime, location: locationText, notes: notes.trim(), category }
    if (rLat != null) activity.locationLat = rLat
    if (rLon != null) activity.locationLon = rLon
    // Keep auto-travel flags if editing a generated travel activity.
    if (ex?.isAutoTravel) Object.assign(activity, { isAutoTravel: ex.isAutoTravel, travelMode: ex.travelMode, travelScore: ex.travelScore })
    setSaving(false)
    onSave(activity)
  }

  return (
    <Dialog
      onClose={onClose}
      title={isEdit ? 'Edit Activity' : 'Add Activity'}
      actions={
        <>
          <Button variant="text" onClick={onClose}>Cancel</Button>
          {isEdit && <Button variant="text" style={{ color: 'var(--error)' }} onClick={onDelete}>Delete</Button>}
          <Button variant="solid" loading={saving} onClick={save}>Save</Button>
        </>
      }
    >
      <div className="col gap-md">
        <div className="field"><label>Activity title</label><input className="input" value={title} onChange={(e) => setTitle(e.target.value)} autoFocus /></div>
        <div className="row gap-sm">
          <div className="field grow"><label>Start</label><input className="input" type="time" value={startTime} onChange={(e) => setStartTime(e.target.value)} /></div>
          <div className="field grow"><label>End</label><input className="input" type="time" value={endTime} onChange={(e) => setEndTime(e.target.value)} /></div>
        </div>
        <div className="field">
          <label>Location {locLoading && <Spinner size="sm" />}</label>
          <input className="input" value={location} onChange={(e) => onLocationChange(e.target.value)} />
          {suggestions.length > 0 && (
            <div style={{ maxHeight: 150, overflowY: 'auto', border: '1px solid var(--border)', borderRadius: 8, marginTop: 4 }}>
              {suggestions.map((s, i) => (
                <div key={i} className="tb-result" style={{ padding: '8px 10px', fontSize: 13 }} onClick={() => { setLocation(s.displayName); setLat(s.lat); setLon(s.lon); setSuggestions([]) }}>
                  {s.displayName}
                </div>
              ))}
            </div>
          )}
        </div>
        <div className="field"><label>Notes</label><textarea className="textarea" rows={3} value={notes} onChange={(e) => setNotes(e.target.value)} /></div>
        <div className="field">
          <label>Category</label>
          <select className="select" value={category in TRAVEL_CATEGORIES ? category : 'Exploring'} onChange={(e) => setCategory(e.target.value)}>
            {Object.keys(TRAVEL_CATEGORIES).map((c) => <option key={c} value={c}>{CATEGORY_EMOJIS[c] ?? '📌'} {c}</option>)}
          </select>
        </div>
      </div>
    </Dialog>
  )
}

// ---- Stay dates dialog --------------------------------------------------------------------------

export function StayDatesDialog({ tripStart, tripEnd, stays, onClose, onApply }: {
  tripStart: Date
  tripEnd: Date
  stays: { index: number; name: string; start: Date; end: Date }[]
  onClose: () => void
  onApply: (updated: { index: number; start: Date; end: Date }[]) => void
}) {
  const [local, setLocal] = useState(stays.map((s) => ({ ...s })))
  const [error, setError] = useState('')
  const set = (i: number, patch: Partial<{ start: Date; end: Date }>) => {
    setError('')
    setLocal((l) => l.map((e, k) => {
      if (k !== i) return e
      const next = { ...e, ...patch }
      if (patch.start && next.end < patch.start) next.end = patch.start
      return next
    }))
  }
  const validate = (): string | null => {
    for (const e of local) {
      if (e.end < e.start) return 'Each stop must end on or after it starts.'
      if (e.start < tripStart || e.end > tripEnd) return 'Stop dates must stay within the trip range.'
    }
    if (!isSameDate(local[0].start, tripStart)) return `The first stop must start on ${ymdOf(tripStart)}.`
    for (let i = 1; i < local.length; i++) {
      const latest = stripDate(addDaysTo(local[i - 1].end, 1))
      if (local[i].start > latest) return `Stop ${i + 1} starts too late. It must start on or before ${ymdOf(latest)} (overlaps are allowed).`
    }
    if (!isSameDate(local[local.length - 1].end, tripEnd)) return `The last stop must end on ${ymdOf(tripEnd)}.`
    return null
  }
  const parse = (s: string, fallback: Date) => tryParseDate(s) ?? fallback

  return (
    <Dialog
      size="wide"
      onClose={onClose}
      title="Edit stay dates"
      actions={
        <>
          <Button variant="text" onClick={onClose}>Cancel</Button>
          <Button variant="text" onClick={() => { const e = validate(); if (e) setError(e); else onApply(local.map(({ index, start, end }) => ({ index, start, end }))) }}>Apply</Button>
        </>
      }
    >
      <div className="muted" style={{ fontSize: 12, marginBottom: 12 }}>Trip range: {ymdOf(tripStart)} → {ymdOf(tripEnd)}</div>
      <div className="col gap-sm" style={{ maxHeight: 360, overflowY: 'auto' }}>
        {local.map((e, i) => {
          const nights = Math.round((e.end.getTime() - e.start.getTime()) / 86400000) + 1
          return (
            <div key={e.index} style={{ padding: 10, border: '1px solid var(--border)', borderRadius: 10 }}>
              <div style={{ fontWeight: 700, marginBottom: 8 }}>{e.name}</div>
              <div className="row gap-sm" style={{ alignItems: 'center' }}>
                <input className="input" type="date" value={ymdOf(e.start)} min={ymdOf(tripStart)} max={ymdOf(e.end)} onChange={(ev) => set(i, { start: parse(ev.target.value, e.start) })} />
                <MdArrowForward size={16} />
                <input className="input" type="date" value={ymdOf(e.end)} min={ymdOf(e.start)} max={ymdOf(tripEnd)} onChange={(ev) => set(i, { end: parse(ev.target.value, e.end) })} />
                <span className="muted" style={{ fontSize: 12, fontWeight: 600, whiteSpace: 'nowrap' }}>{nights} night{nights === 1 ? '' : 's'}</span>
              </div>
            </div>
          )
        })}
      </div>
      {error && <div style={{ color: 'var(--error)', fontSize: 12, marginTop: 10 }}>{error}</div>}
    </Dialog>
  )
}

// ---- Map insight card ---------------------------------------------------------------------------

function InsightCard({ days, point }: { days: Row[]; point: Row | null }) {
  if (!point) {
    return (
      <div style={{ padding: 10, borderRadius: 12, background: 'rgba(255,255,255,0.82)', border: '1px solid rgba(0,0,0,0.08)', fontSize: 12 }} className="muted">
        Tap a map pin to view a place summary and activity categories.
      </div>
    )
  }
  const title = itineraryMapPointTitle(point)
  const subtitle = itineraryMapPointSubtitle(days, point)
  const categories = categoriesForMapPoint(days, point)
  const summary = itineraryAiSummary(days, point, categories)
  const kind = itineraryMapPointKind(point)
  return (
    <div style={{ padding: 10, borderRadius: 12, background: 'rgba(255,255,255,0.86)', border: '1px solid rgba(0,0,0,0.08)' }}>
      <div className="row" style={{ alignItems: 'center', gap: 6 }}>
        {kind === 'activity' ? <MdLocalActivity size={16} /> : kind === 'waypoint' ? <MdLocationCity size={16} /> : <MdPlace size={16} />}
        <span style={{ fontSize: 12, fontWeight: 700 }}>Place Insight</span>
        <span className="grow" />
        <MdAutoAwesome size={14} className="muted" />
      </div>
      <div style={{ fontSize: 14, fontWeight: 700, marginTop: 8 }}>{title}</div>
      {subtitle && <div className="muted" style={{ fontSize: 12, marginTop: 2 }}>{subtitle}</div>}
      <div style={{ fontSize: 11, fontWeight: 700, marginTop: 8 }}>AI Summary</div>
      <div style={{ fontSize: 12, marginTop: 4 }}>{summary}</div>
      {categories.length > 0 && (
        <>
          <div style={{ fontSize: 11, fontWeight: 700, marginTop: 8 }}>Activity Categories</div>
          <div className="row wrap gap-xs" style={{ marginTop: 6 }}>
            {categories.slice(0, 6).map((c) => (
              <span key={c} style={{ padding: '4px 8px', borderRadius: 999, background: 'rgba(0,0,0,0.06)', fontSize: 11, fontWeight: 600 }}>{CATEGORY_EMOJIS[c] ?? '📌'} {c}</span>
            ))}
          </div>
        </>
      )}
    </div>
  )
}

// ---- Calendar -----------------------------------------------------------------------------------

function CalendarCard({ days, selected, onSelect }: { days: Row[]; selected: number; onSelect: (i: number) => void }) {
  const first = tryParseDate(String(days[0].date ?? ''))
  // Monday-first grid.
  const leading = first ? (first.getDay() + 6) % 7 : 0
  const totalCells = Math.floor((leading + days.length + 6) / 7) * 7
  const activityCount = days.reduce((t, d) => t + mapList(d.activities).length, 0)
  const travelDays = days.filter((d) => d.isTravel === true).length
  const planned = days.filter((d) => mapList(d.activities).length > 0 || String(d.notes ?? '').trim()).length
  const metric = (icon: ReactElement, value: number, label: string) => (
    <span className="chip" style={{ fontSize: 11, fontWeight: 600 }}>{icon} {value} {label}</span>
  )
  return (
    <SoftCard padding={12} radius={14}>
      <div style={{ fontWeight: 700, fontSize: 15 }}>Calendar Planner</div>
      <div className="row wrap gap-sm" style={{ marginTop: 8 }}>
        {metric(<MdDateRange size={14} />, days.length, 'days')}
        {metric(<MdLocalActivity size={14} />, activityCount, 'activities')}
        {metric(<MdAltRoute size={14} />, travelDays, 'travel days')}
        {metric(<MdDateRange size={14} />, planned, 'planned')}
      </div>
      <div className="plan-cal" style={{ marginTop: 10 }}>
        {['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((w) => <div key={w} className="plan-cal-head">{w}</div>)}
        {Array.from({ length: totalCells }, (_v, cell) => {
          const di = cell - leading
          if (di < 0 || di >= days.length) return <div key={cell} />
          const day = days[di]
          const isSel = di === selected
          const isTravel = day.isTravel === true
          const acts = mapList(day.activities).length
          const date = tryParseDate(String(day.date ?? ''))
          const loc = shortName(String(day.locationName ?? ''))
          return (
            <button key={cell} className={cx('plan-cal-cell', isSel && 'selected')} onClick={() => onSelect(di)}>
              <div className="row" style={{ alignItems: 'center' }}>
                <span style={{ fontSize: 13, fontWeight: 700, color: isSel ? 'var(--primary)' : undefined }}>{date ? date.getDate() : day.dayNumber ?? di + 1}</span>
                <span className="grow" />
                {isTravel && <MdDirectionsCar size={13} color="#f97316" />}
              </div>
              <div className="faint" style={{ fontSize: 10 }}>D{day.dayNumber ?? di + 1}</div>
              <div className="grow" />
              {!isTravel && loc && <div className="ellipsis muted" style={{ fontSize: 10 }}>{loc}</div>}
              {acts > 0 && <span className="plan-cal-badge">{acts}</span>}
            </button>
          )
        })}
      </div>
    </SoftCard>
  )
}

// ---- Day card -----------------------------------------------------------------------------------

function DayCard({ day, dayIndex, updatingTravel, onPatch, onAdd, onEdit, onDeleteActivity }: {
  day: Row
  dayIndex: number
  updatingTravel: boolean
  onPatch: (patch: Row) => void
  onAdd: () => void
  onEdit: (activityIndex: number, activity: Row) => void
  onDeleteActivity: (activityIndex: number) => void
}) {
  const dateStr = String(day.date ?? '')
  const location = String(day.locationName ?? '')
  const activities = sortActivitiesByStartTime(mapList(day.activities))
  const isTravel = day.isTravel === true
  const travelFrom = String(day.travelFrom ?? '')
  const travelTo = String(day.travelTo ?? '')
  const travelMode = String(day.travelMode ?? '')
  const status = String(day.travelRecommendationStatus ?? '')
  const options = mapList(day.travelOptions)
  const recIdx = typeof day.recommendedTravelOptionIndex === 'number' ? day.recommendedTravelOptionIndex : -1

  return (
    <SoftCard padding={16} radius={14}>
      <div className="row" style={{ alignItems: 'center', gap: 10 }}>
        <div style={{ width: 38, height: 38, borderRadius: 10, display: 'flex', alignItems: 'center', justifyContent: 'center', background: isTravel ? 'rgba(249,115,22,0.15)' : 'rgba(74,173,232,0.1)' }}>
          {isTravel ? <MdDirectionsCar size={20} color="#f97316" /> : <span style={{ fontWeight: 800, color: 'var(--primary)' }}>{String(day.dayNumber ?? dayIndex + 1)}</span>}
        </div>
        <div className="grow" style={{ minWidth: 0 }}>
          {dateStr && <div className="faint" style={{ fontSize: 12 }}>{formatDisplayDate(dateStr)}</div>}
          {isTravel ? (
            <div className="row" style={{ alignItems: 'center', gap: 3, color: '#f97316', fontWeight: 700, fontSize: 13 }}><MdLocationOn size={14} /> Travel Day</div>
          ) : location ? (
            <div className="row" style={{ alignItems: 'center', gap: 3, fontWeight: 600, fontSize: 13 }}><MdLocationOn size={14} color="var(--primary)" /> <span className="ellipsis">{location}</span></div>
          ) : null}
        </div>
        <button className="icon-btn" title="Add activity" onClick={onAdd}><MdAddCircleOutline size={22} /></button>
      </div>

      {isTravel && travelFrom && travelTo && (
        <div className="row" style={{ marginTop: 10, padding: '12px 14px', borderRadius: 10, background: 'linear-gradient(90deg, rgba(249,115,22,0.08), rgba(251,191,36,0.06))', border: '1px solid rgba(249,115,22,0.2)', alignItems: 'center' }}>
          <div className="grow"><div className="faint" style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1 }}>FROM</div><div style={{ fontWeight: 600, fontSize: 13 }}>{travelFrom}</div></div>
          <MdArrowForward size={22} color="rgba(249,115,22,0.6)" style={{ margin: '0 10px' }} />
          <div className="grow"><div className="faint" style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1 }}>TO</div><div style={{ fontWeight: 600, fontSize: 13 }}>{travelTo}</div></div>
        </div>
      )}

      {isTravel && (
        <div style={{ marginTop: 10, padding: '10px 12px', borderRadius: 10, background: 'var(--surface-variant)', border: '1px solid rgba(0,0,0,0.1)' }}>
          <div className="row" style={{ alignItems: 'center', gap: 6 }}>
            {travelModeIcon(travelMode)}
            <span style={{ fontSize: 12, fontWeight: 700 }}>{travelModeLabel(travelMode)} options</span>
            <span className="grow" />
            {updatingTravel && <Spinner size="sm" />}
          </div>
          {options.length === 0 && (
            <div className="faint" style={{ fontSize: 12, marginTop: 6 }}>
              {updatingTravel ? 'Calculating best travel options...' : status === 'unavailable' ? 'No live route options found for this segment yet.' : 'No travel recommendation yet.'}
            </div>
          )}
          {options.slice(0, 3).map((opt, i) => {
            const recommended = opt.sourceIndex === recIdx || opt.isRecommended === true
            const duration = formatDurationShort(num(opt.durationSeconds))
            const transfers = Math.trunc(num(opt.transferCount))
            const layovers = Math.trunc(num(opt.layoverCount))
            const dep = String(opt.departureTimeText ?? '').trim()
            const arr = String(opt.arrivalTimeText ?? '').trim()
            const transit = normalizePlanningMode(travelMode) === 'transit'
            return (
              <div key={i} style={{ marginTop: 6, padding: '8px 10px', borderRadius: 8, background: recommended ? 'rgba(74,173,232,0.1)' : '#fff', border: `1px solid ${recommended ? 'rgba(74,173,232,0.45)' : 'rgba(0,0,0,0.12)'}` }}>
                <div className="row" style={{ gap: 6 }}>
                  <div className="grow" style={{ fontSize: 12, fontWeight: 600 }}>{String(opt.summary ?? 'Route option')}</div>
                  {recommended && <span style={{ padding: '2px 6px', borderRadius: 999, background: 'rgba(74,173,232,0.12)', color: 'var(--primary)', fontSize: 10, fontWeight: 700 }}>Best</span>}
                </div>
                <div className="row wrap muted" style={{ gap: 8, marginTop: 3, fontSize: 11 }}>
                  {duration && <span>{duration}</span>}
                  {transit && <span>{transfers} transfer{transfers === 1 ? '' : 's'}</span>}
                  {transit && layovers > 0 && <span>{layovers} layover{layovers === 1 ? '' : 's'}</span>}
                  {(dep || arr) && <span>{dep || '?'} -&gt; {arr || '?'}</span>}
                </div>
              </div>
            )
          })}
        </div>
      )}

      <input
        className="plan-ghost-input" style={{ fontWeight: 600, fontSize: 14, marginTop: 8 }} placeholder="Day title…"
        value={String(day.title ?? '')} onChange={(e) => onPatch({ title: e.target.value })}
      />
      <textarea
        className="plan-ghost-input" style={{ fontSize: 13 }} rows={1} placeholder="Notes for this day…"
        value={String(day.notes ?? '')} onChange={(e) => onPatch({ notes: e.target.value })}
      />

      {activities.length > 0 && (
        <>
          <hr className="divider" style={{ margin: '6px 0' }} />
          {activities.map((a, i) => {
            const cat = String(a.category ?? 'Exploring')
            const color = TRAVEL_CATEGORIES[cat] ?? '#6366f1'
            return (
              <div key={i} onClick={() => onEdit(i, a)} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 10px', marginBottom: 6, borderRadius: 8, cursor: 'pointer', background: `${color}14`, border: `1px solid ${color}40` }}>
                <span style={{ fontSize: 18 }}>{CATEGORY_EMOJIS[cat] ?? '📌'}</span>
                <div className="grow" style={{ minWidth: 0 }}>
                  <div style={{ fontWeight: 600, fontSize: 13, color }}>{String(a.title ?? 'Activity')}</div>
                  {String(a.startTime ?? '') && <div className="faint" style={{ fontSize: 11 }}>{String(a.startTime)} – {String(a.endTime ?? '')}</div>}
                  {String(a.location ?? '') && <div className="faint ellipsis" style={{ fontSize: 11 }}>{String(a.location)}</div>}
                </div>
                <button className="icon-btn" title="Delete" onClick={(e) => { e.stopPropagation(); onDeleteActivity(i) }}><MdDeleteOutline size={18} color="var(--error)" /></button>
              </div>
            )
          })}
        </>
      )}
    </SoftCard>
  )
}

// ---- Tab ----------------------------------------------------------------------------------------

export interface ItineraryTabProps {
  days: Row[]
  tripData: Row
  selectedDay: number
  onSelectDay: (i: number) => void
  updatingTravel: boolean
  scrollToDay?: number | null
  onPickDates: () => void
  onEditStayDates: () => void
  onPatchDay: (dayIndex: number, patch: Row) => void
  onSaveActivity: (dayIndex: number, activityIndex: number | null, activity: Row) => void
  onDeleteActivity: (dayIndex: number, activityIndex: number) => void
  notify: (m: string) => void
}

export default function ItineraryTab(p: ItineraryTabProps) {
  const [dialog, setDialog] = useState<ActivityDialogState | null>(null)
  const [selectedPoint, setSelectedPoint] = useState<Row | null>(null)
  const detailRef = useRef<HTMLDivElement>(null)

  const waypoints = mapList(p.tripData.waypoints)
  const routePoints = useMemo(() => mapRoutePoints(waypoints), [p.tripData.waypoints]) // eslint-disable-line react-hooks/exhaustive-deps
  const activityPins = useMemo(() => mapItineraryActivityPins(p.days), [p.days])

  useEffect(() => {
    if (p.scrollToDay != null) detailRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }, [p.scrollToDay])

  const startStr = String(p.tripData.startDate ?? '')
  const endStr = String(p.tripData.endDate ?? '')

  if (!p.days.length) {
    return (
      <div className="center col gap-md" style={{ height: '100%', textAlign: 'center', padding: 24 }}>
        <MdDateRange size={48} className="faint" />
        <div style={{ fontSize: 16 }} className="muted">No itinerary yet</div>
        <div className="faint">Set trip dates to generate your day-by-day itinerary.</div>
        <Button variant="solid" icon={<MdDateRange size={18} />} onClick={p.onPickDates}>Set Trip Dates</Button>
      </div>
    )
  }

  const sel = Math.max(0, Math.min(p.selectedDay, p.days.length - 1))
  const selectedDayNum = p.days[sel].dayNumber ?? sel + 1
  const s = tryParseDate(startStr)
  const e = tryParseDate(endStr)
  const label = !startStr && !endStr
    ? 'Tap to set trip dates'
    : `${startStr ? formatDisplayDate(startStr) : '?'}  →  ${endStr ? formatDisplayDate(endStr) : '?'}${s && e ? `  (${Math.round((e.getTime() - s.getTime()) / 86400000) + 1} days)` : ''}`

  return (
    <div className="plan-scroll">
      <h2 className="t-display-s" style={{ margin: '12px 0 8px' }}>Trip Itinerary</h2>

      <div className="plan-date-row" onClick={p.onPickDates}>
        <MdDateRange size={20} color="var(--primary)" />
        <span className="grow" style={{ fontSize: 13, fontWeight: 600, color: startStr ? undefined : 'var(--text-3)' }}>{label}</span>
        <MdEditCalendar size={18} color="var(--primary)" />
      </div>
      <div style={{ textAlign: 'right' }}>
        <Button variant="text" size="sm" icon={<MdAltRoute size={16} />} disabled={waypoints.length === 0} onClick={p.onEditStayDates}>Edit Stay Dates Per Stop</Button>
      </div>

      {routePoints.length > 0 && (
        <SoftCard padding={10} radius={14} style={{ marginBottom: 8 }}>
          <div className="row" style={{ alignItems: 'center', gap: 8 }}>
            <MdOutlineMap size={18} />
            <b>Itinerary Map</b>
            <span className="grow" />
            <span className="faint" style={{ fontSize: 12 }}>{activityPins.length} activity pin{activityPins.length === 1 ? '' : 's'}</span>
          </div>
          <div className="plan-map-grid" style={{ marginTop: 10 }}>
            <div style={{ height: 230, borderRadius: 10, overflow: 'hidden' }}>
              <MapEmbed points={routePoints} secondaryPoints={activityPins} zoomControlsEnabled onPointTap={(pt) => setSelectedPoint({ ...pt })} />
            </div>
            <InsightCard days={p.days} point={selectedPoint} />
          </div>
        </SoftCard>
      )}

      <CalendarCard days={p.days} selected={sel} onSelect={p.onSelectDay} />

      <div ref={detailRef} className="row" style={{ alignItems: 'center', margin: '12px 0 8px' }}>
        <b style={{ fontSize: 15 }}>Day {String(selectedDayNum)} Details</b>
        <span className="grow" />
        <button className="icon-btn" title="Previous day" disabled={sel <= 0} onClick={() => p.onSelectDay(sel - 1)}><MdChevronLeft size={24} /></button>
        <button className="icon-btn" title="Next day" disabled={sel >= p.days.length - 1} onClick={() => p.onSelectDay(sel + 1)}><MdChevronRight size={24} /></button>
      </div>

      <DayCard
        day={p.days[sel]}
        dayIndex={sel}
        updatingTravel={p.updatingTravel}
        onPatch={(patch) => p.onPatchDay(sel, patch)}
        onAdd={() => setDialog({ dayIndex: sel, activityIndex: null, existing: null })}
        onEdit={(i, a) => setDialog({ dayIndex: sel, activityIndex: i, existing: a })}
        onDeleteActivity={(i) => p.onDeleteActivity(sel, i)}
      />

      {dialog && (
        <ActivityDialog
          state={dialog}
          notify={p.notify}
          onClose={() => setDialog(null)}
          onSave={(a) => { p.onSaveActivity(dialog.dayIndex, dialog.activityIndex, a); setDialog(null) }}
          onDelete={() => { if (dialog.activityIndex != null) p.onDeleteActivity(dialog.dayIndex, dialog.activityIndex); setDialog(null) }}
        />
      )}
    </div>
  )
}
