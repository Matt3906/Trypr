import { useCallback, useEffect, useRef, useState } from 'react'
import { doc, getDoc, onSnapshot, updateDoc } from 'firebase/firestore'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { MdAccountBalanceWallet, MdArrowBack, MdCalendarMonth, MdChecklist, MdFolderOpen, MdOutlineStickyNote2, MdSave } from 'react-icons/md'
import type { IconType } from 'react-icons'
import { db } from '@/firebase'
import { useAuth } from '@/context/Auth'
import { useFeedback } from '@/context/Feedback'
import { Button, Spinner } from '@/components/ui'
import { encodeBudgetPeople, parseBudgetPeople } from '@/models/budgetPerson'
import { getRouteOptions } from '@/services/routeOptions'
import { mapList } from '@/lib/tripDetail'
import {
  addDaysTo, daysBetween, defaultChecklist, jsonValueEquals, loadOrGenerateItinerary, newId, normalizeItineraryDays, normalizePlanningMode,
  normalizedBudgetItems, parseBudgetFinalSplitCount, resolveWaypointIndexForDay, segmentIndexForTravel, segmentTransportModeFor, stripDate,
  travelOptionScore, tryParseDate, upsertAutoTravelActivity, clearTravelRecommendationFields, waypointCoords, waypointCountsAsStay, ymdOf, type Row,
} from '@/lib/planning'
import ItineraryTab, { StayDatesDialog } from './planning/ItineraryTab'
import NotesTab, { newNote } from './planning/NotesTab'
import BudgetTab, { type BudgetState } from './planning/BudgetTab'
import ChecklistsTab from './planning/ChecklistsTab'
import DocumentsTab from './planning/DocumentsTab'
import { DateRangeDialog } from './tripBuilder/dialogs'

const TABS: { label: string; icon: IconType }[] = [
  { label: 'Itinerary', icon: MdCalendarMonth },
  { label: 'Notes', icon: MdOutlineStickyNote2 },
  { label: 'Budget', icon: MdAccountBalanceWallet },
  { label: 'Checklists', icon: MdChecklist },
  { label: 'Documents', icon: MdFolderOpen },
]

const ensureNoteIds = (notes: Row[]) => notes.map((n) => (String(n.id ?? '').trim() ? n : { ...n, id: newId() }))
const emptyBudget = (): BudgetState => ({ currency: 'USD', items: [], people: [], finalSplitByCount: 0 })

function budgetFromTrip(data: Row): BudgetState {
  const b = data.tripBudget
  if (!b || typeof b !== 'object') return emptyBudget()
  return {
    currency: String(b.currency ?? 'USD'),
    items: mapList(b.items),
    people: parseBudgetPeople(b.people),
    finalSplitByCount: parseBudgetFinalSplitCount(b.finalSplitByCount),
  }
}

const useIsWide = (min = 800) => {
  const [wide, setWide] = useState(() => window.innerWidth >= min)
  useEffect(() => {
    const on = () => setWide(window.innerWidth >= min)
    window.addEventListener('resize', on)
    return () => window.removeEventListener('resize', on)
  }, [min])
  return wide
}

export interface TripPlanningProps {
  tripId: string
  tripRefPath: string
  tripData: Row
  initialTab?: number
  focusDayIndex?: number | null
}

/** Trip planning workspace: itinerary, notes, budget, checklists and documents on the trip doc. */
export default function TripPlanningScreen({ tripId, tripRefPath, tripData: initialTripData, initialTab = 0, focusDayIndex = null }: TripPlanningProps) {
  const navigate = useNavigate()
  const { toast } = useFeedback()
  const isWide = useIsWide()

  const [selectedTab, setSelectedTab] = useState(Math.max(0, Math.min(initialTab, TABS.length - 1)))
  const [saving, setSaving] = useState(false)
  const [tripData, setTripDataState] = useState<Row>({ ...initialTripData })
  const [days, setDaysState] = useState<Row[]>([])
  const [notes, setNotesState] = useState<Row[]>([])
  const [budget, setBudgetState] = useState<BudgetState>(emptyBudget())
  const [checklists, setChecklistsState] = useState<Row[]>([])
  const [documents, setDocumentsState] = useState<Row[]>([])
  const [selectedDay, setSelectedDay] = useState(focusDayIndex ?? 0)
  const [selectedNote, setSelectedNote] = useState<number | null>(null)
  const [updatingTravel, setUpdatingTravel] = useState(false)
  const [scrollToDay, setScrollToDay] = useState<number | null>(focusDayIndex)
  const [dialog, setDialog] = useState<'dates' | 'stays' | null>(null)

  // Mirrors of state so timers/subscriptions always read the latest values.
  const tripRef = useRef(tripData)
  const daysRef = useRef(days)
  const notesRef = useRef(notes)
  const budgetRef = useRef(budget)
  const checklistsRef = useRef(checklists)
  const documentsRef = useRef(documents)
  const setTripData = (v: Row) => { tripRef.current = v; setTripDataState(v) }
  const setDays = (v: Row[]) => { daysRef.current = v; setDaysState(v) }
  const setNotes = (v: Row[]) => { notesRef.current = v; setNotesState(v) }
  const setBudget = (v: BudgetState) => { budgetRef.current = v; setBudgetState(v) }
  const setChecklists = (v: Row[]) => { checklistsRef.current = v; setChecklistsState(v) }
  const setDocuments = (v: Row[]) => { documentsRef.current = v; setDocumentsState(v) }

  const savingRef = useRef(false)
  const autoSaveInFlight = useRef(false)
  const lastSigRef = useRef('')
  const travelRunId = useRef(0)
  const mounted = useRef(true)

  const resolvedSplitCount = (b: BudgetState) => (b.finalSplitByCount > 0 ? b.finalSplitByCount : b.people.length > 0 ? b.people.length : 1)

  const planningPayload = (): Row => ({
    tripItinerary: daysRef.current,
    tripNotes: notesRef.current,
    tripBudget: {
      currency: budgetRef.current.currency,
      items: normalizedBudgetItems(budgetRef.current.items, budgetRef.current.people),
      people: encodeBudgetPeople(budgetRef.current.people),
      finalSplitByCount: resolvedSplitCount(budgetRef.current),
    },
    tripChecklists: checklistsRef.current,
    tripDocuments: documentsRef.current,
    startDate: String(tripRef.current.startDate ?? ''),
    endDate: String(tripRef.current.endDate ?? ''),
    waypoints: mapList(tripRef.current.waypoints),
  })
  const signature = () => {
    try {
      return JSON.stringify(planningPayload())
    } catch {
      return String(Math.random())
    }
  }

  // ---- travel recommendations ---------------------------------------------------------------
  const refreshTravelRecommendations = useCallback(async (persist: boolean) => {
    const runId = ++travelRunId.current
    if (!mounted.current) return
    setUpdatingTravel(true)
    const nextDays = daysRef.current.map((d) => ({ ...d }))
    const waypoints = mapList(tripRef.current.waypoints)
    let changed = false

    for (let i = 0; i < nextDays.length; i++) {
      const day = nextDays[i]
      if (day.isTravel !== true || i + 1 >= nextDays.length) {
        if (clearTravelRecommendationFields(day)) changed = true
        continue
      }
      const nextDay = nextDays[i + 1]
      const fromIndex = resolveWaypointIndexForDay(day, waypoints)
      const toIndex = resolveWaypointIndexForDay(nextDay, waypoints)
      const from = waypointCoords(waypoints, fromIndex)
      const to = waypointCoords(waypoints, toIndex)
      const mode = segmentTransportModeFor(tripRef.current, segmentIndexForTravel(fromIndex, toIndex, waypoints.length))

      if (String(day.travelMode ?? '') !== mode) {
        day.travelMode = mode
        changed = true
      }

      const markUnavailable = () => {
        let local = false
        if (String(day.travelRecommendationStatus ?? '') !== 'unavailable') { day.travelRecommendationStatus = 'unavailable'; local = true }
        for (const k of ['travelOptions', 'recommendedTravel', 'recommendedTravelOptionIndex']) if (day[k] != null) { delete day[k]; local = true }
        if (upsertAutoTravelActivity(day, mode, null)) local = true
        if (local) changed = true
      }

      if (!from || !to) {
        markUnavailable()
        continue
      }

      const date = tryParseDate(String(day.date ?? ''))
      const options = await getRouteOptions({
        originLat: from.lat, originLng: from.lon, destLat: to.lat, destLng: to.lon, mode,
        departureTime: date ? new Date(date.getFullYear(), date.getMonth(), date.getDate(), 8) : undefined,
        avoidHighways: normalizePlanningMode(mode) === 'biking',
      })
      if (!mounted.current || runId !== travelRunId.current) return

      if (!options.length) {
        const prevOptions = mapList(day.travelOptions)
        const prevRec = day.recommendedTravel && typeof day.recommendedTravel === 'object' ? { ...day.recommendedTravel } : null
        if (prevOptions.length && prevRec) {
          let local = false
          if (String(day.travelRecommendationStatus ?? '') !== 'stale') { day.travelRecommendationStatus = 'stale'; local = true }
          if (upsertAutoTravelActivity(day, mode, prevRec)) local = true
          if (local) changed = true
          continue
        }
        markUnavailable()
        continue
      }

      const scored = options.map((o, idx) => ({ sourceIndex: idx, score: travelOptionScore(o), option: o })).sort((a, b) => a.score - b.score)
      const serialized: Row[] = scored.map((s, rank) => ({ ...s.option, sourceIndex: s.sourceIndex, score: s.score, rank: rank + 1, isRecommended: rank === 0 }))
      const best = { ...serialized[0] }
      const bestSource = Number(best.sourceIndex)

      let local = false
      if (!jsonValueEquals(day.travelOptions, serialized)) { day.travelOptions = serialized; local = true }
      if (day.recommendedTravelOptionIndex !== bestSource) { day.recommendedTravelOptionIndex = bestSource; local = true }
      if (!jsonValueEquals(day.recommendedTravel, best)) { day.recommendedTravel = best; local = true }
      if (String(day.travelRecommendationStatus ?? '') !== 'ready') { day.travelRecommendationStatus = 'ready'; local = true }
      if (upsertAutoTravelActivity(day, mode, best)) local = true
      if (local) {
        day.travelRecommendationUpdatedAt = new Date().toISOString()
        changed = true
      }
    }

    if (!mounted.current || runId !== travelRunId.current) return
    if (changed) {
      const normalized = normalizeItineraryDays(nextDays)
      setDays(normalized)
      setSelectedDay((s) => (normalized.length ? Math.max(0, Math.min(s, normalized.length - 1)) : 0))
      setUpdatingTravel(false)
      if (persist) {
        try {
          await updateDoc(doc(db, tripRefPath), JSON.parse(JSON.stringify({ tripItinerary: normalized })))
        } catch {
          /* non-fatal */
        }
      }
      return
    }
    setUpdatingTravel(false)
  }, [tripRefPath])

  // ---- load planning data from a trip document ----------------------------------------------
  const applyPlanning = useCallback((data: Row) => {
    const itinerary = normalizeItineraryDays(loadOrGenerateItinerary(data))
    setDays(itinerary)
    const n = ensureNoteIds(mapList(data.tripNotes))
    setNotes(n)
    setSelectedNote((s) => (n.length === 0 ? null : s != null ? Math.max(0, Math.min(s, n.length - 1)) : null))
    setBudget(budgetFromTrip(data))
    const cl = mapList(data.tripChecklists)
    setChecklists(cl.length ? cl : [defaultChecklist()])
    setDocuments(mapList(data.tripDocuments))
    setSelectedDay((s) => (itinerary.length ? Math.max(0, Math.min(s, itinerary.length - 1)) : 0))
    void refreshTravelRecommendations(false)
    lastSigRef.current = signature()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refreshTravelRecommendations])

  // ---- lifecycle ------------------------------------------------------------------------------
  useEffect(() => {
    mounted.current = true
    tripRef.current = { ...initialTripData }
    applyPlanning(tripRef.current)

    const unsub = onSnapshot(doc(db, tripRefPath), (snap) => {
      if (!snap.exists() || !mounted.current) return
      const remote = snap.data() ?? {}
      const prevMode = String(tripRef.current.transportMode ?? '')
      const prevSegSig = JSON.stringify(tripRef.current.segmentTransportModes ?? [])
      setTripData({ ...remote })
      const remoteItin = remote.tripItinerary
      if (Array.isArray(remoteItin) && remoteItin.length !== daysRef.current.length) {
        applyPlanning(remote)
      } else if (String(remote.transportMode ?? '') !== prevMode || JSON.stringify(remote.segmentTransportModes ?? []) !== prevSegSig) {
        void refreshTravelRecommendations(false)
      }
    }, () => { /* offline / permission errors are non-fatal here */ })

    const timer = setInterval(() => {
      if (savingRef.current || autoSaveInFlight.current) return
      if (signature() === lastSigRef.current) return
      void persistPlanning(false)
    }, 6000)

    return () => {
      mounted.current = false
      travelRunId.current++
      unsub()
      clearInterval(timer)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tripRefPath])

  useEffect(() => {
    if (focusDayIndex == null) return
    const id = setTimeout(() => setScrollToDay(null), 800)
    return () => clearTimeout(id)
  }, [focusDayIndex])

  // ---- persistence -----------------------------------------------------------------------------
  const persistPlanning = async (showFeedback: boolean): Promise<boolean> => {
    if (showFeedback) {
      if (savingRef.current) return false
      savingRef.current = true
      setSaving(true)
    } else {
      if (autoSaveInFlight.current || savingRef.current) return false
      autoSaveInFlight.current = true
    }
    try {
      await updateDoc(doc(db, tripRefPath), JSON.parse(JSON.stringify(planningPayload())))
      lastSigRef.current = signature()
      if (showFeedback) toast('Trip plan saved ✓')
      return true
    } catch (e: any) {
      if (showFeedback) toast(`Save failed: ${e?.message ?? e}`)
      return false
    } finally {
      if (showFeedback) {
        savingRef.current = false
        if (mounted.current) setSaving(false)
      } else {
        autoSaveInFlight.current = false
      }
    }
  }

  // ---- itinerary actions -----------------------------------------------------------------------
  const patchDay = (dayIndex: number, patch: Row) => setDays(daysRef.current.map((d, i) => (i === dayIndex ? { ...d, ...patch } : d)))

  const saveActivity = (dayIndex: number, activityIndex: number | null, activity: Row) => {
    const acts = mapList(daysRef.current[dayIndex]?.activities)
    if (activityIndex != null && activityIndex < acts.length) acts[activityIndex] = activity
    else acts.push(activity)
    patchDay(dayIndex, { activities: normalizeItineraryDays([{ activities: acts }])[0].activities })
  }
  const deleteActivity = (dayIndex: number, activityIndex: number) => {
    const acts = mapList(daysRef.current[dayIndex]?.activities)
    if (activityIndex < acts.length) acts.splice(activityIndex, 1)
    patchDay(dayIndex, { activities: acts })
  }

  const regenerateItinerary = async (nextTrip: Row) => {
    setTripData(nextTrip)
    const regenerated = normalizeItineraryDays(loadOrGenerateItinerary(nextTrip, { forceRegenerate: true, carryFromDays: daysRef.current }))
    setDays(regenerated)
    setSelectedDay((s) => (regenerated.length ? Math.max(0, Math.min(s, regenerated.length - 1)) : 0))
    await refreshTravelRecommendations(false)
    await persistPlanning(true)
  }

  const applyTripDates = async (range: { start: Date; end: Date }) => {
    setDialog(null)
    await regenerateItinerary({ ...tripRef.current, startDate: ymdOf(range.start), endDate: ymdOf(range.end) })
  }

  const stays = (() => {
    const wps = mapList(tripData.waypoints)
    const tripStart = tryParseDate(String(tripData.startDate ?? ''))
    if (!tripStart) return []
    const out: { index: number; name: string; start: Date; end: Date }[] = []
    wps.forEach((wp, i) => {
      if (!waypointCountsAsStay(wps, i)) return
      const start = stripDate(tryParseDate(String(wp.startDate ?? '')) ?? tripStart)
      let end = stripDate(tryParseDate(String(wp.endDate ?? '')) ?? start)
      if (end < start) end = start
      out.push({ index: i, name: String(wp.name ?? `Stop ${out.length + 1}`), start, end })
    })
    return out
  })()

  const openStayDates = () => {
    const tripStart = tryParseDate(String(tripData.startDate ?? ''))
    const tripEnd = tryParseDate(String(tripData.endDate ?? ''))
    if (!tripStart || !tripEnd) return toast('Set trip dates first.')
    if (!stays.length) return toast('No stay destinations to edit yet.')
    setDialog('stays')
  }

  const applyStayDates = async (updated: { index: number; start: Date; end: Date }[]) => {
    setDialog(null)
    const wps = mapList(tripRef.current.waypoints)
    for (const u of updated) {
      wps[u.index] = { ...wps[u.index], startDate: ymdOf(u.start), endDate: ymdOf(u.end), nights: daysBetween(u.end, u.start) + 1 }
    }
    await regenerateItinerary({
      ...tripRef.current,
      waypoints: wps,
      startDate: String(wps[0]?.startDate ?? tripRef.current.startDate ?? ''),
      endDate: String(wps[wps.length - 1]?.endDate ?? tripRef.current.endDate ?? ''),
    })
  }

  // ---- render ----------------------------------------------------------------------------------
  const tripName = String(tripData.name ?? initialTripData.name ?? 'Trip Plan')
  const tripStartDate = tryParseDate(String(tripData.startDate ?? ''))
  const tripEndDate = tryParseDate(String(tripData.endDate ?? ''))
  const now = stripDate(new Date())

  const content = (() => {
    switch (selectedTab) {
      case 1:
        return (
          <NotesTab
            tripId={tripId} notes={notes} selectedIndex={selectedNote} isWide={isWide} notify={toast}
            onSelect={setSelectedNote}
            onAdd={() => { const n = [...notesRef.current, newNote()]; setNotes(n); setSelectedNote(n.length - 1) }}
            onDelete={(i) => {
              setNotes(notesRef.current.filter((_n, k) => k !== i))
              setSelectedNote((s) => (s == null ? null : s === i ? null : s > i ? s - 1 : s))
            }}
            onPatch={(i, patch) => setNotes(notesRef.current.map((n, k) => (k === i ? { ...n, ...patch } : n)))}
          />
        )
      case 2:
        return <BudgetTab budget={budget} resolvedSplitCount={resolvedSplitCount(budget)} onChange={setBudget} notify={toast} />
      case 3:
        return <ChecklistsTab checklists={checklists} onChange={setChecklists} />
      case 4:
        return <DocumentsTab tripId={tripId} documents={documents} onChange={setDocuments} notify={toast} />
      default:
        return (
          <ItineraryTab
            days={days} tripData={tripData} selectedDay={selectedDay} onSelectDay={setSelectedDay} updatingTravel={updatingTravel}
            scrollToDay={scrollToDay} notify={toast}
            onPickDates={() => setDialog('dates')} onEditStayDates={openStayDates}
            onPatchDay={patchDay} onSaveActivity={saveActivity} onDeleteActivity={deleteActivity}
          />
        )
    }
  })()

  return (
    <div className="plan-screen" style={{ flexDirection: isWide ? 'row' : 'column' }}>
      {isWide ? (
        <aside className="plan-sidebar">
          <div className="row" style={{ alignItems: 'center', gap: 4, padding: '0 12px', marginBottom: 20 }}>
            <button className="icon-btn" title="Back to trip" onClick={() => navigate(-1)}><MdArrowBack size={22} /></button>
            <span className="grow" style={{ fontWeight: 700, fontSize: 14, overflow: 'hidden', display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical' }}>{tripName}</span>
          </div>
          {TABS.map((t, i) => (
            <button key={t.label} className={`plan-nav-item${selectedTab === i ? ' selected' : ''}`} onClick={() => setSelectedTab(i)}>
              <t.icon size={20} /> {t.label}
            </button>
          ))}
          <div className="grow" />
          <div style={{ padding: 12 }}>
            <Button variant="primary" block loading={saving} icon={<MdSave size={18} />} onClick={() => void persistPlanning(true)}>{saving ? 'Saving…' : 'Save All'}</Button>
          </div>
        </aside>
      ) : (
        <div className="plan-topbar">
          <button className="icon-btn" title="Back to trip" onClick={() => navigate(-1)}><MdArrowBack size={22} /></button>
          <span className="grow ellipsis" style={{ fontWeight: 600, fontSize: 16 }}>{tripName}</span>
          {saving ? <Spinner size="sm" /> : <button className="icon-btn" title="Save all" onClick={() => void persistPlanning(true)}><MdSave size={22} /></button>}
        </div>
      )}

      <main className="plan-main">
        <div className="plan-content">{content}</div>
        {!isWide && (
          <nav className="plan-bottom-nav">
            {TABS.map((t, i) => (
              <button key={t.label} className={selectedTab === i ? 'selected' : ''} onClick={() => setSelectedTab(i)}>
                <t.icon size={22} /> {t.label}
              </button>
            ))}
          </nav>
        )}
      </main>

      {dialog === 'dates' && (
        <DateRangeDialog
          initialStart={tripStartDate ?? now}
          initialEnd={tripEndDate ?? addDaysTo(now, 3)}
          onResult={(r) => (r ? void applyTripDates(r) : setDialog(null))}
        />
      )}
      {dialog === 'stays' && tripStartDate && tripEndDate && (
        <StayDatesDialog tripStart={stripDate(tripStartDate)} tripEnd={stripDate(tripEndDate)} stays={stays} onClose={() => setDialog(null)} onApply={(u) => void applyStayDates(u)} />
      )}
    </div>
  )
}

/** Route wrapper for `/plan?ref=users/{uid}/trips/{id}&tripId=…&tab=…&day=…`. */
export function TripPlanningRoute() {
  const [params] = useSearchParams()
  const navigate = useNavigate()
  const { user, loading } = useAuth()
  const ref = params.get('ref') ?? ''
  const tripId = params.get('tripId') ?? ref.split('/').pop() ?? ''
  const tab = parseInt(params.get('tab') ?? '0', 10) || 0
  const dayParam = params.get('day')
  const day = dayParam != null && dayParam !== '' && !Number.isNaN(parseInt(dayParam, 10)) ? parseInt(dayParam, 10) : null

  const [data, setData] = useState<Row | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (loading) return
    if (!user) return setError('sign-in')
    if (!ref) return setError('Missing trip reference')
    getDoc(doc(db, ref))
      .then((s) => (s.exists() ? setData(s.data()) : setError('Trip not found')))
      .catch((e) => setError(e?.message ?? 'Failed to load trip'))
  }, [loading, user, ref])

  if (data) return <TripPlanningScreen tripId={tripId} tripRefPath={ref} tripData={data} initialTab={tab} focusDayIndex={day} />
  if (error) {
    return (
      <div className="center col gap-md" style={{ height: '100vh' }}>
        <p>{error === 'sign-in' ? 'Sign in to plan this trip.' : error}</p>
        <Button onClick={() => navigate(error === 'sign-in' ? '/sign-in' : '/my-trips')}>{error === 'sign-in' ? 'Sign in' : 'Back to My Trips'}</Button>
      </div>
    )
  }
  return <div className="center" style={{ height: '100vh' }}><Spinner /></div>
}
