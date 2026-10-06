import { useEffect, useMemo, useState } from 'react'
import { addDoc, collection, deleteDoc, doc, getDoc, orderBy, query, serverTimestamp, Timestamp } from 'firebase/firestore'
import {
  MdAdd, MdLogin, MdLuggage, MdMailOutline, MdMoreVert, MdMoveToInbox, MdOutlineMap, MdPeople, MdOutlinePeopleAlt, MdOutlinePlace, MdRoute, MdTune,
} from 'react-icons/md'
import { useNavigate } from 'react-router-dom'
import { db } from '@/firebase'
import PageShell from '@/components/PageShell'
import MapPreview from '@/components/MapPreview'
import ShareTripDialog from '@/components/ShareTripDialog'
import { Button, CenteredSpinner, Menu, MenuItem, SoftCard } from '@/components/ui'
import { useAuth } from '@/context/Auth'
import { useFeedback } from '@/context/Feedback'
import { useQuerySnapshot } from '@/hooks/useFirestore'
import { inferTripDifficultyLabel, isAdventureTripType, normalizeTripType, tripTypeBadgeLabel } from '@/models/tripModel'
import { resolvedTripData } from '@/services/tripsService'

const segModes = (d: Record<string, any>): string[] => (Array.isArray(d.segmentTransportModes) ? d.segmentTransportModes.map(String) : [])

const prettyDate = (ts: unknown): string => {
  if (ts instanceof Timestamp) {
    const d = ts.toDate()
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  }
  return String(ts)
}

function dateRange(d: Record<string, any>): string {
  const start = String(d.startDate ?? '').trim()
  const end = String(d.endDate ?? '').trim()
  if (start && end) return `${start} – ${end}`
  if (start) return start
  if (end) return end
  return d.createdAt ? prettyDate(d.createdAt) : 'Dates TBD'
}

function tripTypeBadge(d: Record<string, any>) {
  return tripTypeBadgeLabel(normalizeTripType(String(d.tripType ?? ''), { transportMode: String(d.transportMode ?? ''), segmentTransportModes: segModes(d) }))
}
function difficultyBadge(d: Record<string, any>, stopCount: number) {
  const type = normalizeTripType(String(d.tripType ?? ''), { transportMode: String(d.transportMode ?? ''), segmentTransportModes: segModes(d) })
  if (!isAdventureTripType(type) && type !== 'mixed') return ''
  return inferTripDifficultyLabel({
    tripType: type, experienceLevel: String(d.experienceLevel ?? ''), distanceKm: d.totalKm, estimatedDurationMin: d.estimatedDurationMin, stopCount, segmentTransportModes: segModes(d),
  })
}

const Badge = ({ icon, text }: { icon: React.ReactNode; text: string }) => (
  <span className="frost-badge">{icon}{text}</span>
)

function StatTile({ icon, label, value, accent }: { icon: React.ReactNode; label: string; value: string | number; accent: string }) {
  return (
    <div className="row gap-md" style={{ padding: 12, background: '#fff', borderRadius: 'var(--r-lg)', border: `1px solid color-mix(in srgb, ${accent} 25%, transparent)`, boxShadow: 'var(--shadow-soft)' }}>
      <div className="center" style={{ width: 34, height: 34, borderRadius: 10, background: `color-mix(in srgb, ${accent} 14%, transparent)`, color: accent }}>{icon}</div>
      <div>
        <div style={{ fontSize: 16, fontWeight: 700 }}>{value}</div>
        <div className="muted" style={{ fontSize: 12, fontWeight: 500 }}>{label}</div>
      </div>
    </div>
  )
}

export default function MyTripsScreen() {
  const { user, loading: authLoading } = useAuth()
  const { toast, confirm } = useFeedback()
  const navigate = useNavigate()
  const [shareTarget, setShareTarget] = useState<{ id: string; name: string } | null>(null)

  const trips = useQuerySnapshot(user ? query(collection(db, 'users', user.uid, 'trips'), orderBy('createdAt', 'desc')) : null, [user?.uid])
  const shared = useQuerySnapshot(user ? query(collection(db, 'users', user.uid, 'sharedTrips'), orderBy('createdAt', 'desc')) : null, [user?.uid])

  const docs = trips.data
  const sdocs = shared.data
  const sharedByMe = docs.filter((d) => Array.isArray(d.data().sharedWith) && d.data().sharedWith.length).length
  const totalStops = docs.reduce((n, d) => n + (Array.isArray(d.data().waypoints) ? d.data().waypoints.length : 0), 0)
  const avgStops = docs.length ? Math.round(totalStops / docs.length) : 0
  const userName = user?.displayName ?? user?.email?.split('@')[0] ?? 'Traveler'

  const [w, setW] = useState(window.innerWidth)
  useEffect(() => {
    const on = () => setW(window.innerWidth)
    window.addEventListener('resize', on)
    return () => window.removeEventListener('resize', on)
  }, [])

  const openTrip = async (docId: string, data: Record<string, any>) => {
    if (!user) return
    const resolved = await resolvedTripData(user.uid, docId, data)
    navigate(`/my-trips/${docId}`, { state: { data: resolved } })
  }

  const openShared = async (sharedDoc: { data: () => Record<string, any> }) => {
    const data = sharedDoc.data()
    const tripRefPath = String(data.tripRef ?? '')
    if (!tripRefPath) return
    try {
      const tripDoc = await getDoc(doc(db, tripRefPath))
      if (!tripDoc.exists()) return toast('Trip not available')
      const [, ownerUid, , tripId] = tripRefPath.split('/')
      navigate(`/trip/${ownerUid}/${tripId ?? tripDoc.id}`)
    } catch (e: any) {
      toast(`Open failed: ${e?.message ?? e}`)
    }
  }

  const acceptShared = async (sd: { id: string; data: () => Record<string, any> }) => {
    if (!user) return
    const data = sd.data()
    const tripRefPath = String(data.tripRef ?? '')
    if (!tripRefPath) return
    try {
      const tripDoc = await getDoc(doc(db, tripRefPath))
      if (!tripDoc.exists()) return toast('Original trip not found')
      const ownerName = data.ownerName ?? data.ownerUid ?? ''
      const remote = tripDoc.data() ?? {}
      const wps = remote.waypoints ?? remote.stops
      await addDoc(collection(db, 'users', user.uid, 'trips'), {
        name: data.tripName ?? remote.name ?? 'Shared Trip',
        tripRef: tripRefPath,
        sharedFrom: ownerName,
        ...(Array.isArray(wps) && wps.length ? { waypoints: wps } : {}),
        ...Object.fromEntries(['startDate', 'endDate', 'totalKm', 'transportMode', 'segmentTransportModes', 'segmentRoutingTypes', 'routeVia', 'transitArrivalStop'].filter((k) => remote[k] != null).map((k) => [k, remote[k]])),
        createdAt: serverTimestamp(),
      })
      await deleteDoc(doc(db, 'users', user.uid, 'sharedTrips', sd.id))
      toast('Trip accepted and added to My Trips')
    } catch (e: any) {
      toast(`Accept failed: ${e?.message ?? e}`)
    }
  }

  const declineShared = async (id: string) => {
    if (!user) return
    try {
      await deleteDoc(doc(db, 'users', user.uid, 'sharedTrips', id))
      toast('Shared invite declined')
    } catch (e: any) {
      toast(`Decline failed: ${e?.message ?? e}`)
    }
  }

  const deleteTrip = async (id: string) => {
    if (!user) return
    const ok = await confirm({ title: 'Delete trip?', message: 'This will permanently delete the trip.', confirmLabel: 'Delete', danger: true })
    if (!ok) return
    await deleteDoc(doc(db, 'users', user.uid, 'trips', id))
    toast('Trip deleted')
  }

  const cols = w >= 1100 ? 3 : w >= 720 ? 2 : 1
  const compact = w < 760
  const cards = useMemo(() => docs, [docs])

  return (
    <PageShell>
      <div className="container col gap-md" style={{ maxWidth: 1280, padding: '16px 24px' }}>
        {authLoading || (user && trips.loading) ? (
          <CenteredSpinner />
        ) : !user ? (
          <div className="center" style={{ padding: 40 }}>
            <SoftCard elevated padding={20}>
              <div className="col center gap-md" style={{ textAlign: 'center' }}>
                <div className="center" style={{ width: 56, height: 56, borderRadius: 'var(--r-lg)', background: 'rgba(74,173,232,.12)', color: 'var(--primary-dark)' }}><MdRoute size={28} /></div>
                <h3 className="t-title-l bold">Sign in to view your saved trips</h3>
                <p className="muted">Your past and upcoming adventures will appear here.</p>
                <Button icon={<MdLogin size={18} />} onClick={() => navigate('/sign-in')}>Sign in</Button>
              </div>
            </SoftCard>
          </div>
        ) : (
          <>
            <div style={{ padding: 20, borderRadius: 'var(--r-xl)', boxShadow: 'var(--shadow-elevated)', background: 'linear-gradient(135deg,#1d74b7,var(--primary),#2bb7a2)', color: '#fff' }} className={compact ? 'col gap-md' : 'row gap-lg'}>
              <div className="grow">
                <h1 style={{ fontSize: compact ? 20 : 24, fontWeight: 700 }}>Welcome back, {userName}</h1>
                <p style={{ marginTop: 6, fontSize: 14 }}>Your adventures, shared plans, and route ideas all in one place.</p>
              </div>
              <button className="btn btn-sm" style={{ background: '#fff', color: 'var(--primary-dark)', padding: '12px 20px', borderRadius: 12 }} onClick={() => navigate('/trip-builder')}><MdAdd size={18} />Create New Trip</button>
            </div>

            <div className="stat-grid">
              <StatTile icon={<MdOutlineMap size={18} />} label="Total Trips" value={docs.length} accent="var(--primary)" />
              <StatTile icon={<MdMailOutline size={18} />} label="Shared Invites" value={sdocs.length} accent="var(--secondary)" />
              <StatTile icon={<MdOutlinePeopleAlt size={18} />} label="Trips You Shared" value={sharedByMe} accent="var(--peach)" />
              <StatTile icon={<MdRoute size={18} />} label="Avg Stops per Trip" value={avgStops} accent="var(--mint)" />
            </div>

            {sdocs.length > 0 && (
              <SoftCard elevated padding={16}>
                <div className="row gap-sm">
                  <div className="center" style={{ width: 34, height: 34, borderRadius: 10, background: 'rgba(0,137,123,.14)', color: 'var(--secondary)' }}><MdMoveToInbox size={18} /></div>
                  <h3 className="t-title-m bold grow">Shared Trip Invites</h3>
                  <span className="t-body-s muted">{sdocs.length} pending</span>
                </div>
                <div className="row gap-md" style={{ overflowX: 'auto', marginTop: 12, alignItems: 'stretch' }}>
                  {sdocs.map((sd) => {
                    const sdata = sd.data()
                    return (
                      <div key={sd.id} className="col" style={{ width: 320, flex: 'none', height: 160, padding: 12, borderRadius: 'var(--r-lg)', border: '1px solid #e5eef7', background: 'linear-gradient(135deg,#f7fbff,#fff)', justifyContent: 'space-between' }}>
                        <div>
                          <div className="bold" style={{ fontSize: 15 }}>{String(sdata.tripName ?? 'Shared Trip')}</div>
                          <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>From {String(sdata.ownerName ?? sdata.ownerUid ?? 'Someone')}</div>
                        </div>
                        <div className="row wrap gap-sm">
                          <Button size="sm" variant="solid" onClick={() => openShared(sd)}>Open</Button>
                          <Button size="sm" variant="outlined" onClick={() => acceptShared(sd)}>Accept</Button>
                          <Button size="sm" variant="text" onClick={() => declineShared(sd.id)}>Decline</Button>
                        </div>
                      </div>
                    )
                  })}
                </div>
              </SoftCard>
            )}

            <h2 className="t-head-m bold" style={{ marginTop: 8 }}>My Trips</h2>
            {docs.length === 0 ? (
              <SoftCard elevated padding={20}>
                <div className="col center gap-md" style={{ textAlign: 'center' }}>
                  <div className="center" style={{ width: 56, height: 56, borderRadius: 'var(--r-lg)', background: 'var(--surface-variant)', color: 'var(--text-2)' }}><MdLuggage size={28} /></div>
                  <h3 className="t-title-l bold">No saved trips yet</h3>
                  <p className="muted">Create your first itinerary and it will appear here.</p>
                  <Button icon={<MdAdd size={18} />} onClick={() => navigate('/trip-builder')}>Create a trip</Button>
                </div>
              </SoftCard>
            ) : (
              <div style={{ display: 'grid', gridTemplateColumns: `repeat(${cols}, 1fr)`, gap: 16, padding: '8px 0' }}>
                {cards.map((d) => {
                  const data = d.data()
                  const name = String(data.name ?? 'Untitled Trip')
                  const waypoints: any[] = Array.isArray(data.waypoints) ? data.waypoints : []
                  const stopCount = waypoints.length
                  const isShared = (Array.isArray(data.sharedWith) && data.sharedWith.length > 0) || (data.sharedFrom != null && String(data.sharedFrom).length > 0)
                  const diff = difficultyBadge(data, stopCount)
                  const emoji = String(data.emoji ?? data.tripEmoji ?? '').trim() || '🧭'
                  return (
                    <div key={d.id} className="trip-card" style={{ aspectRatio: cols === 1 ? 1.9 : cols === 2 ? 1.35 : 1.1 }} onClick={() => openTrip(d.id, data)}>
                      <div style={{ position: 'absolute', inset: 0, background: '#e5eef5' }}>
                        <MapPreview waypoints={waypoints} routeGeometry={data.routeGeometry3d ?? []} transportMode={String(data.transportMode ?? 'car')} segmentTransportModes={segModes(data)} />
                      </div>
                      <div style={{ position: 'absolute', inset: 0, background: 'linear-gradient(to top, rgba(0,0,0,.72), rgba(0,0,0,.24), transparent)' }} />
                      <div style={{ position: 'absolute', top: 12, left: 12 }} onClick={(e) => e.stopPropagation()}>
                        <div style={{ background: 'rgba(0,0,0,.42)', borderRadius: 999 }}>
                          <Menu align="left" trigger={<button className="icon-btn" style={{ color: '#fff' }} aria-label="Trip actions"><MdMoreVert size={20} /></button>}>
                            {(close) => (
                              <>
                                <MenuItem onClick={() => { close(); setShareTarget({ id: d.id, name }) }}>Share</MenuItem>
                                <MenuItem onClick={() => { close(); void deleteTrip(d.id) }}>Delete</MenuItem>
                              </>
                            )}
                          </Menu>
                        </div>
                      </div>
                      <div className="row wrap gap-sm" style={{ position: 'absolute', top: 12, right: 12, justifyContent: 'flex-end' }}>
                        <Badge icon={<MdOutlinePlace size={12} />} text={`${stopCount} stops`} />
                        {isShared && <Badge icon={<MdPeople size={12} />} text="Shared" />}
                      </div>
                      <div className="row gap-sm" style={{ position: 'absolute', left: 14, right: 14, bottom: 14, padding: 12, background: 'rgba(0,0,0,.38)', borderRadius: 'var(--r-lg)', alignItems: 'flex-end' }}>
                        <span style={{ fontSize: 22 }}>{emoji}</span>
                        <div className="grow">
                          <div className="ellipsis" style={{ fontSize: 18, fontWeight: 700, color: '#fff' }}>{name}</div>
                          <div className="ellipsis" style={{ color: 'rgba(255,255,255,.9)', fontSize: 13, marginTop: 4 }}>{dateRange(data)}</div>
                          <div className="row wrap" style={{ gap: 6, marginTop: 6 }}>
                            <Badge icon={<MdRoute size={12} />} text={tripTypeBadge(data)} />
                            {diff && <Badge icon={<MdTune size={12} />} text={diff} />}
                          </div>
                        </div>
                      </div>
                    </div>
                  )
                })}
              </div>
            )}
          </>
        )}
      </div>
      {shareTarget && user && (
        <ShareTripDialog open onClose={() => setShareTarget(null)} tripRefPath={`users/${user.uid}/trips/${shareTarget.id}`} tripId={shareTarget.id} tripName={shareTarget.name} />
      )}
    </PageShell>
  )
}
