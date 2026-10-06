import { useEffect, useState, type ReactElement } from 'react'
import { createPortal } from 'react-dom'
import {
  MdAddCircleOutline, MdAdd, MdAutoAwesome, MdBed, MdClose, MdForest, MdHotel, MdMuseum,
  MdNightlife, MdOutlineAttractions, MdOutlineCameraAlt, MdOutlineRemoveCircleOutline, MdRestaurant, MdSpa,
  MdSupportAgent, MdTerrain,
} from 'react-icons/md'
import { Dialog } from './Dialog'
import { Button, SoftCard, cx } from './ui'
import { PremiumRequiredError, suggestAccommodations, suggestItinerary, type Suggestion } from '@/services/aiSuggestions'
import { usePremiumUpsell } from '@/hooks/usePremiumUpsell'
import { useFeedback } from '@/context/Feedback'

export type ActivityFinderMode = 'activities' | 'routeStop'
type ActivityType = 'adventure' | 'foodDrink' | 'cultureMuseum' | 'relaxation' | 'sightseeing' | 'nightlife' | 'attractions'
type RouteStayType = 'hotel' | 'hostel' | 'camping'
type BudgetTier = 'budget' | 'moderate' | 'luxury'
type TimeAvailable = 'oneToTwoHours' | 'halfDay' | 'fullDay'

const ACTIVITY_TYPES: { id: ActivityType; label: string; icon: ReactElement }[] = [
  { id: 'adventure', label: 'Adventure', icon: <MdTerrain size={18} /> },
  { id: 'foodDrink', label: 'Food & Drink', icon: <MdRestaurant size={18} /> },
  { id: 'cultureMuseum', label: 'Culture/Museum', icon: <MdMuseum size={18} /> },
  { id: 'relaxation', label: 'Relaxation', icon: <MdSpa size={18} /> },
  { id: 'sightseeing', label: 'Sightseeing', icon: <MdOutlineCameraAlt size={18} /> },
  { id: 'nightlife', label: 'Nightlife', icon: <MdNightlife size={18} /> },
  { id: 'attractions', label: 'Attractions', icon: <MdOutlineAttractions size={18} /> },
]
const STAY_TYPES: { id: RouteStayType; label: string; icon: ReactElement }[] = [
  { id: 'hotel', label: 'Hotel', icon: <MdHotel size={18} /> },
  { id: 'hostel', label: 'Hostel', icon: <MdBed size={18} /> },
  { id: 'camping', label: 'Camping', icon: <MdForest size={18} /> },
]
const BUDGETS: { id: BudgetTier; sym: string; label: string }[] = [
  { id: 'budget', sym: '$', label: 'Budget ($)' },
  { id: 'moderate', sym: '$$', label: 'Moderate ($$)' },
  { id: 'luxury', sym: '$$$', label: 'Luxury ($$$)' },
]
const TIMES: { id: TimeAvailable; label: string }[] = [
  { id: 'oneToTwoHours', label: '1-2 Hours' },
  { id: 'halfDay', label: 'Half Day (4 hrs)' },
  { id: 'fullDay', label: 'Full Day (8+ hrs)' },
]

function normalizeRouteMode(raw?: string | null): string {
  let v = (raw ?? '').trim().toLowerCase()
  if (['canoe', 'canoeing', 'portage'].includes(v)) v = 'portaging'
  if (v === 'walking') v = 'walk'
  if (['bicycling', 'biking', 'bikepacking'].includes(v)) v = 'bike'
  if (v === 'backpacking') v = 'hiking'
  return v || 'car'
}
const defaultStayForMode = (m?: string | null): RouteStayType => {
  switch (normalizeRouteMode(m)) {
    case 'hiking': case 'portaging': return 'camping'
    case 'bike': return 'hostel'
    default: return 'hotel'
  }
}
const defaultBudgetForMode = (m?: string | null): BudgetTier => {
  const n = normalizeRouteMode(m)
  return n === 'hiking' || n === 'portaging' ? 'budget' : 'moderate'
}
const modeRecommendation = (m?: string | null) => {
  switch (normalizeRouteMode(m)) {
    case 'hiking': return 'Camping is the default for hiking legs so suggestions stay trail-friendly.'
    case 'portaging': return 'Camping is the default for portage legs so suggestions bias toward backcountry-style stops.'
    case 'bike': return 'Hostels are the default for bike legs so quick route-stop suggestions stay lightweight.'
    default: return 'Hotel is the default for road-style legs, but you can switch the stay type any time.'
  }
}

export interface ActivityFinderProps {
  open: boolean
  onClose: () => void
  mode: ActivityFinderMode
  title?: string
  destinationName: string
  lat: number
  lon: number
  startDate: string
  endDate: string
  /** Number of itinerary days (activities mode). */
  dayCount?: number
  onAddToItinerary?: (dayIndex: number, suggestion: Suggestion) => Promise<void> | void
  /** Route-stop mode: add the suggestion as a stop on the trip. */
  onAddStop?: (suggestion: Suggestion) => Promise<void> | void
  routeFromName?: string
  routeToName?: string
  routeMode?: string
}

/** AI "find things to do" / "find a stay stop" bottom sheet. */
export default function ActivityFinderModal(p: ActivityFinderProps) {
  const upsell = usePremiumUpsell()
  const { toast } = useFeedback()
  const isRoute = p.mode === 'routeStop'
  const [type, setType] = useState<ActivityType>('adventure')
  const [stay, setStay] = useState<RouteStayType>(defaultStayForMode(p.routeMode))
  const [budget, setBudget] = useState<BudgetTier>(isRoute ? defaultBudgetForMode(p.routeMode) : 'moderate')
  const [groupSize, setGroupSize] = useState(1)
  const [time, setTime] = useState<TimeAvailable>('halfDay')
  const [haveCar, setHaveCar] = useState(isRoute && normalizeRouteMode(p.routeMode) === 'car')
  const [loading, setLoading] = useState(false)
  const [results, setResults] = useState<Suggestion[]>([])
  const [error, setError] = useState<string | null>(null)
  const [errorDialog, setErrorDialog] = useState<{ title: string; message: string; details?: string } | null>(null)
  const [pickDayFor, setPickDayFor] = useState<Suggestion | null>(null)
  const [pickedDay, setPickedDay] = useState(0)

  useEffect(() => {
    if (!p.open) return
    setResults([])
    setError(null)
    setStay(defaultStayForMode(p.routeMode))
    setBudget(isRoute ? defaultBudgetForMode(p.routeMode) : 'moderate')
    setHaveCar(isRoute && normalizeRouteMode(p.routeMode) === 'car')
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [p.open])

  if (!p.open) return null

  const generate = async () => {
    if (loading) return
    setLoading(true)
    setError(null)
    setResults([])
    const preferences: Record<string, any> = {
      mode: p.mode,
      activityType: type,
      budgetTier: budget,
      groupSize,
      timeAvailable: time,
      haveCar,
    }
    if (isRoute) {
      preferences.stayType = stay
      preferences.routeIntent = 'between_stops'
      preferences.scope = 'along_route'
      preferences.maxTravelMinutes = 30
      preferences.routeMode = normalizeRouteMode(p.routeMode)
      if (p.routeFromName?.trim()) preferences.routeFrom = p.routeFromName.trim()
      if (p.routeToName?.trim()) preferences.routeTo = p.routeToName.trim()
    }
    try {
      const args = { destinationName: p.destinationName, lat: p.lat, lon: p.lon, startDate: p.startDate, endDate: p.endDate, preferences }
      setResults(await (isRoute ? suggestAccommodations(args) : suggestItinerary(args)))
    } catch (e: any) {
      if (e instanceof PremiumRequiredError) {
        p.onClose()
        upsell()
      } else {
        const message = String(e?.message ?? e)
        setError(message)
        setErrorDialog({
          title: 'Unexpected error',
          message: 'Something went wrong while generating suggestions.',
          details: message,
        })
      }
    } finally {
      setLoading(false)
    }
  }

  const addSuggestion = async (s: Suggestion) => {
    if (isRoute) {
      await p.onAddStop?.(s)
      return
    }
    if ((p.dayCount ?? 0) <= 0) return
    setPickedDay(0)
    setPickDayFor(s)
  }

  return createPortal(
    <div className="sheet-backdrop" onMouseDown={(e) => e.target === e.currentTarget && p.onClose()}>
      <div className="sheet" role="dialog" aria-modal="true">
        <div className="sheet-title">
          <span>{p.title ?? 'Find Things to Do'}</span>
          <button className="icon-btn" title="Close" onClick={p.onClose}><MdClose size={22} /></button>
        </div>

        <div className="sheet-body">
          <SoftCard padding={14} radius={14}>
            <div className="sheet-section" style={{ marginTop: 0 }}>{isRoute ? 'Stay Type' : 'Activity Type'}</div>
            <div className="chip-row">
              {isRoute
                ? STAY_TYPES.map((t) => (
                    <button key={t.id} className={cx('chip teal', stay === t.id && 'selected')} onClick={() => setStay(t.id)}>
                      {t.icon} {t.label}
                    </button>
                  ))
                : ACTIVITY_TYPES.map((t) => (
                    <button key={t.id} className={cx('chip teal', type === t.id && 'selected')} onClick={() => setType(t.id)}>
                      {t.icon} {t.label}
                    </button>
                  ))}
            </div>
            {isRoute && <div className="muted" style={{ fontSize: 12, marginTop: 10 }}>{modeRecommendation(p.routeMode)}</div>}

            <div className="sheet-section">Budget</div>
            <div className="toggle-group">
              {BUDGETS.map((b) => (
                <button key={b.id} className={cx(budget === b.id && 'selected')} onClick={() => setBudget(b.id)}>{b.sym}</button>
              ))}
            </div>
            <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>{BUDGETS.find((b) => b.id === budget)?.label}</div>

            <div className="sheet-section">Group Size</div>
            <div className="row gap-sm" style={{ alignItems: 'center' }}>
              <button className="icon-btn" onClick={() => setGroupSize((g) => Math.max(1, g - 1))}><MdOutlineRemoveCircleOutline size={24} /></button>
              <span style={{ fontSize: 18, fontWeight: 800 }}>{groupSize}</span>
              <button className="icon-btn" onClick={() => setGroupSize((g) => Math.min(12, g + 1))}><MdAddCircleOutline size={24} /></button>
            </div>

            {!isRoute && (
              <>
                <div className="sheet-section">Time Available</div>
                <select className="select" value={time} onChange={(e) => setTime(e.target.value as TimeAvailable)}>
                  {TIMES.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}
                </select>
              </>
            )}

            <div className="sheet-section">Have a Car?</div>
            <div className="toggle-group">
              <button className={cx(!haveCar && 'selected')} onClick={() => setHaveCar(false)}>No</button>
              <button className={cx(haveCar && 'selected')} onClick={() => setHaveCar(true)}>Yes</button>
            </div>

            <div style={{ marginTop: 14 }}>
              <Button variant="solid" block loading={loading} onClick={generate} icon={<MdAutoAwesome size={18} />} style={{ background: '#00897b' }}>
                {loading ? 'Generating...' : 'Generate'}
              </Button>
            </div>
            {error && <div style={{ color: 'var(--error)', fontSize: 12, marginTop: 10 }}>{error}</div>}
          </SoftCard>

          {results.length > 0 && (
            <>
              <h3 className="t-title-l" style={{ margin: '14px 0 8px' }}>Suggestions</h3>
              {results.slice(0, 12).map((s, i) => {
                const name = String(s.name ?? '')
                const rating = Number(s.rating ?? 0)
                const price = Number(s.estimatedPrice ?? s.price ?? 0)
                const category = String(s.category ?? '').trim()
                const stayType = String(s.stayType ?? '').trim() || STAY_TYPES.find((t) => t.id === stay)!.label
                return (
                  <SoftCard key={i} padding={14} radius={14} style={{ marginBottom: 10 }}>
                    <div style={{ fontWeight: 900 }}>{name || 'Suggestion'}</div>
                    <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>{String(s.address ?? '')}</div>
                    <div className="row wrap gap-sm" style={{ marginTop: 10 }}>
                      {isRoute ? <span className="chip">{stayType}</span> : category && <span className="chip">{category}</span>}
                      <span className="chip">{rating > 0 ? `Rating: ${rating.toFixed(1)}` : 'Rating: —'}</span>
                      <span className="chip">{price > 0 ? `Est: ${price.toFixed(0)}` : 'Est: —'}</span>
                    </div>
                    <div style={{ textAlign: 'right', marginTop: 10 }}>
                      <Button variant="text" size="sm" icon={<MdAdd size={18} />} style={{ color: '#00897b' }} onClick={() => addSuggestion(s)}>
                        {isRoute ? 'Add Stop to Trip' : 'Add to Itinerary'}
                      </Button>
                    </div>
                  </SoftCard>
                )
              })}
            </>
          )}
        </div>
      </div>

      <Dialog
        open={!!errorDialog}
        onClose={() => setErrorDialog(null)}
        title={<span className="row gap-sm" style={{ alignItems: 'center' }}><MdSupportAgent color="#00897b" /> Trypr Travel Agent</span>}
        actions={
          <>
            {errorDialog?.details && (
              <Button variant="text" onClick={() => { navigator.clipboard?.writeText(errorDialog.details!); toast('Copied error details') }}>Copy details</Button>
            )}
            <Button variant="text" onClick={() => setErrorDialog(null)}>Close</Button>
            <Button variant="solid" onClick={() => { setErrorDialog(null); generate() }}>Retry</Button>
          </>
        }
      >
        <div style={{ fontWeight: 800, marginBottom: 8 }}>{errorDialog?.title}</div>
        <div>{errorDialog?.message}</div>
        {errorDialog?.details && (
          <pre style={{ marginTop: 12, padding: 10, borderRadius: 10, background: 'rgba(0,0,0,0.04)', fontSize: 12, whiteSpace: 'pre-wrap' }}>{errorDialog.details}</pre>
        )}
      </Dialog>

      <Dialog
        open={!!pickDayFor}
        onClose={() => setPickDayFor(null)}
        title="Add to which day?"
        actions={
          <>
            <Button variant="text" onClick={() => setPickDayFor(null)}>Cancel</Button>
            <Button
              variant="solid"
              onClick={async () => {
                const s = pickDayFor!
                setPickDayFor(null)
                await p.onAddToItinerary?.(pickedDay, s)
              }}
            >
              Add
            </Button>
          </>
        }
      >
        <select className="select" value={pickedDay} onChange={(e) => setPickedDay(Number(e.target.value))}>
          {Array.from({ length: p.dayCount ?? 0 }, (_, i) => <option key={i} value={i}>Day {i + 1}</option>)}
        </select>
      </Dialog>
    </div>,
    document.body,
  )
}
