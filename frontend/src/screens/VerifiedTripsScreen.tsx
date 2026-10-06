import { useState } from 'react'
import { collection, deleteDoc, doc, orderBy, query } from 'firebase/firestore'
import { useNavigate } from 'react-router-dom'
import { MdAdd, MdCalendarToday, MdDelete, MdEdit, MdInfo, MdOutlineVerified, MdPlace, MdShield, MdVerified } from 'react-icons/md'
import { db } from '@/firebase'
import { useAuth } from '@/context/Auth'
import { useFeedback } from '@/context/Feedback'
import { useQuerySnapshot } from '@/hooks/useFirestore'
import PageShell from '@/components/PageShell'
import MapEmbed from '@/components/map/MapEmbed'
import { Button, CenteredSpinner, SoftCard } from '@/components/ui'

type Row = Record<string, any>

export const verifiedDateRange = (data: Row) => {
  const subtitle = String(data.subtitle ?? '').trim()
  const days = data.recommendedDays ?? data.days
  if (subtitle) return subtitle
  if (typeof days === 'number') return `Recommended: ${days} days`
  return 'Verified itinerary'
}
export const verifiedTripEmoji = (data: Row) => String(data.emoji ?? data.tripEmoji ?? '').trim() || '✅'
export const verifiedMapPoints = (waypoints: Row[]) =>
  waypoints.map((w) => ({ lat: w.lat ?? w.latitude ?? 0, lon: w.lon ?? w.longitude ?? w.lng ?? 0, name: w.name ?? '' }))
const toInt = (raw: unknown) => (typeof raw === 'number' ? Math.round(raw) : parseInt(String(raw ?? ''), 10) || 0)

function StatTile({ icon, label, value, accent }: { icon: React.ReactNode; label: string; value: string; accent: string }) {
  return (
    <div className="vt-stat" style={{ borderColor: `${accent}40` }}>
      <div className="vt-stat-icon" style={{ background: `${accent}24`, color: accent }}>{icon}</div>
      <div>
        <div style={{ fontSize: 16, fontWeight: 700 }}>{value}</div>
        <div className="muted" style={{ fontSize: 12, fontWeight: 500 }}>{label}</div>
      </div>
    </div>
  )
}

function TripCard({ id, data, isAdmin, onDelete }: { id: string; data: Row; isAdmin: boolean; onDelete: (id: string, title: string) => void }) {
  const navigate = useNavigate()
  const [imgFailed, setImgFailed] = useState(false)
  const title = String(data.title ?? '')
  const subtitle = String(data.subtitle ?? '')
  const cover = String(data.coverImage ?? '')
  const waypoints: Row[] = Array.isArray(data.waypoints) ? data.waypoints : []
  const stops = typeof data.totalStops === 'number' ? Math.round(data.totalStops) : waypoints.length

  return (
    <div className="vt-card" onClick={() => navigate(`/verified-trips/${id}`, { state: { data } })}>
      {cover && !imgFailed ? (
        <img src={cover} alt="" loading="lazy" onError={() => setImgFailed(true)} />
      ) : (
        <div className="vt-cover"><MapEmbed points={verifiedMapPoints(waypoints)} disableDefaultUi disableGestures zoomControlsEnabled={false} /></div>
      )}
      <div className="vt-card-shade" />
      {isAdmin && (
        <div className="row gap-sm" style={{ position: 'absolute', top: 12, left: 12 }} onClick={(e) => e.stopPropagation()}>
          <button className="vt-round" title="Edit Trip" onClick={() => navigate(`/verified-trips/${id}/edit`, { state: { data } })}><MdEdit size={18} /></button>
          <button className="vt-round" title="Delete Trip" style={{ color: '#ef4444' }} onClick={() => onDelete(id, title)}><MdDelete size={18} /></button>
        </div>
      )}
      <div style={{ position: 'absolute', top: 12, right: 12, display: 'flex', alignItems: 'center', gap: 6, padding: '6px 10px', borderRadius: 999, background: 'rgba(0,0,0,0.55)', color: '#fff', fontSize: 12, fontWeight: 600 }}>
        <MdVerified size={14} /> Verified
      </div>
      <div className="vt-card-info">
        {subtitle && <div style={{ display: 'inline-block', marginBottom: 8, padding: '4px 10px', borderRadius: 12, background: '#00B894', fontSize: 11, fontWeight: 600 }}>{subtitle}</div>}
        <div className="row" style={{ gap: 8, alignItems: 'center' }}>
          <span style={{ fontSize: 20 }}>{verifiedTripEmoji(data)}</span>
          <span style={{ fontSize: 20, fontWeight: 700, overflow: 'hidden', display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical' }}>{title || 'Verified Trip'}</span>
        </div>
        <div className="row wrap gap-sm" style={{ marginTop: 8 }}>
          <span className="vt-chip"><MdCalendarToday size={12} /> {toInt(data.recommendedDays ?? data.days)} days</span>
          <span className="vt-chip"><MdPlace size={12} /> {stops} stops</span>
          <span className="vt-chip"><MdInfo size={12} /> {verifiedDateRange(data)}</span>
        </div>
      </div>
    </div>
  )
}

export default function VerifiedTripsScreen() {
  const navigate = useNavigate()
  const { isAdmin } = useAuth()
  const { confirm, toast } = useFeedback()
  const { data: docs, loading, error } = useQuerySnapshot(query(collection(db, 'verifiedTrips'), orderBy('createdAt', 'desc')), [])

  const deleteTrip = async (id: string, title: string) => {
    const ok = await confirm({ title: 'Delete Verified Trip', message: `Are you sure you want to delete "${title}"?\n\nThis action cannot be undone.`, confirmLabel: 'Delete', danger: true })
    if (!ok) return
    try {
      await deleteDoc(doc(db, 'verifiedTrips', id))
      toast(`Deleted "${title}"`)
    } catch (e: any) {
      toast(`Failed to delete: ${e?.message ?? e}`)
    }
  }

  const totalStops = docs.reduce((t, d) => {
    const data = d.data()
    if (typeof data.totalStops === 'number') return t + Math.round(data.totalStops)
    return t + (Array.isArray(data.waypoints) ? data.waypoints.length : 0)
  }, 0)
  const totalDays = docs.reduce((t, d) => t + toInt(d.data().recommendedDays ?? d.data().days), 0)
  const avgDays = docs.length ? Math.round(totalDays / docs.length) : 0

  return (
    <PageShell>
      <div className="container" style={{ maxWidth: 1280, padding: '28px 24px 40px' }}>
        {error ? (
          <div className="center col" style={{ textAlign: 'center', padding: 16, maxWidth: 640, margin: '0 auto' }}>
            <b>Failed to load verified trips</b>
            <p className="muted" style={{ fontSize: 13 }}>{String(error.message ?? error)}</p>
            <p>If this mentions permissions, make sure your Firestore rules are deployed and that your admin document ID exactly matches your Firebase Auth UID.</p>
          </div>
        ) : loading ? (
          <CenteredSpinner />
        ) : (
          <div className="col gap-lg" style={{ alignItems: 'stretch' }}>
            <div className="vt-hero row wrap between" style={{ gap: 16 }}>
              <div>
                <h1 className="t-display-m" style={{ margin: 0 }}>Verified Trips</h1>
                <div style={{ marginTop: 6, fontSize: 14 }}>Curated itineraries tested and reviewed by trusted travelers.</div>
              </div>
              {isAdmin && <Button icon={<MdAdd size={18} />} onClick={() => navigate('/verified-trips/new')}>Create Trip</Button>}
            </div>

            <div className="stat-grid" style={{ gap: 12 }}>
              <StatTile icon={<MdOutlineVerified size={18} />} label="Itineraries" value={String(docs.length)} accent="#6366f1" />
              <StatTile icon={<MdPlace size={18} />} label="Total Stops" value={String(totalStops)} accent="#4aade8" />
              <StatTile icon={<MdCalendarToday size={18} />} label="Avg Recommended Days" value={String(avgDays)} accent="#fb923c" />
              <StatTile icon={<MdShield size={18} />} label="Curation Level" value="Verified" accent="#00b894" />
            </div>

            {docs.length === 0 ? (
              <SoftCard elevated padding={32} className="center col gap-md" style={{ textAlign: 'center' }}>
                <div style={{ width: 56, height: 56, borderRadius: 16, background: 'var(--surface-variant)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><MdOutlineVerified size={28} className="muted" /></div>
                <h3 className="t-head-s" style={{ margin: 0 }}>No verified trips yet</h3>
                {isAdmin && <Button icon={<MdAdd size={18} />} onClick={() => navigate('/verified-trips/new')}>Create first trip</Button>}
              </SoftCard>
            ) : (
              <div className="vt-grid">
                {docs.map((d) => <TripCard key={d.id} id={d.id} data={d.data()} isAdmin={isAdmin} onDelete={deleteTrip} />)}
              </div>
            )}
          </div>
        )}
      </div>
    </PageShell>
  )
}
