import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { addDoc, collection, serverTimestamp, setDoc, type DocumentReference } from 'firebase/firestore'
import { useNavigate } from 'react-router-dom'
import {
  MdAdd, MdAltRoute, MdAutoAwesome, MdCheck, MdDateRange, MdDeleteOutline, MdOutlineBackpack, MdSave, MdSchool, MdSearch,
  MdShare, MdTitle, MdTouchApp, MdTune,
} from 'react-icons/md'
import { auth, db } from '@/firebase'
import { useAuth } from '@/context/Auth'
import { useFeedback } from '@/context/Feedback'
import TopTaskbar from '@/components/TopTaskbar'
import MapEmbed from '@/components/map/MapEmbed'
import Globe3DEmbed from '@/components/Globe3DEmbed'
import TransitLegTabsCard from '@/components/TransitLegTabsCard'
import ShareTripDialog from '@/components/ShareTripDialog'
import ActivityFinderModal from '@/components/ActivityFinderModal'
import { Button, Spinner, cx } from '@/components/ui'
import { formatLocationDisplay } from '@/lib/locationDisplay'
import { buildRouteCacheKey, readRouteSegmentDetails, simplifyRouteGeometry, type AnyMap } from '@/lib/routeCache'
import {
  inferTripDifficultyLabel, inferTripRequiredSkills, isAdventureTripType, normalizeTripExperienceLevel, normalizeTripType,
  tripExperienceDisplayLabel, tripTypeBadgeLabel, tripTypeDisplayLabel, tripTypeEmoji,
} from '@/models/tripModel'
import { reverseNominatim, searchNominatim } from '@/services/geocode'
import {
  SAMPLE_LOOKUP, addDays, adventureDifficultyForDistance, adventureEstimatedTime, adventureWarning,
  availableTransportOptionsForTripType, coerceCoord, containsHikingKeyword, defaultRoutingTypeForMode, defaultTransportModeForTripType,
  diffDays, filterHikingResults, filterPortageAccessResults, guideSteps, haversineKm, hikingBiasedQuery, isAdventureMode,
  looksLikePortageAccessResult, modeSelectionHelperText, normalizeBuilderMode, normalizeBuilderRoutingType,
  portageAccessBiasedQuery, primaryRoutingLabelForMode, rawLocationFromResult, routingDescription, searchResultCategory, stripTime,
  tripNameValidationMessage, tripTypeGuide, tripTypeSearchHint, waypointValidationMessage, ymd,
  type SearchResult, type Waypoint,
} from '@/lib/tripBuilder'
import { AccessPointDialog, DateRangeDialog, DestinationDialog, RouteOptionsDialog, TripBasicsDialog, type DestinationDraft, type TripBasics } from './tripBuilder/dialogs'

interface Plan {
  waypoints: Waypoint[]
  segModes: string[]
  segRouting: string[]
  routeVia: AnyMap[]
  transportMode: string
  activeSeg: number
}

type Dlg =
  | { kind: 'basics'; props: Parameters<typeof TripBasicsDialog>[0] }
  | { kind: 'dates'; props: Parameters<typeof DateRangeDialog>[0] }
  | { kind: 'dest'; props: Parameters<typeof DestinationDialog>[0] }
  | { kind: 'access'; props: Parameters<typeof AccessPointDialog>[0] }
  | { kind: 'route'; props: Parameters<typeof RouteOptionsDialog>[0] }

interface FinderState {
  title: string
  destinationName: string
  lat: number
  lon: number
  routeFromName: string
  routeToName?: string
  routeMode: string
  onAddStop: (s: Record<string, any>) => Promise<void>
}

const clampInt = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v))

function useIsCompact(maxWidth = 980) {
  const [compact, setCompact] = useState(() => (typeof window !== 'undefined' ? window.innerWidth < maxWidth : false))
  useEffect(() => {
    const on = () => setCompact(window.innerWidth < maxWidth)
    window.addEventListener('resize', on)
    return () => window.removeEventListener('resize', on)
  }, [maxWidth])
  return compact
}

export default function TripBuilderScreen() {
  const navigate = useNavigate()
  const { user } = useAuth()
  const { toast } = useFeedback()
  const compact = useIsCompact()

  // ---- trip basics --------------------------------------------------------------------------
  const [tripName, setTripName] = useState('')
  const [range, setRange] = useState<{ start: Date; end: Date } | null>(null)
  const [tripType, setTripType] = useState('road')
  const [experience, setExperience] = useState('beginner')
  const [renamingName, setRenamingName] = useState(false)

  // ---- plan (waypoints + per-leg config) ------------------------------------------------------
  const [plan, setPlanState] = useState<Plan>({ waypoints: [], segModes: [], segRouting: [], routeVia: [], transportMode: 'car', activeSeg: 0 })
  const planRef = useRef(plan)
  const setPlan = useCallback((next: Plan | ((p: Plan) => Plan)) => {
    const value = typeof next === 'function' ? (next as (p: Plan) => Plan)(planRef.current) : next
    planRef.current = value
    setPlanState(value)
  }, [])

  // ---- computed route state -------------------------------------------------------------------
  const [routeInstructions, setRouteInstructions] = useState<string[]>([])
  const [routeGeometry, setRouteGeometry] = useState<AnyMap[]>([])
  const [routeSegmentDetails, setRouteSegmentDetails] = useState<AnyMap[]>([])
  const [distanceKm, setDistanceKm] = useState<number | null>(null)
  const [durationMin, setDurationMin] = useState<number | null>(null)
  const [transitArrivalStop, setTransitArrivalStop] = useState<AnyMap | null>(null)
  const [focusedStep, setFocusedStep] = useState<AnyMap | null>(null)
  const focusRequestRef = useRef(0)
  const computedRef = useRef({ routeInstructions, routeGeometry, routeSegmentDetails, durationMin, transitArrivalStop })
  computedRef.current = { routeInstructions, routeGeometry, routeSegmentDetails, durationMin, transitArrivalStop }

  // ---- ui state -------------------------------------------------------------------------------
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<SearchResult[]>([])
  const [adjustRoute, setAdjustRoute] = useState(false)
  const [mapMode, setMapMode] = useState<'2d' | '3d'>('2d')
  const [saving, setSaving] = useState(false)
  const [savedRefPath, setSavedRefPath] = useState<string | null>(null)
  const [shareOpen, setShareOpen] = useState(false)
  const [dlg, setDlg] = useState<Dlg | null>(null)
  const dlgOpenRef = useRef(false)
  const [finder, setFinder] = useState<FinderState | null>(null)

  const savedRef = useRef<DocumentReference | null>(null)
  const lastSigRef = useRef('')
  const savingRef = useRef(false)
  const autoSaveInFlight = useRef(false)
  const mapTapLockUntil = useRef(0)
  const didOnboard = useRef(false)

  const blockMapTapFor = (ms = 900) => {
    mapTapLockUntil.current = Math.max(mapTapLockUntil.current, Date.now() + clampInt(ms, 0, 60000))
  }
  const isMapTapBlocked = () => dlgOpenRef.current || Date.now() < mapTapLockUntil.current

  // ---- derived -------------------------------------------------------------------------------
  const { waypoints, segModes, segRouting, routeVia, transportMode } = plan
  const normalizedTripType = normalizeTripType(tripType, { transportMode, segmentTransportModes: segModes })
  const isPortage = normalizedTripType === 'portage'
  const isMixed = normalizedTripType === 'mixed'
  const isAdventure = isAdventureTripType(normalizedTripType)
  const allowsCustomDrops = !isPortage
  const isPortageAccessStage = isPortage && waypoints.length === 0

  const normalizeExperience = (raw?: string) => normalizeTripExperienceLevel(raw ?? experience) || 'beginner'

  const totalNights = range ? Math.max(0, diffDays(range.end, range.start)) : 0
  const totalDays = range ? diffDays(range.end, range.start) + 1 : 0
  const segCount = Math.max(0, waypoints.length - 1)
  const selectedSeg: number | null = segCount <= 0 ? null : plan.activeSeg < 0 || plan.activeSeg >= segCount ? 0 : plan.activeSeg

  const segModeAt = (i: number, p: Plan = planRef.current) => {
    if (i < 0 || i >= p.segModes.length) return normalizeBuilderMode(p.transportMode)
    return normalizeBuilderMode(p.segModes[i])
  }
  const segRoutingAt = (i: number, p: Plan = planRef.current) => {
    const mode = segModeAt(i, p)
    if (i < 0 || i >= p.segRouting.length) return defaultRoutingTypeForMode(mode)
    return normalizeBuilderRoutingType(p.segRouting[i], mode)
  }

  const countsTowardDays = (i: number, wps = waypoints) => i >= 0 && i < wps.length && wps[i].isStop
  const effectiveNights = (i: number, wps = waypoints) => (!countsTowardDays(i, wps) ? 0 : wps[i].nights <= 0 ? 1 : wps[i].nights)
  const assignedNights = (wps = waypoints) => wps.reduce((t, _w, i) => t + effectiveNights(i, wps), 0)
  const hasValidAllocation = totalNights === 0 || assignedNights() === totalNights
  const hasStayStops = waypoints.some((_w, i) => countsTowardDays(i))
  const offsetDaysBefore = (idx: number) => {
    let t = 0
    for (let i = 0; i < idx && i < waypoints.length; i++) t += effectiveNights(i)
    return t
  }
  const maxNightsFor = (i: number) => {
    if (!range) return Math.max(1, waypoints[i]?.nights ?? 1)
    if (totalNights <= 0) return 1
    return Math.max(1, totalNights - (assignedNights() - effectiveNights(i)))
  }

  const totalKm = useMemo(() => {
    let t = 0
    for (let i = 1; i < waypoints.length; i++) t += haversineKm(waypoints[i - 1].lat, waypoints[i - 1].lon, waypoints[i].lat, waypoints[i].lon)
    return t
  }, [waypoints])

  const difficultyLabel = inferTripDifficultyLabel({
    tripType: normalizedTripType,
    experienceLevel: experience,
    distanceKm: distanceKm ?? totalKm,
    estimatedDurationMin: durationMin,
    stopCount: waypoints.length,
    segmentTransportModes: segModes,
  })
  const requiredSkills = inferTripRequiredSkills({ tripType: normalizedTripType, segmentTransportModes: segModes })

  const isHikingTrailSegment = (i: number, p: Plan = planRef.current) => {
    if (i < 0 || i + 1 >= p.waypoints.length) return false
    if (containsHikingKeyword(p.waypoints[i].name) || containsHikingKeyword(p.waypoints[i + 1].name)) return true
    const m = segModeAt(i, p)
    return m === 'hiking' || m === 'portaging'
  }

  const validationMessage = tripNameValidationMessage(tripName) ?? waypointValidationMessage(waypoints)
  const canPersist = !!user && !!range && waypoints.length > 0 && validationMessage === null

  // ---- plan mutation helpers ------------------------------------------------------------------
  const normalizeStructure = (p: Plan): Plan => {
    const segments = Math.max(0, p.waypoints.length - 1)
    let modes = p.segModes.slice(0, segments)
    while (modes.length < segments) modes.push(normalizeBuilderMode(p.transportMode))
    modes = modes.map(normalizeBuilderMode)
    const next: Plan = { ...p, segModes: modes }
    modes = modes.map((m, i) => (m === 'car' && isHikingTrailSegment(i, next) ? 'portaging' : m))
    const routing = Array.from({ length: segments }, (_v, i) => normalizeBuilderRoutingType(i < p.segRouting.length ? p.segRouting[i] : '', modes[i]))
    const wps = p.waypoints.map((w) => ({ ...w, nights: Math.max(1, w.nights) }))
    return { ...p, waypoints: wps, segModes: modes, segRouting: routing, activeSeg: segments <= 0 || p.activeSeg < 0 || p.activeSeg >= segments ? 0 : p.activeSeg }
  }

  const resetComputed = () => {
    setRouteInstructions([])
    setRouteGeometry([])
    setRouteSegmentDetails([])
    setDistanceKm(null)
    setDurationMin(null)
    setTransitArrivalStop(null)
    setFocusedStep(null)
  }

  // Keep structure aligned if anything drifts (e.g. mode lists out of sync).
  useEffect(() => {
    const segments = Math.max(0, plan.waypoints.length - 1)
    if (plan.segModes.length !== segments || plan.segRouting.length !== segments) setPlan((p) => normalizeStructure(p))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [plan.waypoints.length, plan.segModes.length, plan.segRouting.length])

  // ---- route cache persistence ----------------------------------------------------------------
  const currentWaypointMaps = (p: Plan = planRef.current) =>
    p.waypoints.map((w, i) => ({ name: w.name, lat: w.lat, lon: w.lon, nights: w.nights, isStop: countsTowardDays(i, p.waypoints) }))

  const routeCachePayload = () => {
    const p = planRef.current
    const c = computedRef.current
    return {
      routeCacheKey: buildRouteCacheKey({
        waypoints: currentWaypointMaps(p),
        transportMode: p.transportMode,
        segmentTransportModes: p.segModes,
        segmentRoutingTypes: p.segRouting,
        routeVia: p.routeVia,
      }),
      routeGeometry3d: simplifyRouteGeometry(c.routeGeometry),
      routeInstructions: c.routeInstructions.slice(0, 8),
      routeSegmentDetails: c.routeSegmentDetails,
    }
  }

  const cachePersistTimer = useRef<ReturnType<typeof setTimeout>>(undefined)
  const persistRouteCache = async () => {
    const ref = savedRef.current
    if (!ref) return
    try {
      await setDoc(ref, JSON.parse(JSON.stringify(routeCachePayload())), { merge: true })
    } catch {
      /* cache persistence is non-fatal */
    }
  }
  const persistRouteCacheRef = useRef(persistRouteCache)
  persistRouteCacheRef.current = persistRouteCache
  const scheduleRouteCachePersist = () => {
    clearTimeout(cachePersistTimer.current)
    cachePersistTimer.current = setTimeout(() => void persistRouteCacheRef.current(), 600)
  }

  // ---- saving ----------------------------------------------------------------------------------
  const signature = () =>
    JSON.stringify({
      name: tripName.trim(), tripType, experience, transportMode,
      start: range ? ymd(range.start) : '', end: range ? ymd(range.end) : '',
      waypoints: currentWaypointMaps(),
      segRouting, segModes, routeVia, transitArrivalStop,
    })

  const buildPayload = (includeCreatedAt: boolean): Record<string, any> => {
    const r = range!
    const p = planRef.current
    const segments = Math.max(0, p.waypoints.length - 1)
    const modes = p.segModes.slice(0, segments).map(normalizeBuilderMode)
    while (modes.length < segments) modes.push(normalizeBuilderMode(p.transportMode))
    const routing = modes.map((m, i) => normalizeBuilderRoutingType(p.segRouting[i] ?? '', m))
    const via = p.routeVia.filter((v) => {
      const after = Number(v.afterIndex)
      return Number.isFinite(after) && after >= 0 && after < segments
    })
    const requiresGear = modes.some(isAdventureMode) || isAdventureMode(p.transportMode)
    const hasTransit = modes.some((m) => m === 'train') || (p.transportMode === 'train' && segments === 0)
    const nightsFor = (i: number) => effectiveNights(i, p.waypoints)
    const offsetFor = (idx: number) => {
      let t = 0
      for (let i = 0; i < idx; i++) t += nightsFor(i)
      return t
    }
    const payload: Record<string, any> = {
      name: tripName.trim(),
      days: totalDays,
      totalDays,
      totalNights,
      startDate: ymd(r.start),
      endDate: ymd(r.end),
      totalKm: p.waypoints.length >= 2 ? totalKm : null,
      estimatedDurationMin: durationMin,
      tripType: normalizedTripType,
      experienceLevel: normalizeExperience(),
      difficultyLabel: difficultyLabel,
      requiredSkills,
      transportMode: p.transportMode,
      routeVia: via,
      requires_gear_list: requiresGear,
      segmentRoutingTypes: routing,
      segmentTransportModes: modes,
      ...routeCachePayload(),
      waypoints: p.waypoints.map((w, idx) => {
        const nights = nightsFor(idx)
        const start = addDays(r.start, offsetFor(idx))
        return {
          name: w.name, lat: w.lat, lon: w.lon, nights, durationNights: nights, isStop: countsTowardDays(idx, p.waypoints),
          startDate: ymd(start), endDate: ymd(addDays(start, Math.max(0, nights - 1))), checkoutDate: ymd(addDays(start, Math.max(0, nights))),
        }
      }),
    }
    if (hasTransit && transitArrivalStop) payload.transitArrivalStop = transitArrivalStop
    // Firestore rejects `undefined`; round-trip to drop it, then add server timestamps.
    const clean = JSON.parse(JSON.stringify(payload))
    clean.updatedAt = serverTimestamp()
    if (includeCreatedAt) clean.createdAt = serverTimestamp()
    return clean
  }

  const persistTrip = async (showFeedback: boolean): Promise<boolean> => {
    if (validationMessage) {
      if (showFeedback) toast(validationMessage)
      return false
    }
    if (!canPersist) return false
    const me = auth.currentUser
    if (!me) return false
    if (showFeedback) {
      if (savingRef.current) return false
      savingRef.current = true
      setSaving(true)
    } else {
      if (autoSaveInFlight.current || savingRef.current) return false
      autoSaveInFlight.current = true
    }
    try {
      const payload = buildPayload(savedRef.current === null)
      if (savedRef.current === null) {
        const ref = await addDoc(collection(db, 'users', me.uid, 'trips'), payload)
        savedRef.current = ref
        setSavedRefPath(ref.path)
      } else {
        await setDoc(savedRef.current, payload, { merge: true })
      }
      lastSigRef.current = signature()
      if (showFeedback) toast('Trip saved to My Trips')
      return true
    } catch (e: any) {
      if (showFeedback) toast(`Save failed: ${e?.message ?? e}`)
      return false
    } finally {
      if (showFeedback) {
        savingRef.current = false
        setSaving(false)
      } else {
        autoSaveInFlight.current = false
      }
    }
  }
  const autoSaveTickRef = useRef<() => void>(() => {})
  autoSaveTickRef.current = () => {
    if (!canPersist || savingRef.current || autoSaveInFlight.current) return
    if (signature() === lastSigRef.current) return
    void persistTrip(false)
  }
  useEffect(() => {
    const id = setInterval(() => autoSaveTickRef.current(), 6000)
    return () => {
      clearInterval(id)
      clearTimeout(cachePersistTimer.current)
    }
  }, [])

  // ---- dialogs (promise-based) ----------------------------------------------------------------
  const ask = useCallback(<T,>(build: (resolve: (v: T | null) => void) => Dlg): Promise<T | null> => {
    return new Promise<T | null>((resolve) => {
      dlgOpenRef.current = true
      setDlg(build((v) => {
        dlgOpenRef.current = false
        blockMapTapFor(700)
        setDlg(null)
        resolve(v)
      }))
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const showTripBasics = async () => {
    const now = stripTime(new Date())
    const res = await ask<TripBasics>((resolve) => ({
      kind: 'basics',
      props: {
        initial: { name: tripName.trim(), start: range?.start ?? now, end: range?.end ?? addDays(now, 3), tripType: normalizedTripType, experience: normalizeExperience() },
        normalizeExperience,
        onResult: resolve,
      },
    }))
    if (!res) return
    setTripName(res.name)
    setRange({ start: res.start, end: res.end })
    setTripType(normalizeTripType(res.tripType))
    setExperience(normalizeExperience(res.experience))
    if (planRef.current.waypoints.length === 0) setPlan((p) => ({ ...p, transportMode: defaultTransportModeForTripType(res.tripType) }))
    setResults([])
    setQuery('')
    resetComputed()
  }

  useEffect(() => {
    if (didOnboard.current) return
    didOnboard.current = true
    if (!tripNameValidationMessage(tripName) && range) return
    void showTripBasics()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const pickDateRange = async () => {
    const now = stripTime(new Date())
    const res = await ask<{ start: Date; end: Date }>((resolve) => ({
      kind: 'dates',
      props: { initialStart: range?.start ?? now, initialEnd: range?.end ?? addDays(now, 3), onResult: resolve },
    }))
    if (res) setRange(res)
  }

  // ---- waypoint operations --------------------------------------------------------------------
  const modeForInsert = (insertIndex?: number, override?: string) => {
    if (override?.trim()) return normalizeBuilderMode(override)
    const p = planRef.current
    if (insertIndex != null && insertIndex > 0 && insertIndex < p.waypoints.length) return segModeAt(insertIndex - 1, p)
    return normalizeBuilderMode(p.transportMode)
  }

  const insertWaypointAt = (insertIndex: number, waypoint: Waypoint, segmentMode: string, routingType: string) => {
    setPlan((p) => {
      const target = clampInt(insertIndex, 0, p.waypoints.length)
      const mode = normalizeBuilderMode(segmentMode)
      const routing = normalizeBuilderRoutingType(routingType, mode)
      const existing = Math.max(0, p.waypoints.length - 1)
      const modes = Array.from({ length: existing }, (_v, i) => normalizeBuilderMode(i < p.segModes.length ? p.segModes[i] : p.transportMode))
      const routings = Array.from({ length: existing }, (_v, i) =>
        normalizeBuilderRoutingType(i < p.segRouting.length ? p.segRouting[i] : defaultRoutingTypeForMode(modes[i]), modes[i]),
      )
      const wps = [...p.waypoints]
      wps.splice(target, 0, waypoint)
      if (wps.length > 1) {
        if (target > 0 && target < wps.length - 1) {
          const split = target - 1
          const inherited = split < modes.length ? modes[split] : mode
          modes.splice(target, 0, inherited)
          if (split < routings.length) {
            routings[split] = routing
            routings.splice(target, 0, routing)
          } else routings.push(routing)
        } else {
          const si = target === 0 ? 0 : target - 1
          modes.splice(si, 0, mode)
          routings.splice(si, 0, routing)
        }
      }
      const next = normalizeStructure({
        ...p,
        waypoints: wps,
        segModes: modes,
        segRouting: routings,
        activeSeg: Math.max(0, Math.min(target === 0 ? 0 : target - 1, Math.max(0, wps.length - 2))),
      })
      return next
    })
    resetComputed()
    setResults([])
    setQuery('')
    scheduleRouteCachePersist()
  }

  const addWaypointWithPrompt = async (
    name: string, lat: number, lon: number,
    opts: { insertIndex?: number; segmentModeOverride?: string; preferredRoutingType?: string; campsiteData?: Record<string, any>; preferStop?: boolean } = {},
  ) => {
    if (!range) {
      toast('Select a trip date range first')
      return
    }
    const insertIndex = opts.insertIndex ?? planRef.current.waypoints.length
    const segmentMode = modeForInsert(insertIndex, opts.segmentModeOverride)
    const nightsLeft = (() => {
      const t = Math.max(0, diffDays(range.end, range.start))
      return t === 0 ? 0 : t - assignedNights(planRef.current.waypoints)
    })()
    const draft = await ask<DestinationDraft>((resolve) => ({
      kind: 'dest',
      props: {
        initialName: name, lat, lon, segmentMode,
        preferredRoutingType: opts.preferredRoutingType, campsiteData: opts.campsiteData, preferStop: opts.preferStop ?? true,
        totalTripNights: Math.max(0, diffDays(range.end, range.start)), availableNights: nightsLeft,
        onResult: resolve,
      },
    }))
    if (!draft) return
    insertWaypointAt(
      insertIndex,
      { name: draft.name, lat, lon, nights: draft.isStop ? Math.max(1, draft.nights) : 1, isStop: draft.isStop },
      segmentMode,
      draft.routingType,
    )
    if (!draft.isStop) toast('Added as a waypoint. Toggle it to Stop if it should use trip nights.')
  }

  const removeWaypoint = (index: number) => {
    setPlan((p) => normalizeStructure({ ...p, waypoints: p.waypoints.filter((_w, i) => i !== index), routeVia: [] }))
    resetComputed()
    scheduleRouteCachePersist()
  }

  const setWaypointRole = (index: number, isStop: boolean) => {
    if (isStop && range && totalNights <= 0) {
      toast('Add at least one trip night before creating stay stops')
      return
    }
    setPlan((p) => {
      const wps = p.waypoints.map((w) => ({ ...w }))
      const w = wps[index]
      if (!w) return p
      w.isStop = isStop
      if (isStop) {
        const used = wps.reduce((t, x, i) => t + (i === index ? 0 : x.isStop ? Math.max(1, x.nights) : 0), 0)
        const max = !range ? Math.max(1, w.nights) : totalNights <= 0 ? 1 : Math.max(1, totalNights - used)
        w.nights = Math.max(1, Math.min(w.nights, max))
      }
      return { ...p, waypoints: wps }
    })
  }

  const setWaypointNights = (index: number, nights: number) =>
    setPlan((p) => ({ ...p, waypoints: p.waypoints.map((w, i) => (i === index ? { ...w, nights } : w)) }))

  const setActiveSegment = (i: number) => {
    const segments = Math.max(0, planRef.current.waypoints.length - 1)
    if (segments <= 0) return
    const clamped = clampInt(i, 0, segments - 1)
    if (planRef.current.activeSeg === clamped) return
    setPlan((p) => ({ ...p, activeSeg: clamped }))
  }

  const setSegmentRoutingType = (i: number, routingType: string) => {
    setPlan((p) => {
      const routing = [...p.segRouting]
      if (i < 0 || i >= routing.length) return p
      routing[i] = normalizeBuilderRoutingType(routingType, segModeAt(i, p))
      return { ...p, segRouting: routing }
    })
    resetComputed()
    scheduleRouteCachePersist()
  }

  const setSegmentMode = (i: number, mode: string, updateDefaultMode = false) => {
    const normalized = normalizeBuilderMode(mode)
    let coerced = false
    setPlan((p) => {
      const segments = Math.max(0, p.waypoints.length - 1)
      if (i < 0 || i >= segments) return p
      const modes = p.segModes.slice(0, segments)
      while (modes.length < segments) modes.push(normalizeBuilderMode(p.transportMode))
      const routing = p.segRouting.slice(0, segments)
      while (routing.length < segments) routing.push(defaultRoutingTypeForMode(modes[routing.length]))
      let resolved = normalized
      if (resolved === 'car' && isHikingTrailSegment(i, { ...p, segModes: modes })) {
        resolved = 'portaging'
        coerced = true
      }
      modes[i] = resolved
      const keepDirect = (routing[i] ?? '').trim().toLowerCase() === 'direct'
      routing[i] = keepDirect ? 'direct' : defaultRoutingTypeForMode(resolved)
      const via = resolved === 'train' || resolved === 'plane' ? p.routeVia.filter((v) => Number(v.afterIndex) !== i) : p.routeVia
      return { ...p, segModes: modes, segRouting: routing, activeSeg: i, routeVia: via, transportMode: updateDefaultMode ? resolved : p.transportMode }
    })
    resetComputed()
    scheduleRouteCachePersist()
    if (coerced) toast('Car mode is disabled on backcountry legs. Using portaging mode instead.')
  }

  const setTransportModeTop = (mode: string) => {
    const m = normalizeBuilderMode(mode)
    if (selectedSeg != null) {
      setSegmentMode(selectedSeg, m, true)
      return
    }
    setPlan((p) => ({ ...p, transportMode: m }))
    if (waypoints.length === 0 && !isMixed) {
      setTripType((t) => normalizeTripType(t, { transportMode: m, segmentTransportModes: [] }))
    }
    resetComputed()
    scheduleRouteCachePersist()
  }

  // ---- map interactions -----------------------------------------------------------------------
  const defaultMapTapName = () => {
    const mode = selectedSeg == null ? transportMode : segModeAt(selectedSeg)
    return isAdventureMode(mode) ? 'Campsite' : 'Dropped Pin'
  }

  const addDroppedPinFromMapTap = async (lat: number, lon: number) => {
    if (isMapTapBlocked()) return
    if (isPortage) {
      toast(
        isPortageAccessStage
          ? 'Portage trips must start from a mapped access point. Click a blue access marker or search one by name.'
          : 'Portage trips only allow mapped campsites and access points. Click a campsite or access marker instead.',
      )
      return
    }
    if (!range) {
      toast('Select a trip date range first')
      return
    }
    let name = defaultMapTapName()
    try {
      const resolved = await reverseNominatim(lat, lon)
      if (resolved && resolved.trim()) name = resolved
    } catch {
      /* keep default name */
    }
    await addWaypointWithPrompt(name, lat, lon)
  }

  const setBoundaryFromAccessPoint = (isStart: boolean, name: string, lat: number, lon: number) => {
    const boundary: Waypoint = { name, lat, lon, nights: 1, isStop: false }
    setPlan((p) => {
      let wps: Waypoint[]
      if (p.waypoints.length === 0) wps = [boundary]
      else if (p.waypoints.length === 1) {
        const other = { ...p.waypoints[0], nights: Math.max(1, p.waypoints[0].nights) }
        wps = isStart ? [boundary, other] : [other, boundary]
      } else {
        wps = [...p.waypoints]
        if (isStart) wps[0] = boundary
        else wps[wps.length - 1] = boundary
      }
      return normalizeStructure({ ...p, waypoints: wps })
    })
    resetComputed()
    scheduleRouteCachePersist()
  }

  const onPortageAccessTap = async (ap: Record<string, any>) => {
    const lat = coerceCoord(ap.lat)
    const lon = coerceCoord(ap.lon)
    if (lat == null || lon == null) return
    if (!range) {
      toast('Select a trip date range first')
      return
    }
    const name = String(ap.name ?? 'Portage access').trim() || 'Portage access'
    const routeKm = Number(ap.distanceKmFromRoute) || 0
    const wps = planRef.current.waypoints
    if (wps.length === 0) {
      setTripType('portage')
      setPlan((p) => ({ ...p, transportMode: 'portaging' }))
      setBoundaryFromAccessPoint(true, name, lat, lon)
      toast(`${name} set as your launch point. Next, add campsites or portages.`)
      return
    }
    const hasStart = wps.length > 0
    const hasEnd = wps.length >= 2
    const choice = await ask<'start' | 'end'>((resolve) => ({
      kind: 'access',
      props: {
        name, lat, lon, routeKm,
        currentStart: hasStart ? formatLocationDisplay({ raw: wps[0].name }).title : '',
        currentEnd: hasEnd ? formatLocationDisplay({ raw: wps[wps.length - 1].name }).title : '',
        startLabel: !hasStart ? 'Add as start point' : wps.length === 1 ? 'Insert as start point' : 'Replace start point',
        endLabel: !hasEnd ? 'Add as end point' : wps.length === 1 ? 'Insert as end point' : 'Replace end point',
        onResult: resolve,
      },
    }))
    if (choice !== 'start' && choice !== 'end') return
    setBoundaryFromAccessPoint(choice === 'start', name, lat, lon)
    toast(`${name} set as your ${choice === 'start' ? 'start' : 'end'} point`)
  }

  const onHikingCampsiteTap = async (campsite: Record<string, any>) => {
    const lat = coerceCoord(campsite.lat)
    const lon = coerceCoord(campsite.lon)
    if (lat == null || lon == null) return
    const name = String(campsite.name ?? 'Campsite').trim() || 'Campsite'
    const fromRouteKm = Number(campsite.distanceKmFromRoute) || 0
    const wps = planRef.current.waypoints
    let fromLastKm: number | null = null
    let lastName: string | null = null
    if (wps.length) {
      const last = wps[wps.length - 1]
      fromLastKm = haversineKm(last.lat, last.lon, lat, lon)
      lastName = formatLocationDisplay({ raw: last.name }).title
    }
    const distanceLabel =
      fromLastKm != null
        ? `${fromLastKm.toFixed(1)} km from last point${lastName ? ` (${lastName})` : ''}`
        : `${fromRouteKm.toFixed(1)} km from your route`
    const campMode = modeForInsert(undefined, String(campsite.mode ?? ''))
    const routeDistanceKm = fromLastKm ?? fromRouteKm
    await addWaypointWithPrompt(name, lat, lon, {
      segmentModeOverride: String(campsite.mode ?? ''),
      preferredRoutingType: defaultRoutingTypeForMode(campMode),
      campsiteData: {
        ...campsite,
        distanceKmFromRoute: routeDistanceKm,
        access: campsite.access ?? distanceLabel,
        ...(lastName ? { accessibleFrom: lastName } : {}),
        routeDifficulty: adventureDifficultyForDistance(routeDistanceKm, campMode),
        estimatedTime: adventureEstimatedTime(routeDistanceKm, campMode),
        warning: adventureWarning(routeDistanceKm, campMode),
      },
      preferStop: true,
    })
  }

  // ---- route-line adjustment ------------------------------------------------------------------
  const upsertVia = (afterIndex: number, lat: number, lon: number) => {
    setPlan((p) => {
      const idx = p.routeVia.findIndex((v) => String(v.afterIndex) === String(afterIndex))
      const entry = { afterIndex, lat, lon }
      const via = idx >= 0 ? p.routeVia.map((v, i) => (i === idx ? entry : v)) : [...p.routeVia, entry]
      return { ...p, routeVia: via }
    })
    resetComputed()
    scheduleRouteCachePersist()
  }
  const moveVia = (viaIndex: number, lat: number, lon: number) => {
    setPlan((p) => (viaIndex < 0 || viaIndex >= p.routeVia.length ? p : { ...p, routeVia: p.routeVia.map((v, i) => (i === viaIndex ? { ...v, lat, lon } : v)) }))
    resetComputed()
    scheduleRouteCachePersist()
  }
  const deleteVia = (viaIndex: number) => {
    setPlan((p) => ({ ...p, routeVia: p.routeVia.filter((_v, i) => i !== viaIndex) }))
    resetComputed()
    scheduleRouteCachePersist()
  }

  const onRouteTapped = async (afterIndex: number, lat: number, lon: number) => {
    setActiveSegment(afterIndex)
    const choice = await ask<'pin' | 'find'>((resolve) => ({ kind: 'route', props: { afterIndex, onResult: resolve } }))
    if (choice === 'pin') upsertVia(afterIndex, lat, lon)
    else if (choice === 'find') smartFindStopBetween(afterIndex)
    void lat
    void lon
  }

  // ---- smart suggestions ----------------------------------------------------------------------
  const geocodeSuggestion = async (s: Record<string, any>): Promise<[number, number] | null> => {
    const query = [s.name, s.address].map((x) => String(x ?? '').trim()).filter(Boolean).join(' ')
    if (!query) return null
    const res = await searchNominatim(query)
    if (!res.length) return null
    const lat = Number(res[0].lat)
    const lon = Number(res[0].lon)
    return Number.isFinite(lat) && Number.isFinite(lon) ? [lat, lon] : null
  }
  const suggestionRaw = (s: Record<string, any>) =>
    [s.name, s.address].map((x) => String(x ?? '').trim()).filter(Boolean).join(', ').trim() || 'Suggested stop'

  const smartSuggestNextStop = () => {
    const p = planRef.current
    if (!range) return toast('Select a trip date range first')
    if (!p.waypoints.length) return toast('Add a waypoint first')
    const last = p.waypoints[p.waypoints.length - 1]
    const legMode = p.waypoints.length >= 2 ? segModeAt(p.waypoints.length - 2, p) : p.transportMode
    const lastTitle = formatLocationDisplay({ raw: last.name }).title
    setFinder({
      title: isAdventureMode(legMode) ? '✨ Suggest Next Campsite' : '✨ Suggest Next Stay Stop',
      destinationName: lastTitle, lat: last.lat, lon: last.lon, routeFromName: lastTitle, routeMode: legMode,
      onAddStop: async (s) => {
        const coords = await geocodeSuggestion(s)
        if (!coords) return toast('Could not locate that stop')
        setFinder(null)
        await addWaypointWithPrompt(suggestionRaw(s), coords[0], coords[1], {
          segmentModeOverride: legMode, preferredRoutingType: defaultRoutingTypeForMode(legMode), preferStop: true,
        })
      },
    })
  }

  const smartFindStopBetween = (afterIndex: number) => {
    const p = planRef.current
    if (!range) return toast('Select a trip date range first')
    if (p.waypoints.length < 2) return toast('Add at least two waypoints')
    if (afterIndex < 0 || afterIndex >= p.waypoints.length - 1) return
    const a = p.waypoints[afterIndex]
    const b = p.waypoints[afterIndex + 1]
    const legMode = segModeAt(afterIndex, p)
    const aTitle = formatLocationDisplay({ raw: a.name }).title
    const bTitle = formatLocationDisplay({ raw: b.name }).title
    setFinder({
      title: isAdventureMode(legMode) ? '✨ Find Campsite Between' : '✨ Find Stay Stop Between',
      destinationName: `Between ${aTitle} and ${bTitle}`, lat: (a.lat + b.lat) / 2, lon: (a.lon + b.lon) / 2,
      routeFromName: aTitle, routeToName: bTitle, routeMode: legMode,
      onAddStop: async (s) => {
        const coords = await geocodeSuggestion(s)
        if (!coords) return toast('Could not locate that stop')
        setFinder(null)
        await addWaypointWithPrompt(suggestionRaw(s), coords[0], coords[1], {
          insertIndex: afterIndex + 1, segmentModeOverride: legMode, preferredRoutingType: segRoutingAt(afterIndex, p), preferStop: true,
        })
      },
    })
  }

  // ---- search ----------------------------------------------------------------------------------
  const isHikingSearchMode = (() => {
    const m = selectedSeg != null ? segModeAt(selectedSeg, plan) : normalizeBuilderMode(transportMode)
    return m === 'hiking' || m === 'portaging'
  })()

  const fallbackResults = (q: string): SearchResult[] => {
    const l = q.trim().toLowerCase()
    if (!l) return []
    return Object.entries(SAMPLE_LOOKUP)
      .filter(([k]) => k.includes(l))
      .map(([, w]) => ({ name: w.name, display_name: w.name, lat: w.lat, lon: w.lon }))
  }

  const searchForUi = async (raw: string): Promise<SearchResult[]> => {
    const q = raw.trim()
    if (!q) return []
    let found: SearchResult[] = await searchNominatim(q)
    if (!found.length) found = fallbackResults(q)

    if (isPortageAccessStage) {
      let filtered = filterPortageAccessResults(found)
      if (filtered.length) return filtered
      const focused = portageAccessBiasedQuery(q)
      if (focused !== q) {
        filtered = filterPortageAccessResults(await searchNominatim(focused))
        if (filtered.length) return filtered
      }
      return []
    }
    if (!isHikingSearchMode) return found
    let filtered = filterHikingResults(found)
    if (filtered.length) return filtered
    const focused = hikingBiasedQuery(q)
    if (focused !== q) {
      filtered = filterHikingResults(await searchNominatim(focused))
      if (filtered.length) return filtered
    }
    return []
  }
  const searchForUiRef = useRef(searchForUi)
  searchForUiRef.current = searchForUi

  useEffect(() => {
    const q = query.trim()
    if (!q) {
      setResults([])
      return
    }
    let cancelled = false
    const id = setTimeout(async () => {
      const r = await searchForUiRef.current(q)
      if (!cancelled) setResults(r)
    }, 400)
    return () => {
      cancelled = true
      clearTimeout(id)
    }
  }, [query])

  const handleSearchSelection = async (r: SearchResult, fallbackQuery: string) => {
    if (!range) return toast('Select a trip date range first')
    const raw = rawLocationFromResult(r, fallbackQuery)
    const lat = coerceCoord(r.lat) ?? 0
    const lon = coerceCoord(r.lon) ?? 0
    if (isPortageAccessStage) {
      if (!looksLikePortageAccessResult(r)) {
        toast('Portage trips usually start at an access point. Search an access point first, then add campsites.')
        return
      }
      await onPortageAccessTap({ ...r, name: raw, lat, lon })
      return
    }
    await addWaypointWithPrompt(raw, lat, lon)
  }

  const submitSearch = async () => {
    const q = query.trim()
    if (!q) return
    if (!range) return toast('Select a trip date range first')
    const found = results.length ? results : await searchForUi(q)
    if (!found.length) {
      if (isPortageAccessStage) toast('Search an access point or click a blue access marker to start a portage trip')
      else if (isHikingSearchMode) toast('Try a trail, campsite, or portage name in backcountry mode')
      else {
        const match = Object.keys(SAMPLE_LOOKUP).find((k) => k.includes(q.toLowerCase()))
        if (match) addFromLookup(match)
        else toast('No matches found for that search')
      }
      return
    }
    await handleSearchSelection(found[0], q)
    setQuery('')
    setResults([])
  }

  const addFromLookup = (key: string) => {
    const s = SAMPLE_LOOKUP[key.toLowerCase().trim()]
    if (!s) return
    if (!range) return toast('Select a trip date range first')
    void addWaypointWithPrompt(s.name, s.lat, s.lon)
  }

  // ---- map points / callbacks ------------------------------------------------------------------
  const mapPoints = useMemo(() => waypoints.map((w) => ({ name: w.name, lat: w.lat, lon: w.lon, isStop: w.isStop })), [waypoints])

  const onRouteSummary = useCallback((meters: number, seconds: number) => {
    setDistanceKm(meters / 1000)
    setDurationMin(seconds / 60)
  }, [])

  // ---- transit leg cards -----------------------------------------------------------------------
  const legacyTransitSteps = (): AnyMap[] =>
    routeInstructions
      .map((line): AnyMap | null => {
        const text = line.trim()
        if (!text) return null
        const lower = text.toLowerCase()
        if (lower.startsWith('walk')) return { mode: 'walking', tabLabel: 'Walk', headline: text }
        if (lower.startsWith('bike')) return { mode: 'biking', tabLabel: 'Bike', headline: text }
        return { mode: 'transit', tabLabel: 'Train', headline: text }
      })
      .filter((s): s is AnyMap => !!s)
      .slice(0, 6)

  const transitDetailAt = (i: number): AnyMap | null => {
    for (const d of routeSegmentDetails) {
      if (Number(d.segmentIndex) === i && normalizeBuilderMode(String(d.mode ?? '')) === 'train' && Array.isArray(d.steps)) return d
    }
    const transitSegs: number[] = []
    for (let s = 0; s < waypoints.length - 1; s++) if (segModeAt(s, plan) === 'train') transitSegs.push(s)
    if (transitSegs.length === 1 && transitSegs[0] === i && routeInstructions.length) {
      return { segmentIndex: i, mode: 'train', steps: legacyTransitSteps(), ...(transitArrivalStop ? { arrivalStop: transitArrivalStop } : {}) }
    }
    return null
  }

  const transitLegCard = (i: number): ReactNode => {
    if (i < 0 || i + 1 >= waypoints.length || segModeAt(i, plan) !== 'train') return null
    const detail = transitDetailAt(i)
    const steps = (detail?.steps as AnyMap[] | undefined) ?? []
    if (!detail || !steps.length) return null
    const arrival = detail.arrivalStop
    const arrivalName = arrival && typeof arrival === 'object' ? String(arrival.name ?? arrival.label ?? '') : ''
    return (
      <div style={{ paddingLeft: 34, marginBottom: 10 }}>
        <TransitLegTabsCard
          originName={waypoints[i].name}
          destinationName={waypoints[i + 1].name}
          arrivalStopName={arrivalName}
          steps={steps}
          onStepSelected={(step) => setFocusedStep({ ...step, requestId: ++focusRequestRef.current })}
        />
      </div>
    )
  }

  // ===========================================================================================
  // Render
  // ===========================================================================================
  const guide = tripTypeGuide(normalizedTripType, waypoints.length > 0)
  const steps = guideSteps(normalizedTripType, waypoints.length)
  const activeStepNumber = steps.findIndex((s) => s.active) >= 0 ? steps.findIndex((s) => s.active) + 1 : steps.length

  const blockPointer = { onPointerDown: () => blockMapTapFor(1200) }

  const detailsIsland = (
    <div className="tb-card" {...blockPointer}>
      <div className="row wrap gap-sm" style={{ alignItems: 'center' }}>
        {renamingName ? (
          <span className="tb-pill">
            <input
              autoFocus value={tripName} placeholder="Trip name"
              onChange={(e) => setTripName(e.target.value)}
              onBlur={() => setRenamingName(false)}
              onKeyDown={(e) => e.key === 'Enter' && setRenamingName(false)}
            />
          </span>
        ) : (
          <button className="tb-pill" title="Double-click to rename" onDoubleClick={() => setRenamingName(true)} onClick={() => !tripName.trim() && void showTripBasics()}>
            <MdTitle size={16} /> {tripName.trim() || 'Trip name'}
          </button>
        )}
        <button className="tb-pill" onClick={() => void pickDateRange()}>
          <MdDateRange size={16} /> {range ? `${ymd(range.start)} → ${ymd(range.end)}` : 'Select dates'}
        </button>
        <button className="tb-pill" onClick={() => void showTripBasics()}>
          <span>{tripTypeEmoji(normalizedTripType)}</span> {tripTypeDisplayLabel(normalizedTripType)}
        </button>
        {isAdventure && <span className="tb-pill" style={{ cursor: 'default' }}><MdTune size={16} /> Difficulty: {difficultyLabel}</span>}
      </div>
    </div>
  )

  const searchIsland = (
    <div className="tb-card tb-search-wrap" {...blockPointer}>
      <div className="input-wrap">
        <span className="input-icon"><MdSearch size={20} /></span>
        <input
          className="input" style={{ paddingRight: 100 }} aria-label="Location search"
          placeholder={tripTypeSearchHint(normalizedTripType, waypoints.length > 0)}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && void submitSearch()}
        />
        <div style={{ position: 'absolute', right: 6, top: 4, display: 'flex', gap: 2 }}>
          <button className="icon-btn" title="Add" onClick={() => void submitSearch()}><MdAdd size={22} /></button>
          <select
            className="select" aria-label="Add from list" disabled={!range} value="" style={{ width: 34, padding: 0, border: 'none', background: 'transparent', cursor: 'pointer' }}
            onChange={(e) => e.target.value && addFromLookup(e.target.value)}
          >
            <option value="">☰</option>
            {Object.keys(SAMPLE_LOOKUP).map((k) => <option key={k} value={k}>{k}</option>)}
          </select>
        </div>
      </div>
      {isAdventure && (
        <div className="muted" style={{ fontSize: 12, marginTop: 8 }}>
          {isPortageAccessStage
            ? 'Search results are filtered to access points first so your route starts from a real launch location.'
            : isPortage
              ? 'Backcountry results include campsites and portage lines. On the map, add stops by clicking campsite or access-point markers.'
              : 'Backcountry results include campsites, trails, and portage lines. Need a custom stop? Click the map.'}
        </div>
      )}
      {results.length > 0 && (
        <div className="tb-results">
          {results.map((r, i) => {
            const display = formatLocationDisplay({ placeName: String(r.name ?? '').trim(), raw: rawLocationFromResult(r, `Result ${i + 1}`) })
            const cat = searchResultCategory(r)
            return (
              <div key={i} className="tb-result" onClick={async () => { await handleSearchSelection(r, rawLocationFromResult(r, display.title)); setQuery(''); setResults([]) }}>
                <MdOutlineBackpack size={20} color={cat.color} style={{ flex: 'none', marginTop: 2 }} />
                <div style={{ minWidth: 0 }}>
                  <div style={{ fontWeight: 800 }}>{display.title}</div>
                  <div style={{ fontSize: 11, fontWeight: 700, color: cat.color }}>{cat.label}</div>
                  <div className="muted" style={{ fontSize: 12 }}>{display.subtitle || `${Number(r.lat).toFixed(4)}, ${Number(r.lon).toFixed(4)}`}</div>
                </div>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )

  const mapModeIsland = (
    <div className="tb-toggle tb-card" style={{ padding: 6 }} {...blockPointer}>
      <button className={cx('td-toggle', mapMode === '2d' && 'selected')} onClick={() => setMapMode('2d')}>2D Map</button>
      <button
        className={cx('td-toggle', mapMode === '3d' && 'selected')}
        onClick={() => {
          setMapMode('3d')
          if (adjustRoute) {
            setAdjustRoute(false)
            toast('Route line adjustments are available in 2D map mode.')
          }
        }}
      >
        3D Globe
      </button>
    </div>
  )

  const guideCard = isAdventure && (
    <div className="tb-guide tb-card" {...blockPointer}>
      <div className="row between" style={{ alignItems: 'flex-start' }}>
        <div className="row gap-sm" style={{ alignItems: 'flex-start' }}>
          <div style={{ width: 30, height: 30, borderRadius: '50%', background: '#CCFBF1', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <MdAltRoute size={17} color="#0F766E" />
          </div>
          <div>
            <div style={{ fontSize: 11, fontWeight: 900, color: '#0F766E', letterSpacing: 0.3 }}>Build Flow</div>
            <div style={{ fontSize: 14, fontWeight: 800, color: '#0F172A' }}>{guide.title}</div>
          </div>
        </div>
        <span style={{ fontSize: 11, fontWeight: 800, color: '#0F766E' }}>{activeStepNumber}/{steps.length}</span>
      </div>
      <div style={{ fontSize: 11.5, color: '#475569', margin: '8px 0 12px', lineHeight: 1.32 }}>{guide.body}</div>
      {steps.map((s, i) => {
        const accent = s.active ? '#0F766E' : s.done ? '#0284C7' : '#94A3B8'
        return (
          <div key={i} className="tb-step">
            <div className="tb-step-badge" style={{ color: accent, borderColor: `${accent}38`, background: s.active ? '#CCFBF1' : s.done ? '#E0F2FE' : '#fff' }}>
              {s.done ? <MdCheck size={14} /> : i + 1}
            </div>
            <div>
              <div style={{ fontSize: 12.5, fontWeight: 800, color: s.active ? '#0F172A' : '#334155' }}>{s.title}</div>
              <div style={{ fontSize: 11.5, color: '#475569', lineHeight: 1.32 }}>{s.detail}</div>
            </div>
          </div>
        )
      })}
      <div className="row wrap gap-sm">
        <Button
          variant="text" size="sm" className="tb-teal-btn" icon={<MdAutoAwesome size={16} />}
          onClick={() =>
            waypoints.length === 0
              ? toast(isPortageAccessStage ? 'Choose your access point first, then Suggested will recommend the next campsite.' : 'Add your first destination first, then Suggested can recommend the next stop.')
              : smartSuggestNextStop()
          }
        >
          {isAdventure ? 'Suggested next' : 'Suggested stop'}
        </Button>
        {allowsCustomDrops && (
          <Button
            variant="text" size="sm" className="tb-teal-btn" icon={<MdTouchApp size={16} />}
            onClick={() =>
              toast(
                isPortageAccessStage
                  ? 'Tip: start your portage trip by clicking a blue access-point marker or searching one by name.'
                  : isPortage
                    ? 'Tip: portage trips only allow mapped campsites and access points. Click those markers on the map or search for them by name.'
                    : isAdventure
                      ? 'Tip: click the map to add a campsite, trail stop, or custom backcountry point.'
                      : 'Tip: click the map to drop a custom stop anywhere on your route.',
              )
            }
          >
            Map tip
          </Button>
        )}
      </div>
    </div>
  )

  const stopItem = (i: number) => {
    const isFirst = i === 0
    const isLast = i === waypoints.length - 1
    const w = waypoints[i]
    const segKm = !isLast ? haversineKm(w.lat, w.lon, waypoints[i + 1].lat, waypoints[i + 1].lon) : 0
    const counts = countsTowardDays(i)
    const nights = effectiveNights(i)
    const display = formatLocationDisplay({ raw: w.name })
    const boundaryLabel = isFirst && isLast ? 'Start / End' : isFirst ? 'Start' : isLast ? 'End' : null

    let dateStr = ''
    if (range && counts) {
      const start = addDays(range.start, offsetDaysBefore(i))
      dateStr = `${ymd(start)} → ${ymd(addDays(start, Math.max(0, nights)))}`
    }
    const staySummary = counts ? `${nights} night${nights === 1 ? '' : 's'}` : boundaryLabel ? `${boundaryLabel} · No stay` : 'Waypoint · No stay'
    const maxNights = range ? maxNightsFor(i) : 30

    const isSegmentRow = !isLast
    const isActive = isSegmentRow && selectedSeg === i
    const carBlocked = isSegmentRow && isHikingTrailSegment(i, plan)
    const segType = isSegmentRow ? segRoutingAt(i, plan) : 'calculated'
    const segMode = segModeAt(i, plan)
    const primaryRouting = defaultRoutingTypeForMode(segMode)
    const lastLegMode = waypoints.length >= 2 ? segModeAt(waypoints.length - 2, plan) : transportMode

    return (
      <div key={i}>
        <div className="tb-stop">
          <div className="tb-stop-rail">
            <div className="tb-stop-dot">{!counts ? <MdAltRoute size={11} color="#616161" /> : i + 1}</div>
            {!isLast && <div className="tb-stop-line" />}
          </div>
          <div className={cx('tb-stop-card', isActive && 'active')} onClick={() => isSegmentRow && setActiveSegment(i)}>
            <div className="row" style={{ alignItems: 'flex-start', gap: 8 }}>
              <div className="grow" style={{ fontWeight: 800, minWidth: 0 }}>{display.title}</div>
              <div className="tb-stop-controls">
                {boundaryLabel && <div className="tb-mini-box">{boundaryLabel}</div>}
                <div>
                  <div className="tb-mini-label">Type</div>
                  <select className="tb-mini-select" value={w.isStop ? 'stop' : 'wp'} onClick={() => blockMapTapFor(2500)} onChange={(e) => { blockMapTapFor(); setWaypointRole(i, e.target.value === 'stop') }}>
                    <option value="stop">Stop</option>
                    <option value="wp">Waypoint</option>
                  </select>
                </div>
                {w.isStop ? (
                  <div>
                    <div className="tb-mini-label">Nights</div>
                    <select className="tb-mini-select" value={Math.max(1, Math.min(w.nights, maxNights))} onClick={() => blockMapTapFor(2500)} onChange={(e) => { blockMapTapFor(); setWaypointNights(i, Number(e.target.value)) }}>
                      {Array.from({ length: maxNights }, (_v, k) => <option key={k} value={k + 1}>{k + 1}</option>)}
                    </select>
                  </div>
                ) : (
                  <div className="tb-mini-box">No stay</div>
                )}
              </div>
              <button className="icon-btn" title="Remove destination" onClick={(e) => { e.stopPropagation(); removeWaypoint(i) }}><MdDeleteOutline size={20} /></button>
            </div>
            {display.subtitle.trim() && <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>{display.subtitle}</div>}
            <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>{dateStr ? `${staySummary} · ${dateStr}` : staySummary}</div>

            {isSegmentRow ? (
              <div style={{ marginTop: 8 }} onClick={(e) => e.stopPropagation()}>
                <div className="muted" style={{ fontSize: 12 }}>{segKm.toFixed(2)} km to next</div>
                <div className="row wrap gap-sm" style={{ alignItems: 'center', marginTop: 8 }}>
                  <span style={{ fontSize: 12, fontWeight: 700 }}>Mode:</span>
                  <select
                    className="tb-mini-select" style={{ width: 150 }} value={segMode}
                    onFocus={() => { setActiveSegment(i); blockMapTapFor(2500) }}
                    onChange={(e) => { setActiveSegment(i); blockMapTapFor(); setSegmentMode(i, e.target.value) }}
                  >
                    {availableTransportOptionsForTripType(normalizedTripType).map((o) => (
                      <option key={o.mode} value={o.mode} disabled={carBlocked && o.mode === 'car'}>{o.emoji} {o.label}</option>
                    ))}
                  </select>
                  <span style={{ fontSize: 12, fontWeight: 700 }}>Routing:</span>
                  <button className={cx('chip', segType.trim().toLowerCase() === primaryRouting && 'selected')} onClick={() => { setActiveSegment(i); setSegmentRoutingType(i, primaryRouting) }}>
                    {primaryRoutingLabelForMode(segMode)}
                  </button>
                  <button className={cx('chip', segType.trim().toLowerCase() === 'direct' && 'selected')} onClick={() => { setActiveSegment(i); setSegmentRoutingType(i, 'direct') }}>Direct</button>
                  <Button variant="text" size="sm" className="tb-teal-btn" icon={<MdAutoAwesome size={14} />} onClick={() => { setActiveSegment(i); smartFindStopBetween(i) }}>
                    {isAdventureMode(segMode) ? 'Find Campsite' : 'Find Stay Stop'}
                  </Button>
                </div>
                <div className="muted" style={{ fontSize: 11, marginTop: 8 }}>{routingDescription(segType.trim().toLowerCase(), segMode)}</div>
              </div>
            ) : (
              <div style={{ marginTop: 8 }} onClick={(e) => e.stopPropagation()}>
                <div className="muted" style={{ fontSize: 12 }}>Last destination</div>
                <Button variant="text" size="sm" className="tb-teal-btn" icon={<MdAutoAwesome size={14} />} onClick={smartSuggestNextStop}>
                  {isAdventureMode(lastLegMode) ? 'Suggest Next Campsite' : 'Suggest Next Stay Stop'}
                </Button>
              </div>
            )}
          </div>
        </div>
        {!isLast && transitLegCard(i)}
      </div>
    )
  }

  const selectedLegMode = selectedSeg == null ? normalizeBuilderMode(transportMode) : segModeAt(selectedSeg, plan)
  const selectedLegLabel = selectedSeg == null ? 'No leg selected yet' : `Leg ${selectedSeg + 1}`
  const nameMsg = tripNameValidationMessage(tripName) ?? waypointValidationMessage(waypoints)

  const itineraryPanel = (
    <div className="tb-panel" {...blockPointer}>
      <div style={{ fontSize: 16, fontWeight: 900, marginBottom: 12 }}>Destinations &amp; routing</div>
      <div className="row wrap gap-sm">
        <span className="chip">{tripTypeEmoji(normalizedTripType)} {tripTypeBadgeLabel(normalizedTripType)}</span>
        {isAdventure && <span className="chip"><MdTune size={16} /> {difficultyLabel}</span>}
        {isAdventure && <span className="chip"><MdSchool size={16} /> Experience: {tripExperienceDisplayLabel(experience)}</span>}
      </div>
      {isAdventure && <div className="muted" style={{ fontSize: 12, margin: '8px 0 12px' }}>Required skills: {requiredSkills.join(', ')}</div>}

      <div style={{ fontWeight: 700, margin: '12px 0 8px' }}>Leg mode ({selectedLegLabel})</div>
      <div className="tb-mode-row">
        {availableTransportOptionsForTripType(normalizedTripType).map((o) => {
          const blocked = selectedSeg != null && o.mode === 'car' && isHikingTrailSegment(selectedSeg, plan)
          return (
            <button key={o.mode} className={cx('chip', selectedLegMode === o.mode && 'selected')} style={{ whiteSpace: 'nowrap', opacity: blocked ? 0.5 : 1 }} disabled={blocked} onClick={() => setTransportModeTop(o.mode)}>
              {o.emoji} {o.label}
            </button>
          )
        })}
      </div>
      <div className="muted" style={{ fontSize: 11, marginTop: 4 }}>{modeSelectionHelperText(normalizedTripType)}</div>

      {waypoints.length >= 2 && !isPortage && (
        <div className="row gap-sm" style={{ alignItems: 'center', marginTop: 14 }}>
          <label className="row gap-sm" style={{ alignItems: 'center', fontWeight: 800 }}>
            <input type="checkbox" checked={adjustRoute} onChange={(e) => setAdjustRoute(e.target.checked)} /> Adjust route line
          </label>
          <span className="grow" />
          {adjustRoute && routeVia.length > 0 && (
            <Button variant="text" size="sm" onClick={() => { setPlan((p) => ({ ...p, routeVia: [] })); resetComputed(); scheduleRouteCachePersist() }}>Clear</Button>
          )}
        </div>
      )}

      <div style={{ marginTop: 14 }}>
        {range && hasStayStops && (
          <div style={{ fontSize: 13, fontWeight: 700, color: hasValidAllocation ? 'rgba(0,0,0,0.54)' : '#c62828' }}>
            Nights assigned (stay stops only): {assignedNights()} / {totalNights}
          </div>
        )}
        {range && hasStayStops && !hasValidAllocation && <div style={{ fontSize: 12, color: '#c62828', marginTop: 4 }}>Adjust nights so they match the trip length.</div>}
        {range && waypoints.length >= 2 && (
          <div className="muted" style={{ fontSize: 11, marginTop: 4 }}>Only destinations marked as Stop count toward trip nights. Waypoints stay transit-only.</div>
        )}
      </div>
      <div style={{ fontSize: 15, fontWeight: 700, marginTop: 10 }}>Total: {(distanceKm ?? totalKm).toFixed(2)} km</div>
      {durationMin != null && <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>Estimated time: {durationMin.toFixed(0)} min</div>}

      <div style={{ fontWeight: 900, margin: '14px 0 10px' }}>Destinations</div>
      {waypoints.length === 0 ? (
        <div>
          {isPortage
            ? 'No destinations yet. Start with an access point above or click a blue access marker on the map.'
            : 'No destinations yet. Search above or click the map to add.'}
        </div>
      ) : (
        waypoints.map((_w, i) => stopItem(i))
      )}

      <div style={{ marginTop: 8 }}>
        {(tripName.trim() || waypoints.length > 0) && nameMsg && <div style={{ color: '#c62828', fontWeight: 600, marginBottom: 8 }}>{nameMsg}</div>}
        {!user && <div className="muted" style={{ marginBottom: 8 }}>Sign in to save trips</div>}
        <Button
          variant="solid" icon={saving ? <Spinner size="sm" white /> : <MdSave size={18} />}
          disabled={!user || !range || waypoints.length === 0 || !!nameMsg || !hasValidAllocation || saving}
          onClick={() => void persistTrip(true)}
        >
          {saving ? 'Saving...' : 'Save Trip'}
        </Button>
        <div style={{ marginTop: 8 }}>
          <Button variant="solid" icon={<MdShare size={18} />} disabled={!savedRefPath} onClick={() => setShareOpen(true)}>Share</Button>
        </div>
        {!user && <Button variant="text" size="sm" onClick={() => navigate('/sign-in')}>Sign in</Button>}
      </div>
    </div>
  )

  const mapNode =
    mapMode === '3d' ? (
      <Globe3DEmbed
        points={mapPoints}
        routeGeometry={routeGeometry}
        transportMode={transportMode}
        onRouteSummary={onRouteSummary}
        onMapTap={!adjustRoute && allowsCustomDrops ? (lat, lon) => void addDroppedPinFromMapTap(lat, lon) : undefined}
      />
    ) : (
      <MapEmbed
        points={mapPoints}
        transportMode={transportMode}
        segmentTransportModes={segModes}
        routeVia={isPortage ? [] : routeVia}
        segmentRoutingTypes={segRouting}
        onRouteInstructions={(lines) => { setRouteInstructions(lines); scheduleRouteCachePersist() }}
        onRouteSegmentDetails={(segs) => { setRouteSegmentDetails(readRouteSegmentDetails(segs)); scheduleRouteCachePersist() }}
        onRouteGeometry={(g) => { setRouteGeometry(g); scheduleRouteCachePersist() }}
        onTransitArrivalStop={(stop) => setTransitArrivalStop(Object.keys(stop ?? {}).length ? stop : null)}
        onRouteError={(message) => { setDistanceKm(null); setDurationMin(null); toast(message) }}
        focusedRouteStep={focusedStep}
        onRouteSummary={onRouteSummary}
        onHikingCampsiteTap={(c) => void onHikingCampsiteTap(c)}
        onPortageAccessTap={(a) => void onPortageAccessTap(a)}
        onMapTap={!adjustRoute && allowsCustomDrops ? (lat, lon) => void addDroppedPinFromMapTap(lat, lon) : undefined}
        onRouteTapAddVia={adjustRoute && !isPortage ? (a, lat, lon) => { if (!isMapTapBlocked()) void onRouteTapped(a, lat, lon) } : undefined}
        onViaDragEnd={adjustRoute && !isPortage ? (v, lat, lon) => { if (!isMapTapBlocked()) moveVia(v, lat, lon) } : undefined}
        onViaTapDelete={adjustRoute && !isPortage ? (v) => { if (!isMapTapBlocked()) deleteVia(v) } : undefined}
        routeComputingBannerTop={compact ? 148 : 108}
        activeStopIndex={(selectedSeg ?? 0) + 1}
        portageExperienceLevel={experience}
      />
    )

  return (
    <div className="tb-screen">
      <TopTaskbar dockProgress={1} />
      <div className="tb-body">
        <div className="tb-map">{mapNode}</div>

        {compact ? (
          <div className="tb-overlay tb-compact">
            {detailsIsland}
            {searchIsland}
            <div style={{ pointerEvents: 'auto', alignSelf: 'flex-start' }}>{mapModeIsland}</div>
            {guideCard}
            {itineraryPanel}
          </div>
        ) : (
          <div className="tb-overlay">
            <div className="tb-col">
              {detailsIsland}
              {guideCard}
              {itineraryPanel}
            </div>
            <div className="tb-main">
              <div style={{ flex: 1, display: 'flex', justifyContent: 'center', minWidth: 0 }}>{searchIsland}</div>
              {mapModeIsland}
            </div>
          </div>
        )}
      </div>

      {dlg?.kind === 'basics' && <TripBasicsDialog {...dlg.props} />}
      {dlg?.kind === 'dates' && <DateRangeDialog {...dlg.props} />}
      {dlg?.kind === 'dest' && <DestinationDialog {...dlg.props} />}
      {dlg?.kind === 'access' && <AccessPointDialog {...dlg.props} />}
      {dlg?.kind === 'route' && <RouteOptionsDialog {...dlg.props} />}

      {finder && (
        <ActivityFinderModal
          open
          mode="routeStop"
          title={finder.title}
          destinationName={finder.destinationName}
          lat={finder.lat}
          lon={finder.lon}
          startDate={range ? ymd(range.start) : ''}
          endDate={range ? ymd(range.end) : ''}
          routeFromName={finder.routeFromName}
          routeToName={finder.routeToName}
          routeMode={finder.routeMode}
          onAddStop={finder.onAddStop}
          onClose={() => setFinder(null)}
        />
      )}

      {savedRefPath && (
        <ShareTripDialog
          open={shareOpen}
          onClose={() => setShareOpen(false)}
          tripRefPath={savedRefPath}
          tripId={savedRefPath.split('/').pop() ?? ''}
          tripName={tripName.trim()}
        />
      )}
    </div>
  )
}
