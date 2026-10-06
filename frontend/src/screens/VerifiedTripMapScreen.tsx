import { useEffect, useState } from 'react'
import { doc, getDoc } from 'firebase/firestore'
import { useLocation, useNavigate, useParams } from 'react-router-dom'
import { MdArrowBack } from 'react-icons/md'
import { db } from '@/firebase'
import MapEmbed from '@/components/map/MapEmbed'
import { Spinner } from '@/components/ui'
import { verifiedMapPoints } from './VerifiedTripsScreen'

/** `/verified-trips/:id/map` — full-screen route map for a verified trip. */
export default function VerifiedTripMapScreen() {
  const { id = '' } = useParams()
  const navigate = useNavigate()
  const state = (useLocation().state ?? {}) as { data?: Record<string, any> }
  const [data, setData] = useState<Record<string, any> | null>(state.data ?? null)
  const [error, setError] = useState('')

  useEffect(() => {
    if (data) return
    getDoc(doc(db, 'verifiedTrips', id))
      .then((s) => (s.exists() ? setData(s.data()) : setError('Trip not found')))
      .catch((e) => setError(e?.message ?? 'Failed to load trip'))
  }, [data, id])

  const title = String(data?.title ?? '').trim() || 'Verified trip'
  return (
    <div style={{ position: 'fixed', inset: 0, display: 'flex', flexDirection: 'column' }}>
      <div className="plan-topbar">
        <button className="icon-btn" title="Back" onClick={() => navigate(-1)}><MdArrowBack size={22} /></button>
        <span style={{ fontWeight: 600, fontSize: 18 }}>{title}</span>
      </div>
      <div style={{ flex: 1, minHeight: 0 }}>
        {data ? <MapEmbed points={verifiedMapPoints(Array.isArray(data.waypoints) ? data.waypoints : [])} /> : error ? <div className="center" style={{ height: '100%' }}>{error}</div> : <div className="center" style={{ height: '100%' }}><Spinner /></div>}
      </div>
    </div>
  )
}
