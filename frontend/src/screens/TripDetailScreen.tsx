import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { deleteField, doc, getDoc, onSnapshot, setDoc, updateDoc } from 'firebase/firestore'
import {
  MdAltRoute, MdArrowBack, MdCheck, MdChat, MdClear, MdClose, MdDelete, MdDirections, MdDragHandle, MdEdit, MdEditNote, MdHotel, MdList,
  MdListAlt, MdLocalActivity, MdLocationCity, MdLockOutline, MdLogin, MdOutlineMap, MdMoreHoriz, MdPieChart, MdPlace, MdPublic, MdSave,
  MdSearch, MdShare, MdTerrain, MdShowChart, MdAutoAwesome, MdArrowUpward, MdArrowDownward,
} from 'react-icons/md'
import { useLocation, useNavigate, useParams } from 'react-router-dom'
import { auth, db } from '@/firebase'
import MapEmbed from '@/components/map/MapEmbed'
import Globe3DEmbed from '@/components/Globe3DEmbed'
import TransitLegTabsCard from '@/components/TransitLegTabsCard'
import ShareTripDialog from '@/components/ShareTripDialog'
import TripChatDialog from '@/components/TripChatDialog'
import TripExpensesDialog from '@/components/TripExpensesDialog'
import PackingListDialog from '@/components/PackingListDialog'
import { Dialog } from '@/components/Dialog'
import { Button, cx, Menu, MenuItem, Spinner } from '@/components/ui'
import { useAuth } from '@/context/Auth'
import { useFeedback } from '@/context/Feedback'
import { useBack } from '@/hooks/useBack'
import { debounce } from '@/lib/async'
import { readRouteGeometry, readRouteInstructions, readRouteSegmentDetails, simplifyRouteGeometry } from '@/lib/routeCache'
import {
  TRANSPORT_OPTIONS, canEditWaypointRole, coerceSegmentRoutingTypes, coerceSegmentTransportModes, currentRouteCacheKey, labelsMatch, mapList,
  mapPointKind, mapPointSubtitle, mapPointTitle, mapRoutePoints, mapSecondaryPoints, normalizeDetailMode, ownerUidFromTripRefPath, requiresGearListForModes,
  syncedWaypointsForSave, topActivityCategories, vibeForCategory, waypointIsStop, waypointNightCount, waypointRoleLabel, isWaypointOnly, toNum, type WP,
} from '@/lib/tripDetail'
import { searchPlaces, type PlaceResult } from '@/services/geocode'
import { tripRefPathFromData } from '@/services/tripsService'

interface Props {
  docId: string
  data: Record<string, any>
  /** Purely read-only (e.g. unauthenticated share-link viewer). */
  readOnly?: boolean
  ownerUid?: string
}

const asWaypoints = (raw: unknown): WP[] => (Array.isArray(raw) ? raw.map((e) => (e && typeof e === 'object' ? { ...e } : {})) : [])

type QuickAction = 'plan' | 'packing' | 'expenses' | 'chat' | 'share'

export default function TripDetailScreen({ docId, data, readOnly = false }: Props) {
  const navigate = useNavigate()
  const back = useBack('/my-trips')
  const { user } = useAuth()
  const { toast } = useFeedback()

  const [liveData, setLiveData] = useState<Record<string, any>>(() => ({ ...data }))
  const [days, setDays] = useState<number>(typeof data.totalDays === 'number' ? Math.trunc(data.totalDays) : 1)
  const [waypoints, setWaypoints] = useState<WP[]>(() => asWaypoints(data.waypoints))
  const [saving, setSaving] = useState(false)
  const [editing, setEditing] = useState(false)
  const [transportMode, setTransportMode] = useState(() => normalizeDetailMode(String(data.transportMode ?? 'driving')))
  const [routeVia, setRouteVia] = useState<WP[]>(() => asWaypoints(data.routeVia))
  const [routeInstructions, setRouteInstructions] = useState<string[]>(() => readRouteInstructions(data.routeInstructions))
  const [routeGeometry, setRouteGeometry] = useState<{ lat: number; lon: number; lng: number }[]>(() => readRouteGeometry(data.routeGeometry3d))
  const [routeSegmentDetails, setRouteSegmentDetails] = useState<WP[]>(() => readRouteSegmentDetails(data.routeSegmentDetails))
  const [segmentRoutingTypes, setSegmentRoutingTypes] = useState<string[]>([])
  const [segmentTransportModes, setSegmentTransportModes] = useState<string[]>([])
  const [transitArrivalStop, setTransitArrivalStop] = useState<WP | null>(null)
  const [selectedMapPoint, setSelectedMapPoint] = useState<WP | null>(null)
  const [focusedStep, setFocusedStep] = useState<WP | null>(null)
  const stepReq = useRef(0)
  const [mapMode, setMapMode] = useState<'map2d' | 'globe3d'>('map2d')

  const [searchText, setSearchText] = useState('')
  const [suggestions, setSuggestions] = useState<PlaceResult[]>([])
  const [searching, setSearching] = useState(false)

  const [dialog, setDialog] = useState<null | 'share' | 'chat' | 'expenses' | 'packing' | 'directions' | 'segments'>(null)
  const [editWpIndex, setEditWpIndex] = useState<number | null>(null)
  const [w, setW] = useState(window.innerWidth)
  const [sheetExtent, setSheetExtent] = useState(0.18)
  const isNarrow = w < 760

  useEffect(() => {
    const on = () => setW(window.innerWidth)
    window.addEventListener('resize', on)
    return () => window.removeEventListener('resize', on)
  }, [])

  // ---------- derive state from a trip document snapshot ----------
  const wpRef = useRef(waypoints)
  wpRef.current = waypoints

  const applyDoc = useCallback((d: Record<string, any>) => {
    const wps = asWaypoints(d.waypoints)
    const mode = normalizeDetailMode(String(d.transportMode ?? 'driving'))
    const segCount = wps.length > 1 ? wps.length - 1 : 0
    setWaypoints(wps)
    if (typeof d.totalDays === 'number') setDays(Math.trunc(d.totalDays))
    setTransportMode(mode)
    const via = asWaypoints(d.routeVia).filter((v) => {
      const after = typeof v.afterIndex === 'number' ? Math.trunc(v.afterIndex) : null
      return after != null && after >= 0 && after < segCount
    })
    setRouteVia(via)
    setSegmentRoutingTypes(coerceSegmentRoutingTypes(Array.isArray(d.segmentRoutingTypes) ? d.segmentRoutingTypes : [], segCount))
    setSegmentTransportModes(coerceSegmentTransportModes(Array.isArray(d.segmentTransportModes) ? d.segmentTransportModes : [], segCount, mode))
    if (d.transitArrivalStop && typeof d.transitArrivalStop === 'object') setTransitArrivalStop({ ...d.transitArrivalStop })
    setRouteGeometry(readRouteGeometry(d.routeGeometry3d))
    setRouteInstructions(readRouteInstructions(d.routeInstructions))
    setRouteSegmentDetails(readRouteSegmentDetails(d.routeSegmentDetails))
  }, [])

  // initial derive
  useEffect(() => {
    const d = { ...data }
    const segCount = asWaypoints(d.waypoints).length
    const count = segCount > 1 ? segCount - 1 : 0
    const mode = normalizeDetailMode(String(d.transportMode ?? 'driving'))
    setSegmentRoutingTypes(coerceSegmentRoutingTypes(Array.isArray(d.segmentRoutingTypes) ? d.segmentRoutingTypes : [], count))
    setSegmentTransportModes(coerceSegmentTransportModes(Array.isArray(d.segmentTransportModes) ? d.segmentTransportModes : [], count, mode))
    if (d.transitArrivalStop && typeof d.transitArrivalStop === 'object') setTransitArrivalStop({ ...d.transitArrivalStop })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const currentTripRefPath = (): string | null => tripRefPathFromData(liveData) ?? tripRefPathFromData(data)
  const tripRefPath = useMemo(() => {
    const p = tripRefPathFromData(liveData) ?? tripRefPathFromData(data)
    if (p) return p
    return user ? `users/${user.uid}/trips/${docId}` : ''
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [liveData.tripRef, data.tripRef, user?.uid, docId])
  void currentTripRefPath

  // ---------- realtime subscriptions (owner doc + local doc) ----------
  const subscribedPath = useRef<string | null>(null)
  const ownerUnsub = useRef<(() => void) | null>(null)

  const subscribeOwner = useCallback((path: string) => {
    ownerUnsub.current?.()
    subscribedPath.current = path
    ownerUnsub.current = onSnapshot(
      doc(db, path),
      (snap) => {
        if (!snap.exists()) {
          toast('This trip was removed by the owner')
          return
        }
        const remote = snap.data() ?? {}
        setLiveData((cur) => ({ ...cur, ...remote, tripRef: path }))
        applyDoc({ ...remote })
      },
      (e) => console.debug('TripDetail: owner snapshot error', e),
    )
  }, [applyDoc, toast])

  useEffect(() => {
    const path = tripRefPathFromData(data)
    if (path) subscribeOwner(path)
    return () => ownerUnsub.current?.()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    if (!user) return
    return onSnapshot(
      doc(db, 'users', user.uid, 'trips', docId),
      (snap) => {
        if (!snap.exists()) return
        const d = snap.data() ?? {}
        const newRef = tripRefPathFromData(d) ?? ''
        if (newRef && newRef !== subscribedPath.current) subscribeOwner(newRef)
        else setLiveData((cur) => ({ ...cur, ...d }))
      },
      (e) => console.debug('TripDetail: local doc snapshot error', e),
    )
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user?.uid, docId])

  // ---------- permissions ----------
  const ownerUid = ownerUidFromTripRefPath(tripRefPath)
  const sharedWith: any[] = Array.isArray(liveData.sharedWith ?? data.sharedWith) ? liveData.sharedWith ?? data.sharedWith : []
  const canWriteTrip = !!user && !!tripRefPath && (ownerUid === user.uid || sharedWith.includes(user.uid))
  const isOwner = !!user && ownerUid === user.uid
  const tripRef = tripRefPath ? doc(db, tripRefPath) : null

  const segmentModeAt = (i: number) => (i < 0 || i >= segmentTransportModes.length ? normalizeDetailMode(transportMode) : normalizeDetailMode(segmentTransportModes[i]))
  const segmentTypeAt = (i: number) => (i < 0 || i >= segmentRoutingTypes.length ? 'calculated' : segmentRoutingTypes[i].trim().toLowerCase() === 'direct' ? 'direct' : 'calculated')
  const hasTransitInRoute = (() => {
    const segs = waypoints.length > 1 ? waypoints.length - 1 : 0
    if (segs === 0) return normalizeDetailMode(transportMode) === 'transit'
    for (let i = 0; i < segs; i++) if (segmentModeAt(i) === 'transit') return true
    return false
  })()

  const syncSegmentData = (nextWps: WP[], via = routeVia, modes = segmentTransportModes, types = segmentRoutingTypes) => {
    const count = nextWps.length > 1 ? nextWps.length - 1 : 0
    setSegmentRoutingTypes(coerceSegmentRoutingTypes(types, count))
    setSegmentTransportModes(coerceSegmentTransportModes(modes, count, transportMode))
    setRouteVia(via.filter((v) => typeof v.afterIndex === 'number' && v.afterIndex >= 0 && v.afterIndex < count).map((v) => ({ ...v })))
  }
  const setWps = (next: WP[]) => {
    setWaypoints(next)
    setLiveData((cur) => ({ ...cur, waypoints: next.map((e) => ({ ...e })) }))
    syncSegmentData(next)
  }

  // ---------- route cache ----------
  const routeCacheKey = currentRouteCacheKey({ waypoints, transportMode, segmentTransportModes, segmentRoutingTypes, routeVia })
  const canUseCachedRoute = (() => {
    const stored = String(liveData.routeCacheKey ?? '').trim()
    return !!stored && stored === routeCacheKey && routeGeometry.length >= 2 && (!hasTransitInRoute || routeSegmentDetails.length > 0)
  })()

  const persistRouteCache = useRef<() => void>(() => {})
  persistRouteCache.current = () => {
    if (!user || !tripRef || ownerUid !== user.uid) return
    const payload = {
      routeCacheKey, routeGeometry3d: simplifyRouteGeometry(routeGeometry), routeInstructions: routeInstructions.slice(0, 8), routeSegmentDetails,
    }
    setDoc(tripRef, payload, { merge: true }).then(() => setLiveData((cur) => ({ ...cur, ...payload }))).catch(() => { /* non-fatal */ })
  }
  const schedulePersist = useMemo(() => debounce(() => persistRouteCache.current(), 600), [])
  useEffect(() => () => schedulePersist.cancel(), [schedulePersist])

  // ---------- trip mutations ----------
  const guardWrite = (): boolean => !!user && !!tripRef && ownerUid === user.uid

  const setTransport = async (mode: string) => {
    if (!user) return
    const normalized = normalizeDetailMode(mode)
    const segs = waypoints.length > 1 ? waypoints.length - 1 : 0
    const updatedModes = Array<string>(segs).fill(normalized)
    const updatedVia = normalized === 'transit' ? [] : routeVia
    setTransportMode(normalized)
    setSegmentTransportModes(updatedModes)
    setRouteVia(updatedVia)
    setRouteInstructions([]); setRouteGeometry([]); setRouteSegmentDetails([]); setFocusedStep(null)
    if (normalized !== 'transit') setTransitArrivalStop(null)
    if (!guardWrite()) return
    try {
      await updateDoc(tripRef!, { transportMode: normalized, segmentTransportModes: updatedModes, routeVia: updatedVia, requires_gear_list: requiresGearListForModes(updatedModes, normalized) })
    } catch (e: any) {
      toast(`Failed to update mode: ${e?.message ?? e}`)
    }
  }

  const upsertVia = async (afterIndex: number, lat: number, lon: number) => {
    if (!guardWrite()) return
    const updated = routeVia.map((v) => ({ ...v }))
    const next = { afterIndex, lat, lon }
    let insertAt = -1
    updated.forEach((v, i) => { if (Math.trunc(v.afterIndex ?? -1) === afterIndex) insertAt = i })
    if (insertAt >= 0) updated.splice(insertAt + 1, 0, next)
    else {
      let lastBefore = -1
      updated.forEach((v, i) => { if (Math.trunc(v.afterIndex ?? -1) <= afterIndex) lastBefore = i })
      updated.splice(lastBefore + 1, 0, next)
    }
    setRouteVia(updated)
    try { await updateDoc(tripRef!, { routeVia: updated }) } catch (e: any) { toast(`Failed to update route: ${e?.message ?? e}`) }
  }

  const moveVia = async (viaIndex: number, lat: number, lon: number) => {
    if (!guardWrite() || viaIndex < 0 || viaIndex >= routeVia.length) return
    const updated = routeVia.map((v) => ({ ...v }))
    updated[viaIndex] = { afterIndex: Math.trunc(updated[viaIndex].afterIndex ?? 0), lat, lon }
    setRouteVia(updated)
    try { await updateDoc(tripRef!, { routeVia: updated }) } catch (e: any) { toast(`Failed to update route: ${e?.message ?? e}`) }
  }

  const deleteVia = async (viaIndex: number) => {
    if (!guardWrite() || viaIndex < 0 || viaIndex >= routeVia.length) return
    const updated = routeVia.filter((_, i) => i !== viaIndex)
    setRouteVia(updated)
    try { await updateDoc(tripRef!, { routeVia: updated }) } catch (e: any) { toast(`Failed to update route: ${e?.message ?? e}`) }
  }

  const setSegmentRoutingType = async (segmentIndex: number, type: string) => {
    if (!guardWrite()) return
    const normalized = type.trim().toLowerCase() === 'direct' ? 'direct' : 'calculated'
    const desired = Math.max(0, waypoints.length - 1)
    const updated = coerceSegmentRoutingTypes(segmentRoutingTypes, desired)
    if (segmentIndex < 0 || segmentIndex >= updated.length) return
    updated[segmentIndex] = normalized
    setSegmentRoutingTypes(updated)
    try { await updateDoc(tripRef!, { segmentRoutingTypes: updated }) } catch (e: any) { toast(`Failed to update routing type: ${e?.message ?? e}`) }
  }

  const setSegmentMode = async (segmentIndex: number, mode: string) => {
    if (!guardWrite()) return
    const normalized = normalizeDetailMode(mode)
    const segs = waypoints.length > 1 ? waypoints.length - 1 : 0
    const updated = coerceSegmentTransportModes(segmentTransportModes, segs, transportMode)
    if (segmentIndex < 0 || segmentIndex >= updated.length) return
    updated[segmentIndex] = normalized
    const nextVia = normalized === 'transit' ? routeVia.filter((v) => Math.trunc(v.afterIndex ?? -1) !== segmentIndex) : routeVia
    setSegmentTransportModes(updated)
    setRouteVia(nextVia)
    setRouteInstructions([]); setRouteGeometry([]); setRouteSegmentDetails([]); setFocusedStep(null)
    if (!updated.includes('transit')) setTransitArrivalStop(null)
    try { await updateDoc(tripRef!, { segmentTransportModes: updated, routeVia: nextVia, requires_gear_list: requiresGearListForModes(updated, transportMode) }) }
    catch (e: any) { toast(`Failed to update segment mode: ${e?.message ?? e}`) }
  }

  const persistArrival = async (stop: WP) => {
    if (!guardWrite()) return
    try {
      await updateDoc(tripRef!, { transitArrivalStop: Object.keys(stop).length ? stop : deleteField() })
    } catch { /* non-fatal */ }
  }

  const clearCorrections = async () => {
    if (!canWriteTrip || !guardWrite()) return
    setRouteVia([]); setRouteInstructions([]); setRouteGeometry([]); setRouteSegmentDetails([])
    try { await updateDoc(tripRef!, { routeVia: [] }) } catch (e: any) { toast(`Failed to clear corrections: ${e?.message ?? e}`) }
  }

  const saveAll = async () => {
    if (!user || !tripRef) return
    setSaving(true)
    try {
      const segCount = waypoints.length > 1 ? waypoints.length - 1 : 0
      const nextTypes = coerceSegmentRoutingTypes(segmentRoutingTypes, segCount)
      const nextModes = coerceSegmentTransportModes(segmentTransportModes, segCount, transportMode)
      const nextVia = routeVia.filter((v) => typeof v.afterIndex === 'number' && v.afterIndex >= 0 && v.afterIndex < segCount).map((v) => ({ ...v }))
      const synced = syncedWaypointsForSave(waypoints)
      setWaypoints(synced)
      setLiveData((cur) => ({ ...cur, waypoints: synced.map((e) => ({ ...e })) }))
      setSegmentRoutingTypes(nextTypes); setSegmentTransportModes(nextModes); setRouteVia(nextVia)
      await updateDoc(tripRef, {
        totalDays: days, waypoints: synced, segmentRoutingTypes: nextTypes, segmentTransportModes: nextModes, routeVia: nextVia,
        requires_gear_list: requiresGearListForModes(nextModes, transportMode),
      })
      toast('Saved')
      setEditing(false)
    } catch (e: any) {
      toast(`Save failed: ${e?.message ?? e}`)
    } finally {
      setSaving(false)
    }
  }

  // ---------- waypoint editing ----------
  const addWaypointFromTap = (lat: number, lon: number) => {
    setWps([...waypoints, { lat, lon, name: `Point ${waypoints.length + 1}`, isStop: false, nights: 0 }])
  }
  const removeWaypoint = (i: number) => setWps(waypoints.filter((_, idx) => idx !== i))
  const moveWaypoint = (from: number, to: number) => {
    if (to < 0 || to >= waypoints.length || from === to) return
    const next = [...waypoints]
    const [item] = next.splice(from, 1)
    next.splice(to, 0, item)
    setWps(next)
  }
  const setWaypointRole = (i: number, isStop: boolean) => {
    if (!canEditWaypointRole(i, waypoints)) return
    const next = waypoints.map((wp, idx) => (idx === i ? { ...wp, isStop, nights: isStop ? (waypointNightCount(wp) > 0 ? waypointNightCount(wp) : 1) : 0 } : wp))
    setWps(next)
  }
  const onSelectSuggestion = (p: PlaceResult) => {
    const display = p.display_name
    if (!display.trim()) return
    setWps([...waypoints, { lat: p.lat, lon: p.lon, name: display, routing_query: display, isStop: false, nights: 0 }])
    setSuggestions([])
    setSearchText('')
  }

  // place search (debounced)
  useEffect(() => {
    const v = searchText.trim()
    if (!v) {
      setSuggestions([])
      return
    }
    const t = setTimeout(async () => {
      setSearching(true)
      try {
        setSuggestions((await searchPlaces(v)).slice(0, 6))
      } catch {
        setSuggestions([])
      } finally {
        setSearching(false)
      }
    }, 400)
    return () => clearTimeout(t)
  }, [searchText])

  // ---------- participants ----------
  const collectParticipants = (): string[] => {
    const parts = new Set<string>()
    const p = tripRefPath.split('/')
    if (p.length >= 2 && p[0] === 'users') parts.add(p[1])
    for (const s of sharedWith) parts.add(String(s))
    if (user?.uid) parts.add(user.uid)
    return [...parts]
  }

  // ---------- navigation ----------
  const openPlanning = (focusWaypointIndex?: number, initialTab = 0) => {
    if (!tripRefPath) return toast('Not logged in')
    let focusDay: number | undefined
    if (focusWaypointIndex != null && focusWaypointIndex < waypoints.length) {
      const wpStart = String(waypoints[focusWaypointIndex].startDate ?? '')
      const tripStart = String(liveData.startDate ?? '')
      if (wpStart && tripStart) {
        const ws = new Date(wpStart), ts = new Date(tripStart)
        if (!Number.isNaN(ws.getTime()) && !Number.isNaN(ts.getTime())) focusDay = Math.max(0, Math.round((ws.getTime() - ts.getTime()) / 86400000))
      }
    }
    const q = new URLSearchParams({ ref: tripRefPath, tripId: docId, tab: String(initialTab) })
    if (focusDay != null) q.set('day', String(focusDay))
    navigate(`/plan?${q.toString()}`)
  }

  const handleQuickAction = (a: QuickAction) => {
    if (a === 'plan') openPlanning()
    else if (a === 'packing') setDialog('packing')
    else if (a === 'expenses') setDialog('expenses')
    else if (a === 'chat') setDialog('chat')
    else setDialog('share')
  }

  // ---------- map data ----------
  const mapPoints = useMemo(() => mapRoutePoints(waypoints), [waypoints])
  const secondaryPoints = useMemo(
    () => mapSecondaryPoints(waypoints, [liveData.tripItinerary, liveData.itinerary, data.tripItinerary, data.itinerary]),
    [waypoints, liveData.tripItinerary, liveData.itinerary, data.tripItinerary, data.itinerary],
  )
  const showMapLayer = !(readOnly && !canWriteTrip)
  const name = String(liveData.name ?? 'Untitled Trip')
  const totalKm = toNum(liveData.totalKm)

  const sameInstr = (next: string[]) => routeInstructions.length === next.length && routeInstructions.every((v, i) => v === next[i])
  const samePath = (next: any[]) => {
    if (routeGeometry.length !== next.length) return false
    return next.every((b, i) => Math.abs(routeGeometry[i].lat - b.lat) <= 1e-7 && Math.abs(routeGeometry[i].lon - (b.lon ?? b.lng)) <= 1e-7)
  }
  const sameDetails = (next: WP[]) => {
    if (routeSegmentDetails.length !== next.length) return false
    return next.every((cand, i) => {
      const cur = routeSegmentDetails[i]
      if (cur.segmentIndex !== cand.segmentIndex || String(cur.mode ?? '') !== String(cand.mode ?? '')) return false
      const cs: any[] = cur.steps ?? [], ns: any[] = cand.steps ?? []
      if (cs.length !== ns.length) return false
      return ns.every((b, si) => ['mode', 'tabLabel', 'headline', 'detail', 'caption'].every((k) => String(cs[si]?.[k] ?? '') === String(b?.[k] ?? '')))
    })
  }
  const cacheKeyCurrent = String(liveData.routeCacheKey ?? '').trim() === routeCacheKey

  const insight = useMemo(() => {
    const p = selectedMapPoint
    if (!p) return null
    const kind = mapPointKind(p)
    const title = mapPointTitle(p)
    const activitiesForWaypoint = (wi: number, wName: string) => {
      const out: WP[] = []
      const seen = new Set<string>()
      const append = (raw: unknown) => {
        for (const a of mapList(raw)) {
          const key = [String(a.title ?? '').trim().toLowerCase(), String(a.startTime ?? '').trim(), String(a.location ?? '').trim().toLowerCase(), String(a.category ?? '').trim().toLowerCase()].join('|')
          if (seen.has(key)) continue
          seen.add(key)
          out.push(a)
        }
      }
      if (wi >= 0 && wi < waypoints.length) for (const day of mapList(waypoints[wi].itinerary)) append(day.activities)
      for (const rawDays of [liveData.tripItinerary, liveData.itinerary, data.tripItinerary, data.itinerary]) {
        for (const day of mapList(rawDays)) {
          const dw = typeof day.waypointIndex === 'number' ? day.waypointIndex : null
          if ((wi >= 0 && dw === wi) || (wName && labelsMatch(String(day.locationName ?? ''), wName))) append(day.activities)
        }
      }
      return out
    }
    let categories: string[] = []
    const pointCategory = String(p.category ?? '').trim()
    if (kind === 'activity') {
      categories = pointCategory ? [pointCategory] : []
      const di = typeof p.dayIndex === 'number' ? p.dayIndex : null
      if (di != null && di >= 0) {
        const itin = mapList(liveData.tripItinerary ?? liveData.itinerary)
        if (di < itin.length) for (const c of topActivityCategories(mapList(itin[di].activities))) if (!categories.includes(c)) categories.push(c)
      }
      categories = categories.slice(0, 6)
    } else {
      const wi = typeof p.waypointIndex === 'number' ? p.waypointIndex : -1
      const cats = topActivityCategories(activitiesForWaypoint(wi, String(p.name ?? '')))
      categories = cats.length ? cats : pointCategory ? [pointCategory] : []
    }
    let summary: string
    if (kind === 'activity') {
      const di = typeof p.dayIndex === 'number' ? p.dayIndex : null
      const when = di != null && di >= 0 ? `on Day ${di + 1}` : 'in your plan'
      const vibe = vibeForCategory(pointCategory || categories[0] || '')
      summary = `${title} is scheduled ${when} and fits ${vibe}. Keep this stop near nearby items to avoid extra transit time.`
    } else if (kind === 'accommodation') {
      summary = `${title} looks like your base for this stop. Nearby focus areas: ${categories.length ? categories.slice(0, 3).join(', ') : 'your planned activities'}.`
    } else {
      const wi = typeof p.waypointIndex === 'number' ? p.waypointIndex : -1
      const acts = activitiesForWaypoint(wi, title)
      const dayCount = wi >= 0 && wi < waypoints.length ? mapList(waypoints[wi].itinerary).length : 0
      if (!acts.length) summary = `${title} is currently a route anchor with no planned activities yet. Add a few stops to generate stronger recommendations.`
      else {
        const catText = categories.length ? categories.slice(0, 3).join(', ') : 'mixed activities'
        const dayText = dayCount > 0 ? `${dayCount} planned day${dayCount === 1 ? '' : 's'}` : 'this stop'
        summary = `${title} has ${acts.length} planned activit${acts.length === 1 ? 'y' : 'ies'} across ${dayText}, with a focus on ${catText}.`
      }
    }
    return { kind, title, subtitle: mapPointSubtitle(p), categories, summary }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedMapPoint, waypoints, liveData])

  // ---------- sub-renderers ----------
  const transitDetailAt = (segmentIndex: number): WP | null => {
    for (const d of routeSegmentDetails) {
      if (d.segmentIndex === segmentIndex && normalizeDetailMode(String(d.mode ?? '')) === 'transit' && Array.isArray(d.steps)) return d
    }
    const transitSegs: number[] = []
    for (let i = 0; i < waypoints.length - 1; i++) if (segmentModeAt(i) === 'transit') transitSegs.push(i)
    if (transitSegs.length === 1 && transitSegs[0] === segmentIndex && routeInstructions.length) {
      const steps = routeInstructions.map((line) => {
        const text = line.trim()
        if (!text) return null
        const lower = text.toLowerCase()
        if (lower.startsWith('walk')) return { mode: 'walking', tabLabel: 'Walk', headline: text }
        if (lower.startsWith('bike')) return { mode: 'biking', tabLabel: 'Bike', headline: text }
        return { mode: 'transit', tabLabel: 'Train', headline: text }
      }).filter(Boolean).slice(0, 6)
      return { segmentIndex, mode: 'transit', steps, ...(transitArrivalStop ? { arrivalStop: transitArrivalStop } : {}) }
    }
    return null
  }

  const transitCard = (i: number) => {
    if (i < 0 || i + 1 >= waypoints.length || segmentModeAt(i) !== 'transit') return null
    const detail = transitDetailAt(i)
    if (!detail) return null
    const steps: WP[] = (detail.steps as any[]).filter((s) => s && typeof s === 'object')
    if (!steps.length) return null
    const arr = detail.arrivalStop
    const arrivalName = arr && typeof arr === 'object' ? String(arr.name ?? arr.label ?? '') : ''
    return (
      <div style={{ padding: '0 0 6px 44px' }}>
        <TransitLegTabsCard
          originName={String(waypoints[i].name ?? `Stop ${i + 1}`)} destinationName={String(waypoints[i + 1].name ?? `Stop ${i + 2}`)} arrivalStopName={arrivalName} steps={steps}
          onStepSelected={(step) => setFocusedStep({ ...step, requestId: ++stepReq.current })}
        />
      </div>
    )
  }

  const dragFrom = useRef<number | null>(null)

  const stopTile = (i: number, wp: WP, isLast: boolean) => {
    const wpName = String(wp.name ?? `Stop ${i + 1}`)
    const roleLabel = waypointRoleLabel(i, waypoints)
    const accs = Array.isArray(wp.accommodations) ? wp.accommodations.length : 0
    const clickable = !readOnly && !editing
    const roleChip = (label: string) => <span className="td-chip">{label}</span>
    return (
      <div
        key={`wp-${i}`}
        className={cx('td-stop', clickable && 'clickable')}
        onClick={clickable ? () => openPlanning(i) : undefined}
        draggable={editing}
        onDragStart={() => { dragFrom.current = i }}
        onDragOver={(e) => editing && e.preventDefault()}
        onDrop={() => { if (editing && dragFrom.current != null) moveWaypoint(dragFrom.current, i); dragFrom.current = null }}
      >
        <div style={{ width: 34, position: 'relative', flex: 'none' }}>
          {!isLast && <div style={{ position: 'absolute', left: 16, top: 26, bottom: -10, width: 2, background: 'rgba(0,0,0,.2)' }} />}
          <div className="center" style={{ position: 'relative', width: 32, height: 32, borderRadius: 999, background: '#fff', border: '1px solid rgba(0,0,0,.13)', fontWeight: 700 }}>
            {isWaypointOnly(i, waypoints) ? <MdAltRoute size={17} /> : i + 1}
          </div>
        </div>
        <div className="grow" style={{ minWidth: 0 }}>
          <div className="row gap-sm" style={{ alignItems: 'flex-start' }}>
            {accs > 0 ? <MdHotel size={18} /> : <MdLocationCity size={18} />}
            <span style={{ fontSize: 13, fontWeight: 600 }}>{wpName}</span>
          </div>
          <div className="row wrap gap-sm" style={{ marginTop: 8 }} onClick={(e) => e.stopPropagation()}>
            {editing && canEditWaypointRole(i, waypoints) ? (
              <Menu align="left" trigger={<span className="td-chip" style={{ cursor: 'pointer' }}>{waypointIsStop(i, waypoints) ? 'Stop' : 'Waypoint'}</span>}>
                {(close) => (
                  <>
                    <MenuItem onClick={() => { close(); setWaypointRole(i, true) }}>Stop</MenuItem>
                    <MenuItem onClick={() => { close(); setWaypointRole(i, false) }}>Waypoint</MenuItem>
                  </>
                )}
              </Menu>
            ) : roleChip(roleLabel)}
          </div>
          {editing && (
            <div className="row wrap gap-sm" style={{ marginTop: 8 }} onClick={(e) => e.stopPropagation()}>
              <button className="td-icon" title="Edit destination" onClick={() => setEditWpIndex(i)}><MdEdit size={18} /></button>
              <button className="td-icon" title="Remove destination" onClick={() => removeWaypoint(i)}><MdDelete size={18} /></button>
              <button className="td-icon" title="Move up" onClick={() => moveWaypoint(i, i - 1)} disabled={i === 0}><MdArrowUpward size={18} /></button>
              <button className="td-icon" title="Move down" onClick={() => moveWaypoint(i, i + 1)} disabled={isLast}><MdArrowDownward size={18} /></button>
              <span className="td-icon" title="Drag to reorder" style={{ cursor: 'grab' }}><MdDragHandle size={18} /></span>
            </div>
          )}
        </div>
      </div>
    )
  }

  const routeControls = (
    <div className="col" style={{ gap: 4 }}>
      <div className={cx(isNarrow ? 'col' : 'row', 'gap-sm')} style={{ alignItems: isNarrow ? 'flex-start' : 'center' }}>
        <div className="row gap-sm"><MdDirections size={18} /><span style={{ fontWeight: 700, fontSize: 12 }}>{isNarrow ? 'Default transport' : 'Default'}</span></div>
        <div className="row grow" style={{ gap: 6, overflowX: 'auto', maxWidth: '100%' }}>
          {TRANSPORT_OPTIONS.map((o) => (
            <button key={o.mode} className={cx('td-mode', transportMode === o.mode && 'selected')} disabled={!canWriteTrip} onClick={() => void setTransport(o.mode)} title={o.label}>{o.emoji}</button>
          ))}
        </div>
      </div>
      <div style={{ fontSize: 11, color: 'rgba(0,0,0,.54)' }}>Set per-leg modes from Segments.</div>
      {requiresGearListForModes(segmentTransportModes, transportMode) && (
        <div className="row wrap gap-sm" style={{ marginTop: 6 }}>
          <span className="chip"><MdTerrain size={18} />Trail routing on</span>
          <span className="chip"><MdShowChart size={18} />High-vis line</span>
        </div>
      )}
      <div className="row wrap gap-sm" style={{ marginTop: 8 }}>
        <Button size="sm" variant="outlined" icon={<MdListAlt size={18} />} onClick={() => setDialog('directions')}>Directions ({routeInstructions.length})</Button>
        <Button size="sm" variant="outlined" icon={<MdAltRoute size={18} />} disabled={!canWriteTrip || waypoints.length < 2} onClick={() => setDialog('segments')}>Segments</Button>
        {canWriteTrip && routeVia.length > 0 && <Button size="sm" variant="outlined" icon={<MdClear size={18} />} onClick={clearCorrections}>Clear ({routeVia.length})</Button>}
      </div>
    </div>
  )

  const insightCard = !insight ? (
    <div style={{ padding: 10, background: 'rgba(255,255,255,.78)', borderRadius: 12, border: '1px solid rgba(0,0,0,.07)', fontSize: 12, color: 'rgba(0,0,0,.54)' }}>Tap any map pin to see a place summary.</div>
  ) : (
    <div style={{ padding: 10, background: 'rgba(255,255,255,.82)', borderRadius: 12, border: '1px solid rgba(0,0,0,.09)' }}>
      <div className="row gap-sm">
        {insight.kind === 'activity' ? <MdLocalActivity size={16} /> : insight.kind === 'accommodation' ? <MdHotel size={16} /> : <MdPlace size={16} />}
        <span style={{ fontSize: 12, fontWeight: 700 }}>Place Insight</span>
        <span className="grow" />
        <MdAutoAwesome size={14} color="rgba(0,0,0,.54)" />
      </div>
      <div style={{ fontSize: 14, fontWeight: 700, marginTop: 8 }}>{insight.title}</div>
      {insight.subtitle && <div style={{ fontSize: 12, color: 'rgba(0,0,0,.54)', marginTop: 2 }}>{insight.subtitle}</div>}
      <div style={{ fontSize: 11, fontWeight: 700, marginTop: 8 }}>AI Summary</div>
      <div style={{ fontSize: 12, marginTop: 4 }}>{insight.summary}</div>
      {insight.categories.length > 0 && (
        <>
          <div style={{ fontSize: 11, fontWeight: 700, marginTop: 8 }}>Activity Categories</div>
          <div className="row wrap" style={{ gap: 6, marginTop: 6 }}>
            {insight.categories.slice(0, 6).map((c) => <span key={c} style={{ padding: '4px 8px', borderRadius: 999, background: 'rgba(0,0,0,.06)', fontSize: 11, fontWeight: 600 }}>{c}</span>)}
          </div>
        </>
      )}
    </div>
  )

  const routeHeader = (
    <div className="row gap-sm">
      <span style={{ fontWeight: 800, fontSize: 14 }}>Route</span>
      <span style={{ fontSize: 12, color: 'rgba(0,0,0,.54)' }}>{waypoints.length} destinations</span>
      <span className="grow" />
      {!readOnly && <button className="icon-btn" title={editing ? 'Done' : 'Edit'} disabled={!canWriteTrip} onClick={() => setEditing((e) => !e)}>{editing ? <MdCheck size={22} /> : <MdEdit size={22} />}</button>}
      {editing && !readOnly && <button className="icon-btn" title="Save" disabled={saving} onClick={saveAll}><MdSave size={22} /></button>}
    </div>
  )

  const stopList = (
    <div>
      {waypoints.map((wp, i) => (
        <div key={`row-${i}`}>
          {stopTile(i, wp, i === waypoints.length - 1)}
          {!editing && i < waypoints.length - 1 && transitCard(i)}
        </div>
      ))}
    </div>
  )

  // mobile bottom sheet drag
  const sheetDrag = useRef<{ startY: number; startExtent: number } | null>(null)
  const SNAPS = [0.18, 0.4, 0.75]
  const onSheetPointerDown = (e: React.PointerEvent) => {
    sheetDrag.current = { startY: e.clientY, startExtent: sheetExtent }
    ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
  }
  const onSheetPointerMove = (e: React.PointerEvent) => {
    const d = sheetDrag.current
    if (!d) return
    const delta = (d.startY - e.clientY) / window.innerHeight
    setSheetExtent(Math.min(0.75, Math.max(0.18, d.startExtent + delta)))
  }
  const onSheetPointerUp = () => {
    if (!sheetDrag.current) return
    sheetDrag.current = null
    setSheetExtent((cur) => SNAPS.reduce((best, s) => (Math.abs(s - cur) < Math.abs(best - cur) ? s : best), SNAPS[0]))
  }

  // ---------- read-only banner ----------
  const readOnlyBanner = (compact: boolean) => (
    <div className="td-glass" style={{ borderRadius: compact ? 18 : 999, padding: compact ? 12 : '6px 12px' }}>
      <div className={cx('row', 'gap-sm')} style={{ flexWrap: 'wrap' }}>
        <MdLockOutline size={16} />
        <span style={{ fontWeight: 600, fontSize: 13 }}>Read-only preview</span>
        <button className="btn btn-sm" style={{ background: '#111827', color: '#fff', borderRadius: 999 }} onClick={() => navigate('/sign-in')}><MdLogin size={16} />Sign in to join</button>
      </div>
    </div>
  )

  const searchBox = (
    <div style={{ position: 'relative' }}>
      <div className="td-glass" style={{ borderRadius: 999, padding: '4px 8px' }}>
        <div className="row gap-sm">
          <MdSearch size={20} style={{ marginLeft: 6 }} />
          <input className="td-search" placeholder="Search locations, hotels, or activities..." value={searchText} onChange={(e) => setSearchText(e.target.value)} />
          {searching ? <Spinner size="sm" /> : searchText.trim() ? <button className="icon-btn" title="Clear" onClick={() => { setSearchText(''); setSuggestions([]) }}><MdClose size={18} /></button> : null}
        </div>
      </div>
      {suggestions.length > 0 && (
        <div className="td-glass" style={{ marginTop: 8, borderRadius: 16, padding: 0, maxHeight: 320, overflowY: 'auto', position: 'absolute', left: 0, right: 0 }}>
          {suggestions.map((p, i) => (
            <button key={i} className="menu-item" style={{ borderTop: i ? '1px solid var(--border)' : undefined, fontSize: 13 }} onClick={() => onSelectSuggestion(p)}>{p.display_name}</button>
          ))}
        </div>
      )}
    </div>
  )

  const quickActionButtons = (
    <div className="td-glass row" style={{ borderRadius: 999, padding: '2px 6px' }}>
      <button className="icon-btn" title="Plan trip" onClick={() => openPlanning()}><MdEditNote size={22} /></button>
      <button className="icon-btn" title="Packing list" onClick={() => setDialog('packing')}><MdList size={22} /></button>
      <button className="icon-btn" title="Expenses" onClick={() => setDialog('expenses')}><MdPieChart size={22} /></button>
      <button className="icon-btn" title="Chat" onClick={() => setDialog('chat')}><MdChat size={22} /></button>
      <button className="icon-btn" title="Share trip" onClick={() => setDialog('share')}><MdShare size={22} /></button>
    </div>
  )

  const mapToggle = (
    <div className="td-glass row" style={{ borderRadius: 999, padding: 4, gap: 6 }}>
      {([['map2d', '2D', <MdOutlineMap size={16} key="a" />], ['globe3d', '3D', <MdPublic size={16} key="b" />]] as const).map(([m, label, icon]) => (
        <button key={m} className={cx('td-toggle', mapMode === m && 'selected')} onClick={() => setMapMode(m)}>{icon}{label}</button>
      ))}
    </div>
  )

  const backBtn = <div className="td-glass" style={{ borderRadius: 999, padding: 0 }}><button className="icon-btn" title="Back" onClick={back}><MdArrowBack size={22} /></button></div>

  const mapEl = !showMapLayer ? (
    <div style={{ position: 'absolute', inset: 0, background: 'linear-gradient(#f8fafc,#eff4fa)' }} />
  ) : mapMode === 'globe3d' ? (
    <Globe3DEmbed points={mapPoints} secondaryPoints={secondaryPoints} routeGeometry={routeGeometry} transportMode={transportMode.toUpperCase()} onMapTap={editing ? addWaypointFromTap : undefined} />
  ) : (
    <MapEmbed
      points={mapPoints}
      transportMode={transportMode}
      segmentTransportModes={segmentTransportModes}
      routeVia={routeVia}
      segmentRoutingTypes={segmentRoutingTypes}
      initialRouteGeometry={routeGeometry}
      initialRouteInstructions={routeInstructions}
      initialRouteSegmentDetails={routeSegmentDetails}
      preferInitialRouteData={canUseCachedRoute}
      onRouteInstructions={(lines) => {
        const next = lines.map((l) => l.trim()).filter(Boolean).slice(0, 8)
        if (sameInstr(next) && cacheKeyCurrent) return
        setRouteInstructions(next)
        setLiveData((cur) => ({ ...cur, routeInstructions: next, routeCacheKey }))
        schedulePersist()
      }}
      onRouteSegmentDetails={(segments) => {
        const next = readRouteSegmentDetails(segments)
        if (sameDetails(next) && cacheKeyCurrent) return
        setRouteSegmentDetails(next)
        setLiveData((cur) => ({ ...cur, routeSegmentDetails: next, routeCacheKey }))
        schedulePersist()
      }}
      onRouteGeometry={(geometry) => {
        const simplified = simplifyRouteGeometry(geometry)
        if (samePath(simplified) && cacheKeyCurrent) return
        setRouteGeometry(simplified)
        setLiveData((cur) => ({ ...cur, routeGeometry3d: simplified, routeCacheKey }))
        schedulePersist()
      }}
      onTransitArrivalStop={(stop) => {
        const resolved = Object.keys(stop).length ? stop : null
        setTransitArrivalStop(resolved)
        if (hasTransitInRoute) void persistArrival(resolved ?? {})
      }}
      focusedRouteStep={focusedStep}
      secondaryPoints={secondaryPoints}
      onPointTap={(p) => setSelectedMapPoint({ ...p })}
      showNearbyContextOverlays={false}
      onMapTap={editing ? addWaypointFromTap : undefined}
      onRouteTapAddVia={!editing && canWriteTrip ? upsertVia : undefined}
      onViaDragEnd={!editing && canWriteTrip ? moveVia : undefined}
      onViaTapDelete={!editing && canWriteTrip ? deleteVia : undefined}
      routeComputingBannerTop={isNarrow ? 164 : 112}
    />
  )

  const saveBtn = readOnly ? null : (
    <button className="btn" style={{ background: '#111827', color: '#fff', borderRadius: 999, padding: '12px 16px' }} onClick={saveAll} disabled={saving}>
      {saving ? <Spinner size="sm" white /> : <MdAutoAwesome size={18} />}{saving ? 'Saving…' : 'Save Trip'}
    </button>
  )
  const statsPill = <div className="td-glass" style={{ borderRadius: 999, padding: '10px 12px', fontWeight: 700 }}>{waypoints.length} Destinations | {Number.isFinite(totalKm) ? totalKm.toFixed(0) : 0} km</div>

  const bottomOffset = isNarrow ? Math.min(window.innerHeight * 0.78, Math.max(108, window.innerHeight * sheetExtent + 12)) : 24

  return (
    <div className="td-screen">
      <div className="td-map">{mapEl}</div>

      {isNarrow ? (
        <div className="td-top-mobile">
          <div className="row gap-sm">
            {backBtn}
            <div className="td-glass grow" style={{ borderRadius: 999, padding: '10px 14px' }}><div className="ellipsis" style={{ fontWeight: 800 }}>{name}</div></div>
            {!readOnly && (
              <div className="td-glass" style={{ borderRadius: 999, padding: 0 }}>
                <Menu trigger={<button className="icon-btn" title="Trip actions"><MdMoreHoriz size={22} /></button>}>
                  {(close) => (
                    <>
                      {([['plan', 'Plan trip'], ['packing', 'Packing list'], ['expenses', 'Expenses'], ['chat', 'Chat'], ['share', 'Share trip']] as [QuickAction, string][]).map(([a, l]) => (
                        <MenuItem key={a} onClick={() => { close(); handleQuickAction(a) }}>{l}</MenuItem>
                      ))}
                    </>
                  )}
                </Menu>
              </div>
            )}
          </div>
          {!readOnly ? searchBox : readOnlyBanner(true)}
          <div style={{ alignSelf: 'flex-end' }}>{mapToggle}</div>
        </div>
      ) : (
        <>
          {!readOnly && <div className="td-top-center">{searchBox}</div>}
          <div className="td-top-left">
            {backBtn}
            <div className="td-glass" style={{ borderRadius: 999, padding: '10px 14px', maxWidth: 280 }}><div className="ellipsis" style={{ fontWeight: 800 }}>{name}</div></div>
          </div>
          {!readOnly ? <div className="td-top-right">{quickActionButtons}</div> : <div className="td-top-right">{readOnlyBanner(false)}</div>}
          <div className="td-toggle-pos">{mapToggle}</div>
        </>
      )}

      {!isNarrow ? (
        <div className="td-dock td-glass col" style={{ padding: '10px 12px 12px' }}>
          {routeHeader}
          <div style={{ marginTop: 8 }}>{routeControls}</div>
          <div style={{ marginTop: 8 }}>{insightCard}</div>
          <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', marginTop: 8, borderRadius: 12 }}>{stopList}</div>
        </div>
      ) : (
        <div className="td-sheet td-glass" style={{ height: `${sheetExtent * 100}%`, transition: sheetDrag.current ? 'none' : 'height .2s' }}>
          <div className="center" style={{ touchAction: 'none', cursor: 'grab', padding: '2px 0 8px' }} onPointerDown={onSheetPointerDown} onPointerMove={onSheetPointerMove} onPointerUp={onSheetPointerUp}>
            <div style={{ width: 36, height: 4, borderRadius: 999, background: 'rgba(0,0,0,.26)' }} />
          </div>
          <div style={{ overflowY: 'auto', flex: 1, minHeight: 0 }}>
            {routeHeader}
            <div style={{ marginTop: 8 }}>{routeControls}</div>
            <div style={{ margin: '8px 0' }}>{insightCard}</div>
            {stopList}
            <div style={{ height: 16 }} />
          </div>
        </div>
      )}

      <div className={isNarrow ? 'td-actions-mobile' : 'td-actions'} style={{ bottom: bottomOffset }}>
        <div className={isNarrow ? 'td-glass col' : 'row gap-md'} style={isNarrow ? { borderRadius: 24, padding: '10px 12px 12px', gap: 10, alignItems: 'stretch' } : undefined}>
          <div className={isNarrow ? 'center' : undefined}>{statsPill}</div>
          {saveBtn}
        </div>
      </div>
      {readOnly && !isNarrow && null}

      {/* dialogs */}
      {dialog === 'share' && <ShareTripDialog open onClose={() => setDialog(null)} tripRefPath={tripRefPath} tripId={docId} tripName={String(liveData.name ?? data.name ?? '')} />}
      {dialog === 'chat' && <TripChatDialog open onClose={() => setDialog(null)} tripRefPath={tripRefPath} />}
      {dialog === 'expenses' && user && <TripExpensesDialog open onClose={() => setDialog(null)} tripRefPath={tripRefPath} currentUid={user.uid} participants={collectParticipants()} />}
      {dialog === 'packing' && <PackingListDialog open onClose={() => setDialog(null)} tripRefPath={tripRefPath} participants={collectParticipants()} />}

      <Dialog open={dialog === 'directions'} onClose={() => setDialog(null)} title="Directions" actions={<Button variant="text" onClick={() => setDialog(null)}>Close</Button>} contentStyle={{ minHeight: 280 }}>
        {hasTransitInRoute && String(transitArrivalStop?.name ?? transitArrivalStop?.label ?? '').trim() && (
          <div style={{ fontWeight: 700, marginBottom: 8 }}>Arrive at: {String(transitArrivalStop?.name ?? transitArrivalStop?.label).trim()}</div>
        )}
        {routeInstructions.length === 0 ? <div className="center muted" style={{ padding: 24 }}>No directions yet. Add stops or wait for routing to load.</div> : routeInstructions.map((s, i) => (
          <div key={i} className="row gap-md" style={{ padding: '8px 0', borderTop: i ? '1px solid var(--border)' : undefined, fontSize: 13 }}>
            <b>{i + 1}</b><span>{s}</span>
          </div>
        ))}
      </Dialog>

      <Dialog open={dialog === 'segments'} onClose={() => setDialog(null)} size="wide" title="Segment settings" actions={<Button variant="text" onClick={() => setDialog(null)}>Close</Button>}>
        <p className="muted" style={{ marginBottom: 10 }}>Set travel mode per leg. Calculated follows roads/trails; Direct draws a straight line.</p>
        {Array.from({ length: Math.max(0, waypoints.length - 1) }, (_, i) => {
          const a = String(waypoints[i].name ?? `Stop ${i + 1}`)
          const b = String(waypoints[i + 1].name ?? `Stop ${i + 2}`)
          const cur = segmentTypeAt(i)
          return (
            <div key={i} className="seg-row">
              <div>
                <div style={{ fontWeight: 800 }}>{i + 1} → {i + 2}</div>
                <div className="muted" style={{ marginTop: 4 }}>{a} → {b}</div>
              </div>
              <div className="col gap-sm">
                <select className="select" value={segmentModeAt(i)} onChange={(e) => void setSegmentMode(i, e.target.value)}>
                  {TRANSPORT_OPTIONS.map((o) => <option key={o.mode} value={o.mode}>{o.emoji} {o.label}</option>)}
                </select>
                <div className="row gap-sm">
                  <button className={cx('chip', cur === 'calculated' && 'selected')} onClick={() => void setSegmentRoutingType(i, 'calculated')}>Calculated</button>
                  <button className={cx('chip', cur === 'direct' && 'selected')} onClick={() => void setSegmentRoutingType(i, 'direct')}>Direct</button>
                </div>
              </div>
            </div>
          )
        })}
      </Dialog>

      {editWpIndex != null && waypoints[editWpIndex] && (
        <EditWaypointDialog
          waypoint={waypoints[editWpIndex]}
          onClose={() => setEditWpIndex(null)}
          onSave={(patch) => { setWps(waypoints.map((wp, i) => (i === editWpIndex ? { ...wp, ...patch } : wp))); setEditWpIndex(null) }}
        />
      )}
      {isOwner && null}
    </div>
  )
}

function EditWaypointDialog({ waypoint, onClose, onSave }: { waypoint: WP; onClose: () => void; onSave: (patch: WP) => void }) {
  const [name, setName] = useState(String(waypoint.name ?? ''))
  const [query, setQuery] = useState('')
  const [loading, setLoading] = useState(false)
  const [results, setResults] = useState<PlaceResult[]>([])
  useEffect(() => {
    const q = query.trim()
    if (!q) return setResults([])
    const t = setTimeout(async () => {
      setLoading(true)
      try { setResults((await searchPlaces(q)).slice(0, 6)) } catch { setResults([]) } finally { setLoading(false) }
    }, 350)
    return () => clearTimeout(t)
  }, [query])
  return (
    <Dialog open onClose={onClose} title="Edit waypoint" actions={<><Button variant="text" onClick={onClose}>Cancel</Button><Button variant="solid" onClick={() => onSave({ name })}>Save</Button></>}>
      <div className="col gap-md">
        <input className="input" placeholder="Name" value={name} onChange={(e) => setName(e.target.value)} />
        <div className="input-wrap">
          <span className="input-icon"><MdSearch size={20} /></span>
          <input className="input" placeholder="Search place to update location" value={query} onChange={(e) => setQuery(e.target.value)} />
        </div>
        {loading && <Spinner size="sm" />}
        {results.length > 0 && (
          <div style={{ maxHeight: 200, overflowY: 'auto', border: '1px solid var(--border)', borderRadius: 8 }}>
            {results.map((p, i) => (
              <button key={i} className="menu-item" style={{ borderTop: i ? '1px solid var(--border)' : undefined }} onClick={() => onSave({ name: p.display_name, routing_query: p.display_name, lat: p.lat, lon: p.lon })}>{p.display_name}</button>
            ))}
          </div>
        )}
      </div>
    </Dialog>
  )
}

/** Route wrapper for `/my-trips/:tripId` — uses router state when present, else loads the doc. */
export function TripDetailRoute() {
  const { tripId = '' } = useParams()
  const location = useLocation()
  const { user, loading } = useAuth()
  const navigate = useNavigate()
  const state = (location.state ?? {}) as { data?: Record<string, any> }
  const [data, setData] = useState<Record<string, any> | null>(state.data ?? null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (data || loading) return
    if (!user) {
      setError('sign-in')
      return
    }
    getDoc(doc(db, 'users', user.uid, 'trips', tripId))
      .then((s) => (s.exists() ? setData(s.data()) : setError('Trip not found')))
      .catch((e) => setError(e?.message ?? 'Failed to load trip'))
  }, [data, loading, user, tripId])

  if (data) return <TripDetailScreen docId={tripId} data={data} />
  if (error) {
    return (
      <div className="center col gap-md" style={{ height: '100vh' }}>
        <p>{error === 'sign-in' ? 'Sign in to view this trip.' : error}</p>
        <Button onClick={() => navigate(error === 'sign-in' ? '/sign-in' : '/my-trips')}>{error === 'sign-in' ? 'Sign in' : 'Back to My Trips'}</Button>
      </div>
    )
  }
  return <div className="center" style={{ height: '100vh' }}><Spinner /></div>
}

void auth
