import { useEffect, useMemo, useRef, useState } from 'react'
import { collection, doc, getDoc, serverTimestamp, setDoc, updateDoc } from 'firebase/firestore'
import { getDownloadURL, ref, uploadBytes } from 'firebase/storage'
import { useLocation, useNavigate, useParams } from 'react-router-dom'
import { MdAdd, MdAltRoute, MdArrowBack, MdClear, MdDeleteOutline, MdOutlineEdit, MdPlace, MdSearch, MdUpload } from 'react-icons/md'
import { auth, db, storage } from '@/firebase'
import { useFeedback } from '@/context/Feedback'
import { Dialog } from '@/components/Dialog'
import { Button, SoftCard, Spinner, cx } from '@/components/ui'
import MapEmbed from '@/components/map/MapEmbed'
import { searchNominatim } from '@/services/geocode'
import { getRouteOptions } from '@/services/routeOptions'
import { pickImageDataUrl } from '@/lib/image'
import { dataUrlToBlob } from '@/lib/files'
import { TRAVEL_CATEGORIES, formatDurationShort } from '@/lib/planning'
import {
  BUILDER_TRANSPORT_OPTIONS, coerceCoord, containsHikingKeyword, filterHikingResults, haversineKm, hikingBiasedQuery, normalizeBuilderMode,
  type SearchResult,
} from '@/lib/tripBuilder'

type Row = Record<string, any>
interface Waypoint { name: string; lat: number; lon: number; days: number }

const PORTAGE_KEYWORDS = ['portage', 'carry', 'canoe carry', 'put-in', 'put in', 'take-out', 'take out', 'carry trail']
const VERIFIED_CATEGORIES = Object.keys(TRAVEL_CATEGORIES).filter((c) => !['Transit', 'Free Time'].includes(c))

const isPortageInstruction = (raw: string) => {
  const t = raw.trim().toLowerCase()
  if (!t) return false
  if (PORTAGE_KEYWORDS.some((k) => t.includes(k))) return true
  return t.includes('trail') && (t.includes('lake') || t.includes('canoe') || t.includes('paddle'))
}

function instructionDistanceKm(raw: string): number {
  const m = /(\d+(?:[.,]\d+)?)\s*(km|m|mi|ft)\b/i.exec(raw)
  if (!m) return 0
  const v = parseFloat(m[1].replace(',', '.'))
  if (!Number.isFinite(v) || v <= 0) return 0
  switch (m[2].toLowerCase()) {
    case 'km': return v
    case 'm': return v / 1000
    case 'mi': return v * 1.60934
    case 'ft': return v * 0.0003048
    default: return 0
  }
}

function analyzePortages(instructions: string[]) {
  let portageCount = 0, portageDistanceKm = 0, longestPortageKm = 0
  const snippets: string[] = []
  for (const ins of instructions) {
    if (!isPortageInstruction(ins)) continue
    portageCount++
    const d = instructionDistanceKm(ins)
    if (d > 0) {
      portageDistanceKm += d
      longestPortageKm = Math.max(longestPortageKm, d)
    }
    if (snippets.length < 3) snippets.push(ins)
  }
  return { portageCount, portageDistanceKm, longestPortageKm, portageSnippets: snippets }
}

const routeOptionsMode = (mode: string) => {
  switch (mode) {
    case 'train': return 'transit'
    case 'walk': return 'walking'
    case 'bike': return 'biking'
    case 'hiking': return 'hiking'
    case 'portaging': return 'portaging'
    default: return 'driving'
  }
}

const newDay = (n: number): Row => ({ title: `Day ${n}`, notes: '', activities: [] })

function ImagePreview({ url, height }: { url: string; height?: number }) {
  const [failed, setFailed] = useState(false)
  const u = url.trim()
  if (!u) return <div style={{ height }} />
  if (failed) return <div className="center" style={{ height, background: 'rgba(0,0,0,0.08)', borderRadius: 12 }}>Image failed to load</div>
  return <img src={u} alt="" onError={() => setFailed(true)} style={{ width: '100%', height, objectFit: 'cover', borderRadius: 12, display: 'block' }} />
}

// ---- Dialogs --------------------------------------------------------------------------------------

function DaysDialog({ locationName, initial, onResult }: { locationName: string; initial: number; onResult: (v: number | null) => void }) {
  const [v, setV] = useState(Math.max(1, Math.min(21, initial)))
  return (
    <Dialog title="Recommended days here" onClose={() => onResult(null)} actions={<><Button variant="text" onClick={() => onResult(null)}>Cancel</Button><Button variant="text" onClick={() => onResult(v)}>Add</Button></>}>
      <div style={{ marginBottom: 12 }}>{locationName}</div>
      <div className="row gap-md" style={{ alignItems: 'center' }}>
        <span>Days:</span>
        <select className="select" value={v} onChange={(e) => setV(Number(e.target.value))}>{Array.from({ length: 21 }, (_x, i) => <option key={i} value={i + 1}>{i + 1} day{i === 0 ? '' : 's'}</option>)}</select>
      </div>
    </Dialog>
  )
}

interface ActivityForm { time: string; title: string; description: string; location: string; category: string; lat: string; lon: string }

function ActivityDialog({ dayTitle, initial, onResult }: { dayTitle: string; initial?: Row; onResult: (v: ActivityForm | null) => void }) {
  const [time, setTime] = useState(String(initial?.time ?? ''))
  const [title, setTitle] = useState(String(initial?.title ?? ''))
  const [description, setDescription] = useState(String(initial?.description ?? ''))
  const [location, setLocation] = useState(String(initial?.location ?? ''))
  const [category, setCategory] = useState(String(initial?.category ?? '') || 'Sightseeing')
  const [selected, setSelected] = useState<SearchResult | null>(null)
  const [suggestions, setSuggestions] = useState<SearchResult[]>([])
  const [searching, setSearching] = useState(false)
  const debounce = useRef<ReturnType<typeof setTimeout>>(undefined)
  useEffect(() => () => clearTimeout(debounce.current), [])

  const onLocation = (v: string) => {
    setLocation(v)
    clearTimeout(debounce.current)
    if (!v.trim()) { setSuggestions([]); setSelected(null); return }
    debounce.current = setTimeout(async () => {
      setSearching(true)
      try { setSuggestions(await searchNominatim(v.trim())) } catch { setSuggestions([]) }
      setSearching(false)
    }, 400)
  }

  return (
    <Dialog
      title="Edit Activity" onClose={() => onResult(null)}
      actions={
        <>
          <Button variant="text" onClick={() => onResult(null)}>Cancel</Button>
          <Button variant="text" onClick={() => title.trim() && onResult({ time: time.trim(), title: title.trim(), description: description.trim(), location: location.trim(), category, lat: selected ? String(selected.lat) : '', lon: selected ? String(selected.lon) : '' })}>Save</Button>
        </>
      }
    >
      <div className="muted" style={{ fontSize: 12, marginBottom: 12 }}>{dayTitle}</div>
      <div className="col gap-md">
        <div className="field"><label>Time (e.g. 9:00 AM)</label><input className="input" value={time} onChange={(e) => setTime(e.target.value)} /></div>
        <div className="field"><label>Title</label><input className="input" value={title} onChange={(e) => setTitle(e.target.value)} autoFocus /></div>
        <div className="field"><label>Category</label><select className="select" value={category} onChange={(e) => setCategory(e.target.value)}>{VERIFIED_CATEGORIES.map((c) => <option key={c}>{c}</option>)}</select></div>
        <div className="field">
          <label>Location (optional - add to map) {searching && <Spinner size="sm" />}</label>
          <input className="input" value={location} onChange={(e) => onLocation(e.target.value)} />
          {suggestions.length > 0 && (
            <div style={{ maxHeight: 150, overflowY: 'auto', border: '1px solid var(--border)', borderRadius: 8, marginTop: 6 }}>
              {suggestions.map((s, i) => (
                <div key={i} className="tb-result" style={{ padding: '8px 10px', fontSize: 13 }} onClick={() => { setLocation(String(s.name ?? '')); setSelected(s); setSuggestions([]) }}>{String(s.name ?? '')}</div>
              ))}
            </div>
          )}
        </div>
        <div className="field"><label>Description (optional)</label><textarea className="textarea" rows={3} value={description} onChange={(e) => setDescription(e.target.value)} /></div>
      </div>
    </Dialog>
  )
}

function RouteChoicesDialog({ segmentIndex, waypoints, mode, preferred, tapped, load, onChoose, onDropPin, onClose }: {
  segmentIndex: number
  waypoints: Waypoint[]
  mode: string
  preferred: Row | undefined
  tapped: { lat: number; lon: number } | null
  load: (force: boolean) => Promise<Row[]>
  onChoose: (option: Row) => void
  onDropPin: () => void
  onClose: () => void
}) {
  const [options, setOptions] = useState<Row[] | null>(null)
  const refresh = (force: boolean) => { setOptions(null); void load(force).then(setOptions) }
  useEffect(() => refresh(false), []) // eslint-disable-line react-hooks/exhaustive-deps
  const hasSingle = !!options?.some((o) => o.portagePattern === 'single_long')
  const hasMulti = !!options?.some((o) => o.portagePattern === 'multi_short')
  void waypoints; void mode
  return (
    <Dialog
      title={`Leg ${segmentIndex + 1} route options`} size="wide" onClose={onClose}
      actions={<><Button variant="text" onClick={onClose}>Close</Button>{tapped && <Button variant="text" onClick={onDropPin}>Drop pin at tap</Button>}<Button variant="text" onClick={() => refresh(true)}>Refresh</Button></>}
    >
      {options == null ? <div className="center" style={{ padding: 16 }}><Spinner /></div>
        : options.length === 0 ? <div>No live route alternatives found right now. You can still drop a pin to force a preferred lake or portage line.</div>
        : (
          <div>
            <div className="muted" style={{ fontSize: 12 }}>Choose your preferred portage style for this leg.</div>
            {hasSingle && hasMulti && <div style={{ fontSize: 12, fontWeight: 700, color: '#00695C', marginTop: 4 }}>Detected both styles: one long carry vs multiple short carries.</div>}
            <div style={{ marginTop: 10 }}>
              {options.map((o, i) => {
                const selected = preferred?.sourceIndex === o.sourceIndex
                const pc = Number(o.portageCount) || 0
                const dur = formatDurationShort(Number(o.durationSeconds) || 0)
                return (
                  <div key={i} style={{ marginBottom: 8, padding: 10, borderRadius: 10, background: selected ? 'rgba(74,173,232,0.08)' : '#fff', border: `1px solid ${selected ? 'var(--primary)' : '#d4d4d8'}` }}>
                    <div className="row" style={{ gap: 8 }}>
                      <b className="grow">{String(o.summary ?? 'Route option')}</b>
                      {o.portagePattern === 'single_long' && <span className="chip" style={{ background: 'rgba(0,137,123,0.12)', color: '#00695C', fontSize: 11, fontWeight: 700 }}>1 long portage</span>}
                      {o.portagePattern === 'multi_short' && <span className="chip" style={{ background: 'rgba(0,137,123,0.12)', color: '#00695C', fontSize: 11, fontWeight: 700 }}>multi short portages</span>}
                    </div>
                    <div className="row wrap" style={{ gap: 8, marginTop: 4 }}>
                      <span>{((Number(o.distanceMeters) || 0) / 1000).toFixed(1)} km</span>
                      {dur && <span>{dur}</span>}
                      <span>{pc > 0 ? `${pc} portage${pc === 1 ? '' : 's'}` : 'no explicit portage steps'}</span>
                      {Number(o.portageDistanceKm) > 0 && <span>~{Number(o.portageDistanceKm).toFixed(1)} km carry</span>}
                    </div>
                    {(o.portageSnippets as string[] | undefined)?.slice(0, 2).map((l, k) => <div key={k} className="muted" style={{ fontSize: 12, marginTop: 6 }}>• {l}</div>)}
                    <div style={{ textAlign: 'right', marginTop: 8 }}><Button variant="outlined" size="sm" onClick={() => onChoose(o)}>{selected ? 'Selected' : 'Choose'}</Button></div>
                  </div>
                )
              })}
            </div>
          </div>
        )}
    </Dialog>
  )
}

// ---- Builder --------------------------------------------------------------------------------------

function Builder({ existingId, existing }: { existingId?: string; existing?: Row }) {
  const navigate = useNavigate()
  const { toast, confirm } = useFeedback()
  const isEditing = !!existingId

  const initial = useMemo(() => {
    const d = existing ?? {}
    const wps: Waypoint[] = (Array.isArray(d.waypoints) ? d.waypoints : [])
      .filter((w: any) => w && typeof w === 'object' && String(w.name ?? ''))
      .map((w: any) => ({ name: String(w.name), lat: typeof w.lat === 'number' ? w.lat : 0, lon: typeof w.lon === 'number' ? w.lon : 0, days: typeof w.days === 'number' ? Math.trunc(w.days) : 2 }))
    const itinerary: Row[] = (Array.isArray(d.itinerary) ? d.itinerary : []).filter((x: any) => x && typeof x === 'object').map((day: any) => ({
      title: String(day.title ?? ''), notes: String(day.notes ?? ''),
      activities: (Array.isArray(day.activities) ? day.activities : []).filter((a: any) => a && typeof a === 'object').map((a: any) => ({ time: String(a.time ?? ''), title: String(a.title ?? ''), description: String(a.description ?? ''), ...(a.location ? { location: String(a.location) } : {}), ...(a.category ? { category: String(a.category) } : {}), ...(a.locationLat != null ? { locationLat: a.locationLat } : {}), ...(a.locationLon != null ? { locationLon: a.locationLon } : {}) })),
    }))
    const prefs: Record<number, Row> = {}
    for (const raw of Array.isArray(d.segmentRoutePreferences) ? d.segmentRoutePreferences : []) {
      const idx = Number(raw?.segmentIndex)
      if (Number.isFinite(idx) && idx >= 0) prefs[idx] = { ...raw }
    }
    return {
      title: String(d.title ?? ''), subtitle: String(d.subtitle ?? ''), description: String(d.description ?? ''), cover: String(d.coverImage ?? ''),
      mode: normalizeBuilderMode(String(d.transportMode ?? 'car')),
      photos: (Array.isArray(d.photos) ? d.photos : []).filter((p: any) => typeof p === 'string' && p) as string[],
      wps, itinerary,
      via: (Array.isArray(d.routeVia) ? d.routeVia : []).filter((v: any) => v && typeof v === 'object').map((v: any) => ({ ...v })) as Row[],
      segRouting: (Array.isArray(d.segmentRoutingTypes) ? d.segmentRoutingTypes : []).map(String) as string[],
      segModes: (Array.isArray(d.segmentTransportModes) ? d.segmentTransportModes : []).map(String) as string[],
      prefs,
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const [title, setTitle] = useState(initial.title)
  const [subtitle, setSubtitle] = useState(initial.subtitle)
  const [description, setDescription] = useState(initial.description)
  const [coverImage, setCoverImage] = useState(initial.cover)
  const [photos, setPhotos] = useState<string[]>(initial.photos)
  const [waypoints, setWaypoints] = useState<Waypoint[]>(initial.wps)
  const [itinerary, setItinerary] = useState<Row[]>(initial.itinerary)
  const [transportMode, setTransportMode] = useState(initial.mode)
  const [adjustRoute, setAdjustRoute] = useState(false)
  const [routeVia, setRouteVia] = useState<Row[]>(initial.via)
  const [routeInstructions, setRouteInstructions] = useState<string[]>([])
  const [segRouting, setSegRouting] = useState<string[]>(initial.segRouting)
  const [segModes, setSegModes] = useState<string[]>(initial.segModes)
  const [activeSeg, setActiveSeg] = useState(0)
  const [distanceKm, setDistanceKm] = useState<number | null>(null)
  const [durationMin, setDurationMin] = useState<number | null>(null)
  const [prefs, setPrefs] = useState<Record<number, Row>>(initial.prefs)
  const [saving, setSaving] = useState(false)
  const [errors, setErrors] = useState<{ title?: string; description?: string }>({})
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<SearchResult[]>([])
  const [dialog, setDialog] = useState<
    | { kind: 'days'; name: string; initial: number; resolve: (v: number | null) => void }
    | { kind: 'activity'; dayTitle: string; initial?: Row; resolve: (v: ActivityForm | null) => void }
    | { kind: 'routes'; segmentIndex: number; tapped: { lat: number; lon: number } | null }
    | null
  >(null)
  const optionsCache = useRef<Record<number, Row[]>>({})
  const [expandedDay, setExpandedDay] = useState<number | null>(null)

  const segmentCount = Math.max(0, waypoints.length - 1)
  const selectedSeg: number | null = segmentCount <= 0 ? null : activeSeg < 0 || activeSeg >= segmentCount ? 0 : activeSeg
  const recommendedDays = waypoints.reduce((t, w) => t + w.days, 0)
  const totalKm = useMemo(() => { let t = 0; for (let i = 1; i < waypoints.length; i++) t += haversineKm(waypoints[i - 1].lat, waypoints[i - 1].lon, waypoints[i].lat, waypoints[i].lon); return t }, [waypoints])
  const km = distanceKm ?? totalKm

  const segModeAt = (i: number) => (i < 0 || i >= segModes.length ? normalizeBuilderMode(transportMode) : normalizeBuilderMode(segModes[i]))
  const isHikingTrailSegment = (i: number, wps = waypoints) => {
    if (i < 0 || i + 1 >= wps.length) return false
    if (containsHikingKeyword(wps[i].name) || containsHikingKeyword(wps[i + 1].name)) return true
    const m = segModeAt(i)
    return m === 'hiking' || m === 'portaging'
  }
  // Car is only blocked when the primary mode is itself a backcountry mode (differs from the trip builder).
  const isCarBlocked = (i: number) => {
    const primary = normalizeBuilderMode(transportMode)
    return (primary === 'hiking' || primary === 'portaging') && isHikingTrailSegment(i)
  }

  /** Re-aligns per-leg arrays with the waypoint list (call with the next waypoint list). */
  const syncRouting = (wps: Waypoint[], modes = segModes, routing = segRouting, via = routeVia, primary = transportMode) => {
    const count = Math.max(0, wps.length - 1)
    const fallback = normalizeBuilderMode(primary)
    const nextRouting = routing.slice(0, count)
    while (nextRouting.length < count) nextRouting.push('calculated')
    setSegRouting(nextRouting.map((v) => (v.trim().toLowerCase() === 'direct' ? 'direct' : 'calculated')))
    let nextModes = modes.slice(0, count)
    while (nextModes.length < count) nextModes.push(fallback)
    nextModes = nextModes.map(normalizeBuilderMode)
    if (fallback === 'hiking' || fallback === 'portaging') {
      nextModes = nextModes.map((m, i) => (m === 'car' && isHikingTrailSegment(i, wps) ? 'portaging' : m))
    }
    setSegModes(nextModes)
    setRouteVia(via.filter((v) => { const a = Number(v.afterIndex); return Number.isFinite(a) && a >= 0 && a < count }))
    setPrefs((p) => Object.fromEntries(Object.entries(p).filter(([k]) => Number(k) >= 0 && Number(k) < count)))
    for (const k of Object.keys(optionsCache.current)) if (Number(k) >= count) delete optionsCache.current[Number(k)]
    setActiveSeg((a) => (count <= 0 || a < 0 || a >= count ? 0 : a))
  }

  const ensureItineraryLength = (dayCount: number) =>
    setItinerary((it) => {
      const next = it.slice(0, Math.max(0, dayCount))
      while (next.length < dayCount) next.push(newDay(next.length + 1))
      return next.map((d, i) => ({ ...d, title: String(d.title ?? '').trim() ? d.title : `Day ${i + 1}` }))
    })

  const askDays = (name: string, initialDays = 2) => new Promise<number | null>((resolve) => setDialog({ kind: 'days', name, initial: initialDays, resolve: (v) => { setDialog(null); resolve(v) } }))
  const askActivity = (dayTitle: string, init?: Row) => new Promise<ActivityForm | null>((resolve) => setDialog({ kind: 'activity', dayTitle, initial: init, resolve: (v) => { setDialog(null); resolve(v) } }))

  const addWaypoint = async (name: string, lat: number, lon: number) => {
    const days = await askDays(name)
    if (days == null) return
    const next = [...waypoints, { name, lat, lon, days }]
    setWaypoints(next)
    ensureItineraryLength(next.reduce((t, w) => t + w.days, 0))
    syncRouting(next)
    setResults([])
    setQuery('')
  }

  const setSegmentMode = (i: number, mode: string) => {
    const normalized = normalizeBuilderMode(mode)
    if (i < 0 || i >= segmentCount) return
    setActiveSeg(i)
    const modes = segModes.slice(0, segmentCount)
    while (modes.length < segmentCount) modes.push(normalizeBuilderMode(transportMode))
    modes[i] = normalized
    setTransportMode(normalized)
    const via = normalized === 'train' || normalized === 'plane' ? routeVia.filter((v) => Number(v.afterIndex) !== i) : routeVia
    delete optionsCache.current[i]
    setRouteInstructions([])
    syncRouting(waypoints, modes, segRouting, via, normalized)
  }
  const setTopMode = (mode: string) => {
    if (selectedSeg != null) return setSegmentMode(selectedSeg, mode)
    const m = normalizeBuilderMode(mode)
    setTransportMode(m)
    syncRouting(waypoints, segModes, segRouting, routeVia, m)
  }

  // ---- search ----
  const isHikingSearchMode = (() => {
    const m = selectedSeg != null ? segModeAt(selectedSeg) : normalizeBuilderMode(transportMode)
    return m === 'hiking' || m === 'portaging'
  })()
  const searchForUi = async (q: string): Promise<SearchResult[]> => {
    const t = q.trim()
    if (!t) return []
    let res: SearchResult[] = await searchNominatim(t)
    if (!isHikingSearchMode) return res
    let filtered = filterHikingResults(res)
    if (filtered.length) return filtered
    const focused = hikingBiasedQuery(t)
    if (focused !== t) {
      res = await searchNominatim(focused)
      filtered = filterHikingResults(res)
      if (filtered.length) return filtered
    }
    return []
  }
  const searchRef = useRef(searchForUi)
  searchRef.current = searchForUi
  useEffect(() => {
    const q = query.trim()
    if (!q) return setResults([])
    let cancelled = false
    const id = setTimeout(async () => { const r = await searchRef.current(q); if (!cancelled) setResults(r) }, 400)
    return () => { cancelled = true; clearTimeout(id) }
  }, [query])
  const addFromResult = (r: SearchResult, fallbackName: string) =>
    addWaypoint(String(r.name ?? fallbackName), coerceCoord(r.lat) ?? 0, coerceCoord(r.lon) ?? 0)
  const submitSearch = async () => {
    const q = query.trim()
    if (!q) return
    const found = await searchForUi(q)
    if (found.length) await addFromResult(found[0], q)
  }

  // ---- route choices ----
  const loadRouteChoices = async (segmentIndex: number, force: boolean): Promise<Row[]> => {
    if (!force && optionsCache.current[segmentIndex]?.length) return optionsCache.current[segmentIndex]
    if (segmentIndex < 0 || segmentIndex + 1 >= waypoints.length) return []
    const from = waypoints[segmentIndex], to = waypoints[segmentIndex + 1]
    const mode = routeOptionsMode(segModeAt(segmentIndex))
    const options = await getRouteOptions({ originLat: from.lat, originLng: from.lon, destLat: to.lat, destLng: to.lon, mode, avoidHighways: mode === 'biking', maxOptions: 5 })
    const ranked: Row[] = options
      .map((o, i) => ({ ...o, sourceIndex: i, score: o.durationSeconds > 0 ? o.durationSeconds / 60 : 100000, ...analyzePortages(o.instructions) }))
      .sort((a, b) => a.score - b.score)
    ranked.forEach((r, i) => { r.rank = i + 1; r.portagePattern = '' })
    let singleIdx = -1, singleBest = -1, multiIdx = -1, multiCount = -1, multiLongest = Infinity
    ranked.forEach((r, i) => {
      if (r.portageCount === 1 && r.longestPortageKm > singleBest) { singleBest = r.longestPortageKm; singleIdx = i }
      if (r.portageCount >= 2 && (r.portageCount > multiCount || (r.portageCount === multiCount && r.longestPortageKm < multiLongest))) { multiCount = r.portageCount; multiLongest = r.longestPortageKm; multiIdx = i }
    })
    if (singleIdx >= 0) ranked[singleIdx].portagePattern = 'single_long'
    if (multiIdx >= 0) ranked[multiIdx].portagePattern = 'multi_short'
    optionsCache.current[segmentIndex] = ranked
    return ranked
  }

  const upsertVia = (afterIndex: number, lat: number, lon: number) => {
    if (afterIndex < 0 || afterIndex >= segmentCount) return
    setRouteVia((v) => {
      const idx = v.findIndex((x) => String(x.afterIndex) === String(afterIndex))
      const entry = { afterIndex, lat, lon }
      return idx >= 0 ? v.map((x, i) => (i === idx ? entry : x)) : [...v, entry]
    })
    setActiveSeg(Math.max(0, Math.min(afterIndex, segmentCount - 1)))
  }

  // ---- onHikingCampsiteTap ----
  const onCampsiteTap = async (c: Row) => {
    const lat = coerceCoord(c.lat), lon = coerceCoord(c.lon)
    if (lat == null || lon == null) return
    const name = String(c.name ?? 'Campsite').trim() || 'Campsite'
    const ok = await toastConfirm(name, `${(Number(c.distanceKmFromRoute) || 0).toFixed(1)} km from route`, `Lat ${lat.toFixed(5)}, Lon ${lon.toFixed(5)}`)
    if (ok) await addWaypoint(name, lat, lon)
  }
  const toastConfirm = (name: string, a: string, b: string) => confirm({ title: name, message: <><div>{a}</div><div className="muted" style={{ fontSize: 12, marginTop: 8 }}>{b}</div></>, confirmLabel: 'Add as stop' })

  // ---- save ----
  const uploadImage = async (tripId: string, label: string, dataUrl: string) => {
    const decoded = dataUrlToBlob(dataUrl)
    if (!decoded) throw new Error('Unsupported image format')
    const ct = decoded.contentType.toLowerCase()
    const ext = ct.includes('png') ? 'png' : ct.includes('webp') ? 'webp' : ct.includes('gif') ? 'gif' : 'jpg'
    const r = ref(storage, `verifiedTrips/${tripId}/${label}_${Date.now()}.${ext}`)
    await uploadBytes(r, decoded.blob, { contentType: decoded.contentType })
    return getDownloadURL(r)
  }

  const save = async () => {
    const u = auth.currentUser
    if (!u) return toast('You must be signed in to create a verified trip.')
    const errs = { title: title.trim() ? undefined : 'Title is required', description: description.trim() ? undefined : 'Description is required' }
    setErrors(errs)
    if (errs.title || errs.description) return toast('Please fix the highlighted fields.')
    if (!waypoints.length) return toast('Add at least one location to build the trip.')

    setSaving(true)
    try {
      const docRef = isEditing ? doc(db, 'verifiedTrips', existingId!) : doc(collection(db, 'verifiedTrips'))
      const tripId = docRef.id
      let cover = coverImage.trim() || (photos[0]?.trim() ?? '')
      if (cover.startsWith('data:image')) cover = await uploadImage(tripId, 'cover', cover)
      const uploaded: string[] = []
      for (let i = 0; i < photos.length; i++) {
        const p = photos[i].trim()
        if (!p) continue
        uploaded.push(p.startsWith('data:image') ? await uploadImage(tripId, `photo_${i}`, p) : p)
      }
      if (!cover && uploaded.length) cover = uploaded[0]
      const uniquePhotos = [...new Set(uploaded.map((p) => p.trim()).filter(Boolean))]

      const count = Math.max(0, waypoints.length - 1)
      const routing = segRouting.slice(0, count).map((v) => (v.trim().toLowerCase() === 'direct' ? 'direct' : 'calculated'))
      while (routing.length < count) routing.push('calculated')
      const modes = segModes.slice(0, count).map(normalizeBuilderMode)
      while (modes.length < count) modes.push(normalizeBuilderMode(transportMode))
      const via = routeVia.filter((v) => { const a = Number(v.afterIndex); return Number.isFinite(a) && a >= 0 && a < count })
      const prefsOut = Object.entries(prefs).filter(([k]) => Number(k) >= 0 && Number(k) < count).map(([k, v]) => ({ ...v, segmentIndex: Number(k) }))

      const tripData: Row = JSON.parse(JSON.stringify({
        title: title.trim(), subtitle: subtitle.trim(), description: description.trim(), coverImage: cover,
        recommendedDays, days: recommendedDays, itinerary, photos: uniquePhotos, transportMode: normalizeBuilderMode(transportMode),
        segmentRoutingTypes: routing, segmentTransportModes: modes, routeVia: via, segmentRoutePreferences: prefsOut,
        routeInstructions: routeInstructions.slice(0, 8),
        waypoints: waypoints.map((w) => ({ name: w.name, lat: w.lat, lon: w.lon, days: w.days })),
        totalStops: waypoints.length, totalKm: distanceKm ?? totalKm,
      }))
      if (isEditing) {
        tripData.updatedAt = serverTimestamp()
        tripData.updatedByUid = u.uid
        await updateDoc(docRef, tripData)
      } else {
        tripData.createdAt = serverTimestamp()
        tripData.createdByUid = u.uid
        await setDoc(docRef, tripData)
      }
      toast(isEditing ? 'Verified trip updated' : 'Verified trip created')
      navigate(-1)
    } catch (e: any) {
      toast(`Save failed: ${e?.message ?? e}`)
    } finally {
      setSaving(false)
    }
  }

  // ---- itinerary mutations ----
  const patchDay = (i: number, patch: Row) => setItinerary((it) => it.map((d, k) => (k === i ? { ...d, ...patch } : d)))
  const activityRow = (res: ActivityForm): Row => ({
    time: res.time, title: res.title, description: res.description, location: res.location, category: res.category || 'Sightseeing',
    locationLat: Number.isFinite(parseFloat(res.lat)) ? parseFloat(res.lat) : null, locationLon: Number.isFinite(parseFloat(res.lon)) ? parseFloat(res.lon) : null,
  })

  const secondaryPoints = useMemo(
    () => itinerary.flatMap((day, dayIndex) =>
      (Array.isArray(day.activities) ? day.activities : [])
        .map((a: Row, activityIndex: number) => ({ a, activityIndex }))
        .filter(({ a }: { a: Row }) => a.locationLat != null && a.locationLon != null)
        .map(({ a, activityIndex }: { a: Row; activityIndex: number }) => ({ lat: a.locationLat, lon: a.locationLon, kind: 'activity', category: a.category ?? 'Sightseeing', dayIndex, activityIndex }))),
    [itinerary],
  )
  const mapPoints = useMemo(() => waypoints.map((w) => ({ name: w.name, lat: w.lat, lon: w.lon })), [waypoints])
  const cover = coverImage.trim() || (photos[0] ?? '')
  const mapHeight = Math.max(220, Math.min(340, window.innerWidth * 0.55))

  return (
    <div style={{ minHeight: '100vh', background: 'var(--bg)' }}>
      <div className="plan-topbar" style={{ position: 'sticky', top: 0, zIndex: 5 }}>
        <button className="icon-btn" title="Back" onClick={() => navigate(-1)}><MdArrowBack size={22} /></button>
        <span className="grow" style={{ fontSize: 20, fontWeight: 500 }}>{isEditing ? 'Edit verified trip' : 'New verified trip'}</span>
        <Button variant="text" disabled={saving} onClick={() => void save()}>{saving ? <Spinner size="sm" /> : 'Save'}</Button>
      </div>

      <div style={{ maxWidth: 900, margin: '0 auto', padding: 16 }}>
        {cover && <div style={{ marginBottom: 12 }}><ImagePreview url={cover} height={220} /></div>}

        <SoftCard padding={12}>
          <div className="col gap-md">
            <div className="field"><label>Title</label><input className={cx('input', errors.title && 'error')} value={title} onChange={(e) => setTitle(e.target.value)} />{errors.title && <div className="form-error">{errors.title}</div>}</div>
            <div className="field"><label>Subtitle (optional)</label><input className="input" value={subtitle} onChange={(e) => setSubtitle(e.target.value)} /></div>
            <div className="field"><label>Cover photo</label><div className="input" style={{ display: 'flex', alignItems: 'center' }}>{coverImage ? 'Uploaded' : 'None'}</div></div>
            <div className="row gap-sm">
              <Button variant="outlined" size="sm" disabled={saving} icon={<MdUpload size={18} />} onClick={async () => { const d = await pickImageDataUrl(1600); if (d) setCoverImage(d) }}>Upload cover</Button>
              {coverImage && <Button variant="text" size="sm" disabled={saving} onClick={() => setCoverImage('')}>Remove cover</Button>}
            </div>
            <div className="field"><label>Description</label><textarea className={cx('textarea', errors.description && 'error')} rows={6} value={description} onChange={(e) => setDescription(e.target.value)} />{errors.description && <div className="form-error">{errors.description}</div>}</div>
            <div className="row between wrap">
              <b>Recommended: {recommendedDays} days</b>
              <span className="muted" style={{ fontSize: 12 }}>{waypoints.length} stops{waypoints.length > 1 ? ` • ${km.toFixed(0)} km` : ''}{durationMin != null ? ` • ${Math.round(durationMin)} min` : ''}</span>
            </div>
          </div>
        </SoftCard>

        <h3 style={{ margin: '12px 0 8px' }}>Build the route</h3>
        <SoftCard padding={12}>
          {segmentCount > 0 && (
            <>
              <div className="row" style={{ gap: 8 }}>
                <b style={{ whiteSpace: 'nowrap' }}>Leg mode ({selectedSeg == null ? 'No leg selected' : `Leg ${selectedSeg + 1}`})</b>
                <div className="tb-mode-row grow">
                  {BUILDER_TRANSPORT_OPTIONS.map((o) => {
                    const blocked = selectedSeg != null && o.mode === 'car' && isCarBlocked(selectedSeg)
                    const sel = (selectedSeg == null ? normalizeBuilderMode(transportMode) : segModeAt(selectedSeg)) === o.mode
                    return <button key={o.mode} className={cx('chip', sel && 'selected')} style={{ fontSize: 18, opacity: blocked ? 0.5 : 1 }} disabled={blocked} title={o.label} onClick={() => setTopMode(o.mode)}>{o.emoji}</button>
                  })}
                </div>
              </div>
              <div className="muted" style={{ fontSize: 11, margin: '4px 0 8px' }}>Tap a stop row to change the active leg. For portage routing, use hiking mode.</div>
              <div className="row" style={{ gap: 8 }}>
                <label className="row gap-sm grow" style={{ fontWeight: 700 }}><input type="checkbox" checked={adjustRoute} disabled={saving} onChange={(e) => setAdjustRoute(e.target.checked)} /> Adjust route line (tap route to compare options or drop via pins)</label>
                {adjustRoute && routeVia.length > 0 && <Button variant="text" size="sm" disabled={saving} icon={<MdClear size={16} />} onClick={() => setRouteVia([])}>Clear pins</Button>}
              </div>
              {routeInstructions.length > 0 && <div className="muted" style={{ fontSize: 12, margin: '8px 0 10px' }}>{routeInstructions.slice(0, 3).join(' • ')}</div>}
            </>
          )}

          <div className="row gap-sm" style={{ marginTop: 8 }}>
            <div className="input-wrap grow"><span className="input-icon"><MdSearch size={20} /></span>
              <input className="input" placeholder={isHikingSearchMode ? 'Search hiking trails, campsites, portages' : 'Search locations'} value={query} onChange={(e) => setQuery(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && void submitSearch()} />
            </div>
            <Button variant="solid" disabled={saving} onClick={() => void submitSearch()}>Add</Button>
          </div>
          {results.length > 0 && (
            <div style={{ height: 160, overflowY: 'auto', marginTop: 10, border: '1px solid #d4d4d8', borderRadius: 8, background: '#fff' }}>
              {results.map((r, i) => (
                <div key={i} className="row" style={{ padding: '8px 12px', gap: 8, borderBottom: '1px solid var(--border)' }}>
                  <div className="grow" style={{ minWidth: 0 }}><div className="ellipsis">{String(r.name ?? `Result ${i + 1}`)}</div><div className="muted" style={{ fontSize: 12 }}>{Number(r.lat).toFixed(4)}, {Number(r.lon).toFixed(4)}</div></div>
                  <Button variant="text" size="sm" disabled={saving} onClick={() => void addFromResult(r, `Result ${i + 1}`)}>Add</Button>
                </div>
              ))}
            </div>
          )}

          <div style={{ height: mapHeight, marginTop: 10, borderRadius: 12, overflow: 'hidden', border: '1px solid #d4d4d8' }}>
            <MapEmbed
              points={mapPoints} transportMode={transportMode} segmentTransportModes={segModes} segmentRoutingTypes={segRouting} routeVia={routeVia}
              secondaryPoints={secondaryPoints}
              onRouteSummary={(m, s) => { setDistanceKm(m / 1000); setDurationMin(s / 60) }}
              onRouteInstructions={setRouteInstructions}
              onHikingCampsiteTap={(c) => void onCampsiteTap(c)}
              onRouteTapAddVia={adjustRoute ? (a, lat, lon) => { setActiveSeg(a); setDialog({ kind: 'routes', segmentIndex: a, tapped: { lat, lon } }) } : undefined}
              onViaDragEnd={adjustRoute ? (v, lat, lon) => setRouteVia((l) => (v < 0 || v >= l.length ? l : l.map((x, i) => (i === v ? { ...x, lat, lon } : x)))) : undefined}
              onViaTapDelete={adjustRoute ? (v) => setRouteVia((l) => l.filter((_x, i) => i !== v)) : undefined}
            />
          </div>
        </SoftCard>

        {waypoints.length === 0 && <div style={{ marginTop: 12 }}>No stops yet — search a location to start building the verified trip.</div>}

        {waypoints.length > 0 && (
          <>
            <div className="row" style={{ margin: '12px 0 8px' }}><h3 className="grow" style={{ margin: 0 }}>Stops</h3><span className="muted" style={{ fontSize: 12 }}>Total: {recommendedDays} days</span></div>
            <SoftCard padding={0}>
              {waypoints.map((w, i) => {
                const isSeg = i < waypoints.length - 1
                const next = isSeg ? waypoints[i + 1] : null
                const segKm = next ? haversineKm(w.lat, w.lon, next.lat, next.lon) : 0
                const segType = i < segRouting.length ? segRouting[i] : 'calculated'
                const segMode = segModeAt(i)
                const active = isSeg && selectedSeg === i
                const pref = prefs[i]
                const prefSummary = String(pref?.summary ?? '').trim()
                const carBlocked = isSeg && isCarBlocked(i)
                return (
                  <div key={i} onClick={() => isSeg && setActiveSeg(i)} style={{ padding: '10px 12px', borderTop: i ? '1px solid var(--border)' : undefined, background: active ? 'rgba(74,173,232,0.08)' : undefined, cursor: isSeg ? 'pointer' : undefined }}>
                    <div className="row" style={{ alignItems: 'flex-start', gap: 8 }}>
                      <div className="grow" style={{ minWidth: 0 }}><div className="ellipsis" style={{ fontWeight: 700 }}>{w.name}</div><div className="muted" style={{ fontSize: 12 }}>{w.lat.toFixed(4)}, {w.lon.toFixed(4)}</div></div>
                      <Button variant="outlined" size="sm" disabled={saving} style={{ width: 72 }}
                        onClick={async (e) => {
                          e.stopPropagation()
                          const v = await askDays(w.name, w.days)
                          if (v == null) return
                          const next2 = waypoints.map((x, k) => (k === i ? { ...x, days: v } : x))
                          setWaypoints(next2)
                          ensureItineraryLength(next2.reduce((t, x) => t + x.days, 0))
                        }}>{w.days}d</Button>
                      <button className="icon-btn" title="Remove stop" disabled={saving} onClick={(e) => { e.stopPropagation(); const next2 = waypoints.filter((_x, k) => k !== i); setWaypoints(next2); ensureItineraryLength(next2.reduce((t, x) => t + x.days, 0)); syncRouting(next2) }}><MdDeleteOutline size={20} /></button>
                    </div>
                    {isSeg && (
                      <div onClick={(e) => e.stopPropagation()}>
                        <div className="muted" style={{ fontSize: 12, margin: '8px 0' }}>{segKm.toFixed(2)} km to next stop</div>
                        <div className="row wrap gap-sm" style={{ alignItems: 'center' }}>
                          <select className="tb-mini-select" style={{ width: 92 }} value={segMode} onChange={(e) => setSegmentMode(i, e.target.value)}>
                            {BUILDER_TRANSPORT_OPTIONS.map((o) => <option key={o.mode} value={o.mode} disabled={carBlocked && o.mode === 'car'}>{o.emoji}</option>)}
                          </select>
                          <button className={cx('chip', segType.trim().toLowerCase() === 'calculated' && 'selected')} onClick={() => { setActiveSeg(i); setSegRouting((l) => l.map((v, k) => (k === i ? 'calculated' : v))) }}>Calculated</button>
                          <button className={cx('chip', segType.trim().toLowerCase() === 'direct' && 'selected')} onClick={() => { setActiveSeg(i); setSegRouting((l) => l.map((v, k) => (k === i ? 'direct' : v))) }}>Direct</button>
                          <Button variant="text" size="sm" disabled={saving} icon={<MdAltRoute size={16} />} onClick={() => { setActiveSeg(i); setDialog({ kind: 'routes', segmentIndex: i, tapped: null }) }}>Portage choices</Button>
                        </div>
                        {prefSummary && (
                          <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>
                            Preferred: {prefSummary}{Number(pref?.portageCount) > 0 ? ` • ${pref.portageCount} portage${pref.portageCount === 1 ? '' : 's'}` : ''}{Number(pref?.portageDistanceKm) > 0 ? ` • ~${Number(pref.portageDistanceKm).toFixed(1)} km carry` : ''}
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                )
              })}
            </SoftCard>

            <div className="row" style={{ margin: '16px 0 8px' }}><h3 className="grow" style={{ margin: 0 }}>Itinerary (by day)</h3><span className="muted" style={{ fontSize: 12 }}>{itinerary.length} days</span></div>
            <SoftCard padding={0}>
              {itinerary.map((day, di) => {
                const dayTitle = String(day.title ?? `Day ${di + 1}`)
                const notes = String(day.notes ?? '')
                const acts: Row[] = Array.isArray(day.activities) ? day.activities : []
                const open = expandedDay === di
                return (
                  <div key={di} style={{ borderTop: di ? '1px solid var(--border)' : undefined }}>
                    <div className="row" style={{ padding: '12px 16px', cursor: 'pointer', gap: 8 }} onClick={() => setExpandedDay(open ? null : di)}>
                      <div className="grow" style={{ minWidth: 0 }}>
                        <div>{dayTitle}</div>
                        <div className="muted ellipsis" style={{ fontSize: 13 }}>{notes.trim() ? notes : `${acts.length} activit${acts.length === 1 ? 'y' : 'ies'}`}</div>
                      </div>
                      <span style={{ transform: open ? 'rotate(90deg)' : undefined, transition: 'transform 0.15s' }}>›</span>
                    </div>
                    {open && (
                      <div style={{ padding: '0 16px 16px' }}>
                        <div className="field"><label>Day notes (optional)</label><input className="input" disabled={saving} value={notes} onChange={(e) => patchDay(di, { notes: e.target.value })} /></div>
                        <div style={{ margin: '10px 0' }}>
                          <Button variant="outlined" size="sm" disabled={saving} icon={<MdAdd size={18} />} onClick={async () => { const res = await askActivity(dayTitle); if (res) patchDay(di, { activities: [...acts, activityRow(res)] }) }}>Add activity</Button>
                        </div>
                        {acts.length === 0 && <div>No activities yet.</div>}
                        {acts.map((a, ai) => {
                          const loc = String(a.location ?? '').trim()
                          const cat = String(a.category ?? '')
                          const sub = [String(a.time ?? '').trim(), loc ? `📍 ${loc}` : '', String(a.description ?? '').trim()].filter(Boolean).join(' • ')
                          return (
                            <div key={ai} className="row" style={{ gap: 8, padding: '8px 0', borderTop: ai ? '1px solid var(--border)' : undefined }}>
                              {loc && <span className="row" style={{ gap: 6 }}>{cat in TRAVEL_CATEGORIES && <span style={{ width: 12, height: 12, borderRadius: '50%', background: TRAVEL_CATEGORIES[cat] }} />}<MdPlace size={20} /></span>}
                              <div className="grow" style={{ minWidth: 0 }}><div>{String(a.title ?? '') || 'Activity'}</div>{sub && <div className="muted" style={{ fontSize: 13 }}>{sub}</div>}</div>
                              <button className="icon-btn" title="Edit activity" disabled={saving} onClick={async () => { const res = await askActivity(dayTitle, a); if (res) patchDay(di, { activities: acts.map((x, k) => (k === ai ? activityRow(res) : x)) }) }}><MdOutlineEdit size={20} /></button>
                              <button className="icon-btn" title="Delete activity" disabled={saving} onClick={() => patchDay(di, { activities: acts.filter((_x, k) => k !== ai) })}><MdDeleteOutline size={20} /></button>
                            </div>
                          )
                        })}
                      </div>
                    )}
                  </div>
                )
              })}
            </SoftCard>
          </>
        )}

        <div className="row" style={{ margin: '16px 0 8px' }}>
          <h3 className="grow" style={{ margin: 0 }}>Photo log</h3>
          <Button variant="outlined" size="sm" disabled={saving} icon={<MdAdd size={18} />} onClick={async () => { const d = await pickImageDataUrl(1600); if (d) setPhotos((p) => [...p, d]) }}>Add photo</Button>
        </div>
        {photos.length === 0 ? <div>No photos yet. Upload a few images to make this feel premium.</div> : (
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
            {photos.map((p, i) => (
              <div key={i} style={{ position: 'relative', aspectRatio: '1.3' }}>
                <ImagePreview url={p} height={undefined} />
                <button disabled={saving} onClick={() => setPhotos((l) => l.filter((_x, k) => k !== i))} style={{ position: 'absolute', top: 6, right: 6, borderRadius: 16, border: 'none', background: 'rgba(0,0,0,0.54)', color: '#fff', padding: 6, display: 'flex' }}>✕</button>
              </div>
            ))}
          </div>
        )}
        <div style={{ height: 40 }} />
      </div>

      {dialog?.kind === 'days' && <DaysDialog locationName={dialog.name} initial={dialog.initial} onResult={dialog.resolve} />}
      {dialog?.kind === 'activity' && <ActivityDialog dayTitle={dialog.dayTitle} initial={dialog.initial} onResult={dialog.resolve} />}
      {dialog?.kind === 'routes' && (
        <RouteChoicesDialog
          segmentIndex={dialog.segmentIndex} waypoints={waypoints} mode={segModeAt(dialog.segmentIndex)} preferred={prefs[dialog.segmentIndex]} tapped={dialog.tapped}
          load={(force) => loadRouteChoices(dialog.segmentIndex, force)}
          onChoose={(o) => { setPrefs((p) => ({ ...p, [dialog.segmentIndex]: { ...o, segmentIndex: dialog.segmentIndex, selectedAt: new Date().toISOString() } })); setDialog(null); toast(`Saved leg ${dialog.segmentIndex + 1} route preference.`) }}
          onDropPin={() => { if (dialog.tapped) upsertVia(dialog.segmentIndex, dialog.tapped.lat, dialog.tapped.lon); setDialog(null) }}
          onClose={() => setDialog(null)}
        />
      )}
    </div>
  )
}

/** `/verified-trips/new` and `/verified-trips/:id/edit` */
export default function VerifiedTripBuilderRoute() {
  const { id } = useParams()
  const state = (useLocation().state ?? {}) as { data?: Row }
  const [data, setData] = useState<Row | null>(state.data ?? null)
  const [error, setError] = useState('')
  useEffect(() => {
    if (!id || data) return
    getDoc(doc(db, 'verifiedTrips', id)).then((s) => (s.exists() ? setData(s.data()) : setError('Trip not found'))).catch((e) => setError(e?.message ?? 'Failed to load trip'))
  }, [id, data])
  if (id && !data) return <div className="center" style={{ height: '100vh' }}>{error || <Spinner />}</div>
  return <Builder key={id ?? 'new'} existingId={id} existing={data ?? undefined} />
}
