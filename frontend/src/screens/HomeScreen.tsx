import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { collection, doc, getDoc, limit, onSnapshot, orderBy, query, Timestamp } from 'firebase/firestore'
import { format } from 'date-fns'
import {
  MdAutoAwesome, MdCalendarToday, MdChevronLeft, MdChevronRight, MdClose, MdEditRoad, MdOutlineGroup, MdGroups, MdHotel,
  MdHourglassTop, MdOutlineMap, MdOutlineRoute, MdOutlineSchedule, MdShare,
} from 'react-icons/md'
import { useNavigate } from 'react-router-dom'
import { db } from '@/firebase'
import TopTaskbar from '@/components/TopTaskbar'
import { SectionHeader, SoftCard, Spinner } from '@/components/ui'
import { useAuth } from '@/context/Auth'
import { useFeedback } from '@/context/Feedback'
import { resolveTripDataForOpen } from '@/services/tripsService'
import SavedTripsDock, { type DockTrip } from './home/SavedTripsDock'
import StopInsightCard, { focusedStopTitle } from './home/StopInsightCard'
import VerifiedTripPreviewCard from './home/VerifiedTripPreviewCard'
import { bearingDegrees, earthAssetUrl, messageType, normalizedWaypointsFromTrip, overviewCameraForTrip, type StopPoint } from './home/globeBridge'
import { focusedStopKey, useStopInsights } from './home/stopInsights'

const DESKTOP_DOCK_H = 392
const MOBILE_DOCK_H = 268
const APPBAR_H = 64

function useWindowSize() {
  const [s, setS] = useState({ w: window.innerWidth, h: window.innerHeight })
  useEffect(() => {
    const on = () => setS({ w: window.innerWidth, h: window.innerHeight })
    window.addEventListener('resize', on)
    return () => window.removeEventListener('resize', on)
  }, [])
  return s
}

function GlassButton({ label, icon, onClick }: { label: string; icon: React.ReactNode; onClick: () => void }) {
  return (
    <button type="button" className="glass-btn" onClick={onClick} aria-label={label}>
      {icon}<span>{label}</span>
    </button>
  )
}

const FEATURES: [React.ReactNode, string][] = [
  [<MdOutlineMap size={18} />, 'Build multi-stop trips with date ranges, destination sequencing, and route context.'],
  [<MdOutlineGroup size={18} />, 'Collaborate in one place with shared trips, shared packing lists, and built-in trip chat.'],
  [<MdCalendarToday size={18} />, 'Plan each destination day-by-day with arrival/departure dates, activities, and notes.'],
  [<MdHotel size={18} />, 'Track practical details including accommodations, activities, and planning progress.'],
  [<MdShare size={18} />, 'Share trip links so participants and guests can view the same source of truth.'],
]

const VALUES: [React.ReactNode, string, string, string][] = [
  [<MdOutlineSchedule size={20} />, 'Trip Logic Stays Coherent', 'When dates or stop lengths change, your itinerary structure stays organized instead of drifting out of sync.', 'Planning accuracy'],
  [<MdGroups size={20} />, 'Collaboration Without Clutter', 'Shared trips, chat, and packing lists keep everyone aligned without scattered group-message planning.', 'Team coordination'],
  [<MdOutlineRoute size={20} />, 'From Plan to Execution', 'Destination-level stays, activities, and day plans make it easier to move from rough ideas to real bookings.', 'Execution ready'],
]

export default function HomeScreen() {
  const navigate = useNavigate()
  const { user } = useAuth()
  const { toast } = useFeedback()
  const { w, h } = useWindowSize()
  const isPhone = w < 760
  const isNarrow = w < 420

  const scrollRef = useRef<HTMLDivElement>(null)
  const iframeRef = useRef<HTMLIFrameElement>(null)
  const [dock, setDock] = useState(0)

  const [selectedTrip, setSelectedTrip] = useState<DockTrip | null>(null)
  const [showOpenButton, setShowOpenButton] = useState(false)
  const [opening, setOpening] = useState(false)
  const [stopIndex, setStopIndex] = useState(0)
  const [showStopNav, setShowStopNav] = useState(false)
  const [showPoiCard, setShowPoiCard] = useState(false)
  const [globeReady, setGlobeReady] = useState(false)
  const [iframeSrc, setIframeSrc] = useState<string | null>(null)
  const [verified, setVerified] = useState<{ id: string; data: Record<string, any> }[] | null>(null)
  const [verifiedError, setVerifiedError] = useState<string | null>(null)

  const insightsApi = useStopInsights(selectedTrip)
  const timers = useRef<{ intro?: ReturnType<typeof setTimeout>; open?: ReturnType<typeof setTimeout>; ready?: ReturnType<typeof setTimeout> }>({})
  const animToken = useRef(0)
  const lastAnimatedKey = useRef<string | null>(null)
  const globeReadyRef = useRef(false)
  const selectedRef = useRef(selectedTrip)
  selectedRef.current = selectedTrip
  const targetOrigin = useRef<string>(window.location.origin)

  // Lazily load the globe iframe after first paint.
  useEffect(() => {
    const t = setTimeout(() => setIframeSrc(earthAssetUrl()), user ? 350 : 900)
    return () => clearTimeout(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(
    () =>
      onSnapshot(
        query(collection(db, 'verifiedTrips'), orderBy('createdAt', 'desc'), limit(3)),
        (s) => { setVerified(s.docs.map((d) => ({ id: d.id, data: d.data() }))); setVerifiedError(null) },
        (e) => setVerifiedError(e.message),
      ),
    [],
  )

  // Docking taskbar on scroll.
  const onScroll = useCallback(() => {
    const el = scrollRef.current
    if (!el) return
    const start = window.innerHeight * 0.4
    const end = window.innerHeight * 0.75
    const p = Math.min(1, Math.max(0, (el.scrollTop - start) / (end - start)))
    setDock((prev) => (Math.abs(prev - p) > 0.01 ? p : prev))
  }, [])

  const post = useCallback((payload: Record<string, any>) => {
    const win = iframeRef.current?.contentWindow
    if (!win) return
    try {
      win.postMessage(payload, targetOrigin.current || '*')
    } catch (e) {
      console.debug('postMessage failed', e)
    }
  }, [])

  const postFlyTo = (lat: number, lon: number, range: number, tilt = 55, heading = 0) =>
    post({ type: 'flyTo', lat, lng: lon, range, tilt, heading })

  const waypoints = useMemo(() => normalizedWaypointsFromTrip(selectedTrip), [selectedTrip])

  const focusStopIndex = useCallback((index: number, explicit?: StopPoint[]) => {
    const wps = explicit ?? normalizedWaypointsFromTrip(selectedRef.current)
    if (!wps.length) return
    const count = wps.length
    const idx = ((index % count) + count) % count
    const stop = wps[idx]
    setStopIndex(idx)
    setShowStopNav(count > 1)
    setShowPoiCard(true)
    void insightsApi.ensurePoiInsight(stop, idx)
    void insightsApi.ensurePhotos(stop, idx, focusedStopTitle(stop, idx + 1, selectedRef.current, insightsApi.insights[focusedStopKey(stop)]))

    let heading = 0
    if (count > 1) {
      const target = wps[idx < count - 1 ? idx + 1 : idx - 1]
      heading = bearingDegrees(stop.lat, stop.lon, target.lat, target.lon)
    }
    postFlyTo(stop.lat, stop.lon, count > 1 ? 1800 : 1400, 76, heading)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [insightsApi.ensurePoiInsight, insightsApi.ensurePhotos])

  const runIntro = useCallback((tripKey: string, wps: StopPoint[]) => {
    if (!wps.length) return
    const token = ++animToken.current
    clearTimeout(timers.current.intro)
    setShowStopNav(false)
    const o = overviewCameraForTrip(wps)
    postFlyTo(o.lat, o.lon, o.range, 52, 0)
    timers.current.intro = setTimeout(() => {
      if (token !== animToken.current) return
      focusStopIndex(0, wps)
      lastAnimatedKey.current = tripKey
    }, 2000)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focusStopIndex])

  const sendTripToMap = useCallback((animate = false) => {
    const trip = selectedRef.current
    if (!iframeRef.current?.contentWindow || !globeReadyRef.current || !trip) return
    const wps = normalizedWaypointsFromTrip(trip)
    if (!wps.length) {
      post({ type: 'clearRoute' })
      return
    }
    const pt = (p: StopPoint) => ({ lat: p.lat, lng: p.lon, name: p.name })
    const origin = pt(wps[0])
    const destination = wps.length > 1 ? pt(wps[wps.length - 1]) : origin
    const middle = wps.length > 2 ? wps.slice(1, -1).map(pt) : []

    let tripDates = ''
    try {
      const sd = trip.startDate
      const d = sd instanceof Timestamp ? sd.toDate() : sd instanceof Date ? sd : null
      if (d) tripDates = format(d, 'MMM d')
    } catch { /* ignore */ }

    post({
      type: 'route', origin, destination, waypoints: middle,
      tripInfo: { name: trip.title ?? 'Trip', dates: tripDates, distance: typeof trip.distance === 'number' ? trip.distance : null, stops: wps.length },
    })

    const key = `${trip.id ?? trip.title ?? ''}|${wps.length}`
    if (animate && lastAnimatedKey.current !== key) runIntro(key, wps)
  }, [post, runIntro])

  // Globe handshake: wait for `map_ready`, with a 3s fallback after iframe load.
  useEffect(() => {
    const onMessage = (e: MessageEvent) => {
      if (e.origin !== targetOrigin.current) return
      if (messageType(e.data) !== 'map_ready' || globeReadyRef.current) return
      globeReadyRef.current = true
      setGlobeReady(true)
      sendTripToMap(true)
    }
    window.addEventListener('message', onMessage)
    return () => window.removeEventListener('message', onMessage)
  }, [sendTripToMap])

  const onIframeLoad = () => {
    post({ type: 'flutter_ping', timestamp: new Date().toISOString() })
    clearTimeout(timers.current.ready)
    timers.current.ready = setTimeout(() => {
      if (globeReadyRef.current) return
      globeReadyRef.current = true
      setGlobeReady(true)
      sendTripToMap(true)
    }, 3000)
  }

  useEffect(() => () => Object.values(timers.current).forEach(clearTimeout), [])

  const openTrip = useCallback(async () => {
    if (opening) return
    const trip = selectedRef.current
    if (!trip?.canEdit) return
    const tripId = String(trip.id ?? '')
    if (!tripId) return
    setOpening(true)
    try {
      let resolved: Record<string, any> = {
        name: String(trip.title ?? 'Trip'),
        title: String(trip.title ?? 'Trip'),
        waypoints: Array.isArray(trip.waypoints) ? [...trip.waypoints] : [],
        ...(trip.startDate != null ? { startDate: trip.startDate } : {}),
        ...(trip.endDate != null ? { endDate: trip.endDate } : {}),
        ...(trip.distance != null ? { totalKm: trip.distance } : {}),
        ...(trip.transportMode != null ? { transportMode: trip.transportMode } : {}),
        ...(Array.isArray(trip.segmentTransportModes) ? { segmentTransportModes: [...trip.segmentTransportModes] } : {}),
        ...(Array.isArray(trip.segmentRoutingTypes) ? { segmentRoutingTypes: [...trip.segmentRoutingTypes] } : {}),
      }
      if (user) {
        try {
          const snap = await Promise.race([
            getDoc(doc(db, 'users', user.uid, 'trips', tripId)),
            new Promise<never>((_, rej) => setTimeout(() => rej(new Error('timeout')), 6000)),
          ])
          if (snap.exists()) {
            const local = snap.data() ?? {}
            try {
              resolved = await Promise.race([
                resolveTripDataForOpen(user.uid, tripId, local),
                new Promise<never>((_, rej) => setTimeout(() => rej(new Error('timeout')), 6000)),
              ])
            } catch {
              resolved = local
            }
          }
        } catch { /* use selected-card data */ }
      }
      navigate(`/my-trips/${tripId}`, { state: { data: resolved } })
    } catch (e: any) {
      toast(`Could not open trip: ${e?.message ?? e}`)
    } finally {
      setOpening(false)
    }
  }, [opening, user, navigate, toast])

  const clearSelection = () => {
    clearTimeout(timers.current.intro)
    clearTimeout(timers.current.open)
    animToken.current++
    setSelectedTrip(null)
    setShowOpenButton(false)
    setOpening(false)
    setStopIndex(0)
    setShowStopNav(false)
    setShowPoiCard(false)
    post({ type: 'clearRoute' })
  }

  const onTripSelected = (trip: DockTrip) => {
    const sel = selectedRef.current
    if (sel?.id && trip.id && sel.id === trip.id && trip.canEdit) {
      void openTrip()
      return
    }
    clearTimeout(timers.current.intro)
    clearTimeout(timers.current.open)
    lastAnimatedKey.current = null
    setSelectedTrip(trip)
    setShowOpenButton(false)
    setOpening(false)
    setStopIndex(0)
    setShowStopNav(false)
    setShowPoiCard(false)
    timers.current.open = setTimeout(() => {
      if (selectedRef.current?.id !== trip.id || !selectedRef.current?.canEdit) return
      setShowOpenButton(true)
    }, 1600)
  }

  // Push the route whenever the selected trip changes.
  useEffect(() => {
    if (selectedTrip) sendTripToMap(true)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedTrip])

  // ---------- Layout ----------
  const heroBase = isPhone ? Math.min(760, Math.max(360, h * 0.78)) : h
  const heroHeight = heroBase + APPBAR_H
  const overlayPad = isPhone ? 12 : 32
  const contentPad = isNarrow ? 16 : 24
  const dockHeight = isPhone ? MOBILE_DOCK_H : DESKTOP_DOCK_H

  const count = waypoints.length
  const normalizedIdx = count ? ((stopIndex % count) + count) % count : -1
  const focusedStop = count ? waypoints[normalizedIdx] : null
  const showNav = !!selectedTrip && showStopNav && count > 1
  const showCard = !!selectedTrip && !!focusedStop && showPoiCard
  const focusedKey = focusedStop ? focusedStopKey(focusedStop) : ''
  const insight = focusedKey ? insightsApi.insights[focusedKey] : undefined
  const cardProps = focusedStop && {
    stop: focusedStop, stopNumber: normalizedIdx + 1, totalStops: count, trip: selectedTrip, insight,
    isLoading: insightsApi.loading.has(focusedKey), placePhotos: insightsApi.photos[focusedKey] ?? [],
    attribution: insightsApi.attribution, hasPremium: insightsApi.premium,
  }

  const verifiedCards = (verified ?? []).map(({ id, data }) => {
    const photos: string[] = Array.isArray(data.photos) ? data.photos.map(String).filter((s) => s.trim()) : []
    const cover = String(data.coverImage ?? '').trim()
    const images = [...(cover ? [cover] : []), ...photos.filter((p) => p.trim() !== cover)]
    const daysRaw = data.recommendedDays ?? data.days
    const days = typeof daysRaw === 'number' ? Math.trunc(daysRaw) : parseInt(String(daysRaw ?? ''), 10)
    const wps = Array.isArray(data.waypoints) ? data.waypoints : null
    const subtitle = (Number.isFinite(days) ? `${days} days` : 'Verified trip') + (wps ? ` • ${wps.length} stops` : '')
    const hasPoints = !!wps?.some((p: any) => typeof p?.lat === 'number' && typeof p?.lon === 'number')
    return (
      <VerifiedTripPreviewCard key={id} title={String(data.title ?? '')} subtitle={subtitle}
        images={images.length ? images : ['/images/mainScreenPic.jpg']}
        onClick={hasPoints ? () => navigate(`/verified-trips/${id}/map`) : undefined} />
    )
  })

  return (
    <div className="screen home-screen">
      <TopTaskbar dockProgress={dock} overlay />
      <div className="home-scroll" ref={scrollRef} onScroll={onScroll}>
        <section className="home-hero" style={{ height: heroHeight }}>
          <div className="globe-wrap">
            {iframeSrc ? (
              <iframe ref={iframeRef} src={iframeSrc} title="Trypr 3D Globe" allow="fullscreen" loading="lazy" onLoad={onIframeLoad} className="globe-frame" />
            ) : (
              <div className="center" style={{ height: '100%' }}><Spinner /></div>
            )}
          </div>

          {showOpenButton && selectedTrip?.canEdit && (
            <div className="hero-abs pop-in" style={{ top: APPBAR_H + (isPhone ? (showNav ? 104 : 68) : 72), right: overlayPad }}>
              <GlassButton label={opening ? 'Opening…' : 'Edit Trip'} icon={opening ? <MdHourglassTop size={18} /> : <MdEditRoad size={18} />} onClick={openTrip} />
            </div>
          )}

          {selectedTrip && (
            <>
              <div className="hero-abs" style={{ top: APPBAR_H + 16, right: overlayPad }}>
                <button type="button" className="glass-icon" title="Clear selected trip" aria-label="Clear selected trip" onClick={clearSelection}><MdClose size={18} /></button>
              </div>
              <div className="hero-abs" style={{ top: APPBAR_H + 16, left: overlayPad, maxWidth: Math.max(120, Math.min(420, w - overlayPad * 2 - 56)) }}>
                <div className="glass-chip"><MdOutlineMap size={14} /><span className="ellipsis">{selectedTrip.title ?? 'Trip'}</span></div>
              </div>
            </>
          )}

          {showNav && (
            <div className="hero-abs" style={{ top: APPBAR_H + 64, left: overlayPad }}>
              <div className="glass-nav" aria-label={`Stop navigator. Stop ${normalizedIdx + 1} of ${count}.`}>
                <button type="button" title="Previous stop" onClick={() => focusStopIndex(stopIndex - 1)}><MdChevronLeft size={18} /></button>
                <span>Stop {normalizedIdx + 1}/{count}</span>
                <button type="button" title="Next stop" onClick={() => focusStopIndex(stopIndex + 1)}><MdChevronRight size={18} /></button>
              </div>
            </div>
          )}

          {showCard && !isPhone && cardProps && (
            <div className="hero-abs" style={{ top: APPBAR_H + 20, bottom: dockHeight + 18, right: overlayPad, display: 'flex', alignItems: 'center' }}>
              <StopInsightCard {...cardProps} maxWidth={Math.min(560, w * 0.5)} height={Math.min(760, Math.max(420, h - (APPBAR_H + dockHeight + 44)))} />
            </div>
          )}

          <div className="hero-dock">
            <SavedTripsDock compact={isPhone} selectedTripId={selectedTrip?.id} onTripSelected={onTripSelected} />
          </div>
        </section>

        <section className="home-content" style={{ padding: `0 ${contentPad}px` }}>
          <div style={{ height: 24 }} />
          {showCard && isPhone && cardProps && (
            <>
              <h3 className="t-title-m bold" style={{ marginBottom: 12 }}>Selected Stop Insight</h3>
              <StopInsightCard {...cardProps} maxWidth={Math.max(0, Math.min(520, w - contentPad * 2))} height={Math.min(560, Math.max(300, h * 0.64))} />
              <div style={{ height: 24 }} />
            </>
          )}

          <SectionHeader title="Recommended Trips" seeAllText="View all" onSeeAll={() => navigate('/verified-trips')} />
          <div style={{ height: 16 }} />
          {verifiedError ? (
            <p className="t-body-s" style={{ color: 'rgba(0,0,0,.54)', padding: '12px 0' }}>Famous trips failed to load: {verifiedError}</p>
          ) : !verified ? (
            <div className="center" style={{ padding: 24 }}><Spinner /></div>
          ) : verified.length === 0 ? (
            <p style={{ padding: '12px 0' }}>No famous trips yet — check back soon.</p>
          ) : (
            <div className="vt-grid">{verifiedCards}</div>
          )}

          <div style={{ height: 24 }} />
          <SoftCard padding={20}>
            <div className="row gap-md">
              <div className="center" style={{ padding: 8, borderRadius: 12, background: 'rgba(74,173,232,.1)', color: 'var(--primary)' }}><MdAutoAwesome size={20} /></div>
              <h3 className="t-head-s grow">What You Can Do Today</h3>
            </div>
            <div className="col" style={{ marginTop: 16 }}>
              {FEATURES.map(([icon, text]) => (
                <div key={text} className="row gap-md" style={{ alignItems: 'flex-start', marginBottom: 12 }}>
                  <span style={{ color: 'var(--primary)', marginTop: 2 }}>{icon}</span>
                  <span className="muted" style={{ lineHeight: 1.5 }}>{text}</span>
                </div>
              ))}
            </div>
          </SoftCard>

          <div style={{ height: 24 }} />
          <SectionHeader title="Why Teams Choose Trypr" />
          <div style={{ height: 16 }} />
          <div className="value-grid">
            {VALUES.map(([icon, title, desc, tag]) => (
              <div key={title} className="soft-card" style={{ padding: 16 }}>
                <div className="row gap-md">
                  <div className="center" style={{ width: 40, height: 40, borderRadius: 12, background: 'rgba(74,173,232,.12)', color: 'var(--primary)' }}>{icon}</div>
                  <div className="grow t-title-l">{title}</div>
                </div>
                <p className="muted" style={{ marginTop: 12, lineHeight: 1.45 }}>{desc}</p>
                <span style={{ display: 'inline-block', marginTop: 8, padding: '4px 8px', borderRadius: 8, background: 'var(--surface-variant)', color: 'var(--text-3)', fontSize: 12, fontWeight: 500 }}>{tag}</span>
              </div>
            ))}
          </div>
          <div style={{ height: 32 }} />
        </section>

        <footer style={{ padding: '20px 0', background: 'var(--surface-variant)', textAlign: 'center' }} className="t-body-s">
          © Trypr 2026 • Practical trip planning for real groups
        </footer>
      </div>
      <span hidden>{String(globeReady)}</span>
    </div>
  )
}
