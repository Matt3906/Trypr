import { useEffect, useMemo, useState } from 'react'
import { doc, getDoc } from 'firebase/firestore'
import { useLocation, useNavigate, useParams } from 'react-router-dom'
import {
  MdArrowBack, MdAutoStories, MdCalendarToday, MdChevronRight, MdClose, MdFlag, MdMap, MdPhotoLibrary, MdPlace, MdSchedule, MdStraighten,
  MdTravelExplore, MdVerified,
} from 'react-icons/md'
import { db } from '@/firebase'
import MapEmbed from '@/components/map/MapEmbed'
import { Spinner } from '@/components/ui'
import { verifiedMapPoints } from './VerifiedTripsScreen'
import { TRAVEL_CATEGORIES } from '@/lib/planning'

type Row = Record<string, any>
const GREEN = '#00B894'

const asRows = (raw: unknown): Row[] => (Array.isArray(raw) ? raw.map((w) => (w && typeof w === 'object' ? { ...w } : {})) : [])

function StatCard({ icon, value, label, color }: { icon: React.ReactNode; value: string; label: string; color: string }) {
  return (
    <div className="row" style={{ gap: 12, padding: '16px 20px', borderRadius: 12, background: `${color}1a`, border: `1px solid ${color}33` }}>
      <span style={{ color }}>{icon}</span>
      <div>
        <div style={{ fontSize: 20, fontWeight: 700, color }}>{value}</div>
        <div style={{ fontSize: 12, color: '#757575' }}>{label}</div>
      </div>
    </div>
  )
}

const SectionTitle = ({ icon, children }: { icon: React.ReactNode; children: React.ReactNode }) => (
  <div className="row" style={{ gap: 10, marginBottom: 16, color: '#424242' }}>{icon}<h2 style={{ margin: 0, fontSize: 22, fontWeight: 700, color: '#333' }}>{children}</h2></div>
)

/** Travel-blog style detail view for verified trips. */
export function VerifiedTripDetail({ data }: { data: Row }) {
  const navigate = useNavigate()
  const [scroll, setScroll] = useState(0)
  const [viewer, setViewer] = useState<number | null>(null)
  const wide = typeof window !== 'undefined' && window.innerWidth >= 900
  const heroHeight = wide ? 500 : 350

  useEffect(() => {
    const el = document.getElementById('vtd-scroll')
    if (!el) return
    const on = () => setScroll(el.scrollTop)
    el.addEventListener('scroll', on, { passive: true })
    return () => el.removeEventListener('scroll', on)
  }, [])

  const title = String(data.title ?? 'Verified Trip')
  const subtitle = String(data.subtitle ?? '')
  const description = String(data.description ?? '')
  const cover = String(data.coverImage ?? '')
  const days = Number(data.recommendedDays ?? data.days ?? 0) || 0
  const totalStops = Number(data.totalStops ?? 0) || 0
  const totalKm = Number(data.totalKm ?? 0) || 0
  const waypoints = useMemo(() => asRows(data.waypoints), [data.waypoints])
  const photos: string[] = useMemo(() => (Array.isArray(data.photos) ? data.photos.map(String).filter(Boolean) : []), [data.photos])
  const itinerary = useMemo(() => asRows(data.itinerary), [data.itinerary])
  const points = useMemo(() => verifiedMapPoints(waypoints), [waypoints])
  const activityMarkers = useMemo(
    () =>
      itinerary.flatMap((day, dayIndex) =>
        asRows(day.activities)
          .map((a, activityIndex) => ({ a, activityIndex }))
          .filter(({ a }) => a.locationLat != null && a.locationLon != null)
          .map(({ a, activityIndex }) => ({ lat: a.locationLat, lon: a.locationLon, kind: 'activity', category: a.category ?? 'Sightseeing', dayIndex, activityIndex })),
      ),
    [itinerary],
  )
  const arr = (raw: unknown): string[] => (Array.isArray(raw) ? raw.map(String) : [])
  const routeVia = asRows(data.routeVia)

  const barOpacity = Math.max(0, Math.min(1, scroll / (heroHeight - 100)))

  return (
    <div style={{ position: 'fixed', inset: 0, background: 'var(--bg, #fff)' }}>
      <div style={{ position: 'absolute', top: 0, left: 0, right: 0, zIndex: 5, height: 56, display: 'flex', alignItems: 'center', gap: 12, padding: '0 8px', background: `rgba(255,255,255,${barOpacity})`, boxShadow: barOpacity > 0.5 ? '0 2px 4px rgba(0,0,0,0.12)' : 'none' }}>
        <button className="icon-btn" title="Back" onClick={() => navigate(-1)} style={{ background: barOpacity < 0.5 ? 'rgba(0,0,0,0.3)' : 'transparent', color: barOpacity < 0.5 ? '#fff' : undefined, borderRadius: '50%' }}><MdArrowBack size={22} /></button>
        <span style={{ fontSize: 20, fontWeight: 500, opacity: barOpacity }}>{title}</span>
      </div>

      <div id="vtd-scroll" style={{ position: 'absolute', inset: 0, overflowY: 'auto' }}>
        <div style={{ position: 'relative', height: heroHeight, width: '100%' }}>
          {cover ? (
            <img src={cover} alt="" style={{ width: '100%', height: '100%', objectFit: 'cover' }} onError={(e) => ((e.currentTarget.style.display = 'none'))} />
          ) : (
            <div className="center" style={{ width: '100%', height: '100%', background: 'linear-gradient(135deg, #26a69a, #1e88e5)', color: 'rgba(255,255,255,0.54)' }}><MdTravelExplore size={100} /></div>
          )}
          <div style={{ position: 'absolute', inset: 0, background: 'linear-gradient(to bottom, transparent, rgba(0,0,0,0.1) 50%, rgba(0,0,0,0.6))' }} />
          <div style={{ position: 'absolute', left: 24, right: 24, bottom: 32 }}>
            {subtitle && <span style={{ display: 'inline-block', padding: '6px 12px', borderRadius: 20, background: GREEN, color: '#fff', fontSize: 13, fontWeight: 600 }}>{subtitle}</span>}
            <h1 style={{ margin: '12px 0 0', fontSize: 36, fontWeight: 700, color: '#fff', textShadow: '0 0 10px rgba(0,0,0,0.54)' }}>{title}</h1>
          </div>
        </div>

        <div style={{ maxWidth: 1000, margin: '0 auto', padding: '32px 24px 60px' }}>
          <div className="row" style={{ alignItems: 'flex-start', gap: 16 }}>
            <div style={{ padding: 14, borderRadius: 16, background: `${GREEN}26`, color: GREEN }}><MdVerified size={32} /></div>
            <div>
              <div style={{ fontSize: 14, color: GREEN, fontWeight: 600, letterSpacing: 1.2 }}>Verified Adventure</div>
              <div style={{ marginTop: 4, fontSize: 16, color: '#757575', lineHeight: 1.5 }}>A curated {days}-day journey through {totalStops} amazing destinations</div>
            </div>
          </div>

          {description && (
            <div style={{ marginTop: 24, padding: 24, borderRadius: 16, background: '#fafafa', border: '1px solid #eee' }}>
              <div className="row" style={{ gap: 10, marginBottom: 16 }}><MdAutoStories size={22} color="#616161" /><b style={{ fontSize: 18, color: '#424242' }}>About This Trip</b></div>
              <div style={{ fontSize: 16, color: '#616161', lineHeight: 1.7, whiteSpace: 'pre-wrap' }}>{description}</div>
            </div>
          )}

          <div className="row wrap" style={{ gap: 16, marginTop: 32 }}>
            <StatCard icon={<MdCalendarToday size={24} />} value={String(days)} label="Days" color="#2196f3" />
            <StatCard icon={<MdPlace size={24} />} value={String(totalStops)} label="Stops" color="#ff9800" />
            <StatCard icon={<MdStraighten size={24} />} value={`${totalKm.toFixed(0)} km`} label="Distance" color="#009688" />
            <StatCard icon={<MdPhotoLibrary size={24} />} value={String(photos.length)} label="Photos" color="#9c27b0" />
          </div>

          {points.length > 0 && (
            <div style={{ marginTop: 40 }}>
              <SectionTitle icon={<MdMap size={24} />}>Route Overview</SectionTitle>
              <div style={{ height: 350, borderRadius: 16, overflow: 'hidden' }}>
                <MapEmbed
                  points={points} transportMode={String(data.transportMode ?? 'car')}
                  segmentTransportModes={arr(data.segmentTransportModes)} segmentRoutingTypes={arr(data.segmentRoutingTypes)}
                  routeVia={routeVia} secondaryPoints={activityMarkers} zoomControlsEnabled
                />
              </div>
            </div>
          )}

          {waypoints.length > 0 && (
            <div style={{ marginTop: 40 }}>
              <SectionTitle icon={<MdFlag size={24} />}>Destinations</SectionTitle>
              {waypoints.map((wp, i) => {
                const name = String(wp.name ?? `Stop ${i + 1}`)
                const d = wp.days ?? 1
                const last = i === waypoints.length - 1
                return (
                  <div key={i} style={{ display: 'flex', gap: 12 }}>
                    <div style={{ width: 40, display: 'flex', flexDirection: 'column', alignItems: 'center' }}>
                      <div style={{ width: 32, height: 32, borderRadius: '50%', background: GREEN, color: '#fff', fontWeight: 700, fontSize: 14, display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: `0 2px 8px ${GREEN}4d` }}>{i + 1}</div>
                      {!last && <div style={{ width: 2, flex: 1, margin: '4px 0', background: '#e0e0e0' }} />}
                    </div>
                    <div className="grow row" style={{ marginBottom: 16, padding: 16, borderRadius: 12, background: '#fff', border: '1px solid #eee', boxShadow: '0 2px 8px rgba(0,0,0,0.04)' }}>
                      <div className="grow"><div style={{ fontSize: 16, fontWeight: 600 }}>{name}</div><div style={{ marginTop: 4, fontSize: 14, color: '#757575' }}>{String(d)} {d === 1 ? 'day' : 'days'}</div></div>
                      <MdChevronRight size={24} color="#bdbdbd" />
                    </div>
                  </div>
                )
              })}
            </div>
          )}

          {photos.length > 0 && (
            <div style={{ marginTop: 40 }}>
              <SectionTitle icon={<MdPhotoLibrary size={24} />}>Photo Gallery</SectionTitle>
              <div className="row" style={{ gap: 12, overflowX: 'auto', alignItems: 'stretch' }}>
                {photos.map((p, i) => (
                  <img key={i} src={p} alt="" loading="lazy" onClick={() => setViewer(i)} style={{ height: 200, aspectRatio: '4 / 3', objectFit: 'cover', borderRadius: 12, cursor: 'pointer', flex: 'none', background: '#eee' }} />
                ))}
              </div>
            </div>
          )}

          {itinerary.length > 0 && (
            <div style={{ marginTop: 40 }}>
              <SectionTitle icon={<MdSchedule size={24} />}>Day-by-Day Itinerary</SectionTitle>
              {itinerary.map((day, di) => {
                const dayTitle = String(day.title ?? `Day ${di + 1}`)
                const notes = String(day.notes ?? '')
                const acts = asRows(day.activities)
                return (
                  <div key={di} style={{ marginBottom: 20, borderRadius: 16, background: '#fff', border: '1px solid #eee', boxShadow: '0 4px 10px rgba(0,0,0,0.04)' }}>
                    <div className="row" style={{ gap: 12, padding: 16, borderRadius: '16px 16px 0 0', background: `${GREEN}1a` }}>
                      <span style={{ padding: '6px 12px', borderRadius: 20, background: GREEN, color: '#fff', fontWeight: 600, fontSize: 13 }}>Day {di + 1}</span>
                      <span className="grow" style={{ fontSize: 16, fontWeight: 600 }}>{dayTitle !== `Day ${di + 1}` ? dayTitle : ''}</span>
                      <span style={{ fontSize: 13, color: '#757575' }}>{acts.length} {acts.length === 1 ? 'activity' : 'activities'}</span>
                    </div>
                    {notes && <div style={{ padding: '12px 16px 0', fontSize: 14, color: '#757575', fontStyle: 'italic' }}>{notes}</div>}
                    {acts.length > 0 ? (
                      <div style={{ padding: 16 }}>
                        {acts.map((a, ai) => {
                          const loc = String(a.location ?? '').trim()
                          const cat = String(a.category ?? '')
                          const time = String(a.time ?? '')
                          return (
                            <div key={ai} style={{ display: 'flex', alignItems: 'flex-start', marginBottom: ai < acts.length - 1 ? 12 : 0 }}>
                              <div style={{ width: 70, fontSize: 13, color: '#9e9e9e', fontWeight: 500, flex: 'none' }}>{time || '•'}</div>
                              <div className="grow">
                                <div className="row" style={{ gap: 4 }}>
                                  {loc && cat in TRAVEL_CATEGORIES && <span style={{ width: 10, height: 10, borderRadius: '50%', background: TRAVEL_CATEGORIES[cat], flex: 'none' }} />}
                                  {loc && <MdPlace size={16} color="#1976d2" />}
                                  <span style={{ fontSize: 15, fontWeight: 600 }}>{String(a.title ?? '')}</span>
                                </div>
                                {loc && <div style={{ marginTop: 2, fontSize: 13, color: '#1e88e5', fontWeight: 500 }}>📍 {loc}</div>}
                                {String(a.description ?? '') && <div style={{ marginTop: 4, fontSize: 14, color: '#757575' }}>{String(a.description)}</div>}
                              </div>
                            </div>
                          )
                        })}
                      </div>
                    ) : (
                      <div style={{ padding: 16, fontSize: 14, color: '#bdbdbd', fontStyle: 'italic' }}>No activities planned yet</div>
                    )}
                  </div>
                )
              })}
            </div>
          )}
        </div>
      </div>

      {viewer != null && (
        <div style={{ position: 'fixed', inset: 0, zIndex: 1000, background: '#000', display: 'flex', alignItems: 'center', justifyContent: 'center' }} onClick={() => setViewer(null)}>
          <button className="icon-btn" style={{ position: 'absolute', top: 8, right: 8, color: '#fff' }} onClick={() => setViewer(null)}><MdClose size={24} /></button>
          <button className="icon-btn" style={{ position: 'absolute', left: 8, color: '#fff' }} disabled={viewer <= 0} onClick={(e) => { e.stopPropagation(); setViewer(viewer - 1) }}><MdArrowBack size={28} /></button>
          <img src={photos[viewer]} alt="" style={{ maxWidth: '92vw', maxHeight: '92vh', objectFit: 'contain' }} onClick={(e) => e.stopPropagation()} onError={() => undefined} />
          <button className="icon-btn" style={{ position: 'absolute', right: 8, color: '#fff' }} disabled={viewer >= photos.length - 1} onClick={(e) => { e.stopPropagation(); setViewer(viewer + 1) }}><MdChevronRight size={28} /></button>
        </div>
      )}
    </div>
  )
}

/** `/verified-trips/:id` */
export default function VerifiedTripDetailRoute() {
  const { id = '' } = useParams()
  const state = (useLocation().state ?? {}) as { data?: Row }
  const [data, setData] = useState<Row | null>(state.data ?? null)
  const [error, setError] = useState('')

  useEffect(() => {
    if (data) return
    getDoc(doc(db, 'verifiedTrips', id))
      .then((s) => (s.exists() ? setData(s.data()) : setError('Trip not found')))
      .catch((e) => setError(e?.message ?? 'Failed to load trip'))
  }, [data, id])

  if (data) return <VerifiedTripDetail data={data} />
  return <div className="center" style={{ height: '100vh' }}>{error || <Spinner />}</div>
}
