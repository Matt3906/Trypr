import { lazy, Suspense, useEffect, useState } from 'react'
import { doc, getDoc, serverTimestamp, setDoc } from 'firebase/firestore'
import { MdArrowBack, MdErrorOutline, MdHourglassTop, MdLockOutline, MdLogin, MdPersonAdd, MdOutlineVisibility } from 'react-icons/md'
import { useNavigate, useParams } from 'react-router-dom'
import { db } from '@/firebase'
import { Button, Spinner } from '@/components/ui'
import { useAuth } from '@/context/Auth'
import { useBack } from '@/hooks/useBack'

const TripDetailScreen = lazy(() => import('./TripDetailScreen'))

/**
 * Handles `/trip/:ownerUid/:tripId` deep links.
 * - signed-in owner / shared-with  → full editing
 * - signed-in but not shared       → read-only if shareLinkEnabled, else join-request flow
 * - not signed-in                  → public preview if shareLinkEnabled, else sign-in prompt
 */
export default function TripLinkScreen() {
  const { ownerUid = '', tripId = '' } = useParams()
  const { user, loading: authLoading } = useAuth()
  const navigate = useNavigate()
  const back = useBack('/')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [data, setData] = useState<Record<string, any> | null>(null)
  const [readOnly, setReadOnly] = useState(true)
  const [publicPreview, setPublicPreview] = useState(false)
  const tripRefPath = `users/${ownerUid}/trips/${tripId}`

  const resolveTrip = async () => {
    setLoading(true)
    setError(null)
    try {
      let snap
      try {
        snap = await Promise.race([getDoc(doc(db, tripRefPath)), new Promise<never>((_, rej) => setTimeout(() => rej(new Error('timeout')), 10000))])
      } catch (e) {
        console.debug('TripLinkScreen: get() failed', e)
        setError(user ? 'no-access' : 'sign-in-required')
        return
      }
      if (!snap.exists()) {
        setError('Trip not found')
        return
      }
      const d = snap.data()
      const tripData = { ...d, tripRef: tripRefPath }
      const shareLinkEnabled = d.shareLinkEnabled === true
      if (!user && !shareLinkEnabled) {
        setError('sign-in-required')
        return
      }
      const hasEditAccess = !user ? false : user.uid === ownerUid ? true : Array.isArray(d.sharedWith) && d.sharedWith.includes(user.uid)
      setData(tripData)
      setReadOnly(!hasEditAccess)
      setPublicPreview(!user)
    } catch (e: any) {
      setError(`Something went wrong: ${e?.message ?? e}`)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    if (authLoading) return
    void resolveTrip()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [authLoading, user?.uid, ownerUid, tripId])

  const sendJoinRequest = async () => {
    if (!user) return
    setLoading(true)
    try {
      let name = (user.displayName ?? '').trim()
      if (!name) {
        const pub = await getDoc(doc(db, 'publicUsers', user.uid))
        name = String(pub.data()?.name ?? '').trim()
      }
      if (!name) name = 'Someone'
      const ref = doc(db, 'tripJoinRequests', `${ownerUid}_${tripId}_${user.uid}`)
      const existing = await getDoc(ref)
      if (existing.exists()) {
        if (String(existing.data()?.status ?? '') === 'approved') return void (await resolveTrip())
        setError('request-pending')
        return
      }
      await setDoc(ref, { tripRef: tripRefPath, ownerUid, tripId, requesterUid: user.uid, requesterName: name, status: 'pending', createdAt: serverTimestamp() })
      setError('request-sent')
    } catch (e: any) {
      setError(`Failed to send request: ${e?.message ?? e}`)
    } finally {
      setLoading(false)
    }
  }

  if (data) {
    if (publicPreview) {
      const title = String(data.name ?? 'Shared Trip').trim() || 'Shared Trip'
      const start = String(data.startDate ?? '').trim()
      const end = String(data.endDate ?? '').trim()
      const totalDays = typeof data.totalDays === 'number' ? Math.trunc(data.totalDays) : null
      const wps: any[] = Array.isArray(data.waypoints) ? data.waypoints.filter((w) => w && typeof w === 'object') : []
      const subtitle = [
        start && end ? `${start} to ${end}` : '',
        totalDays && totalDays > 0 ? `${totalDays} day${totalDays === 1 ? '' : 's'}` : '',
        `${wps.length} stop${wps.length === 1 ? '' : 's'}`,
      ].filter(Boolean).join(' • ')
      return (
        <div className="container col gap-md" style={{ maxWidth: 860, padding: '28px 24px' }}>
          <button className="icon-btn" title="Back" onClick={back}><MdArrowBack size={22} /></button>
          <h1 style={{ fontSize: 32, fontWeight: 800 }}>{title}</h1>
          <div className="muted" style={{ fontSize: 15 }}>{subtitle}</div>
          <div className="row gap-md" style={{ padding: 16, background: '#f3f4f6', borderRadius: 16, alignItems: 'flex-start' }}>
            <MdOutlineVisibility size={20} />
            <span style={{ lineHeight: 1.35 }}>You are viewing a public preview. Sign in to request access and collaborate on this trip.</span>
          </div>
          <h3 className="t-head-s bold" style={{ marginTop: 8 }}>Stops</h3>
          {wps.length === 0 ? (
            <div style={{ padding: 16, background: '#fafafa', border: '1px solid #e5e7eb', borderRadius: 14 }}>No stops added yet.</div>
          ) : (
            wps.map((wp, i) => (
              <div key={i} className="row gap-md" style={{ padding: '12px 14px', background: '#fff', border: '1px solid #e5e7eb', borderRadius: 12 }}>
                <span className="center" style={{ width: 28, height: 28, borderRadius: '50%', background: '#111827', color: '#fff', fontSize: 12, fontWeight: 700 }}>{i + 1}</span>
                <span style={{ fontWeight: 600 }}>{String(wp.name ?? '').trim() || `Stop ${i + 1}`}</span>
              </div>
            ))
          )}
          <div className="row wrap gap-md" style={{ marginTop: 8 }}>
            <button className="btn" style={{ background: '#111827', color: '#fff', borderRadius: 999 }} onClick={() => navigate('/sign-in')}><MdLogin size={18} />Sign in to join</button>
            <Button variant="outlined" onClick={() => navigate('/create-account')}>Create account</Button>
          </div>
        </div>
      )
    }
    return (
      <Suspense fallback={<div className="center" style={{ height: '100vh' }}><Spinner /></div>}>
        <TripDetailScreen docId={tripId} data={data} readOnly={readOnly} ownerUid={ownerUid} />
      </Suspense>
    )
  }

  if (loading || authLoading) {
    return (
      <div className="center col gap-md" style={{ height: '100vh' }}>
        <Spinner />
        <span>Loading trip…</span>
      </div>
    )
  }

  const dark = { background: '#111827', color: '#fff', borderRadius: 999, padding: '14px 24px' }
  let content: React.ReactNode
  if (error === 'sign-in-required') {
    content = (
      <>
        <MdLockOutline size={48} color="rgba(0,0,0,.54)" />
        <h2 className="t-head-m bold">Sign in to view this trip</h2>
        <p className="muted">This trip requires a Trypr account to view.</p>
        <button className="btn" style={dark} onClick={() => navigate('/sign-in')}><MdLogin size={18} />Sign in</button>
        <Button variant="text" onClick={() => navigate('/create-account')}>Create an account</Button>
        <Button variant="text" onClick={back}>Go back</Button>
      </>
    )
  } else if (error === 'no-access') {
    content = (
      <>
        <MdLockOutline size={48} color="rgba(0,0,0,.54)" />
        <h2 className="t-head-m bold">Access required</h2>
        <p className="muted" style={{ textAlign: 'center' }}>You don't have access to this trip yet. Send a request to join!</p>
        <button className="btn" style={dark} onClick={sendJoinRequest}><MdPersonAdd size={18} />Request to join</button>
        <Button variant="text" onClick={back}>Go back</Button>
      </>
    )
  } else if (error === 'request-sent' || error === 'request-pending') {
    content = (
      <>
        <MdHourglassTop size={48} color="#ffc107" />
        <h2 className="t-head-m bold">{error === 'request-sent' ? 'Request sent!' : 'Request already pending'}</h2>
        <p className="muted" style={{ textAlign: 'center' }}>The trip owner needs to approve your request. Once approved, this trip will appear in your Shared Trips.</p>
        <Button variant="solid" onClick={() => navigate('/my-trips')}>Go to My Trips</Button>
        <Button variant="text" onClick={back}>Go back</Button>
      </>
    )
  } else {
    content = (
      <>
        <MdErrorOutline size={48} color="#ef4444" />
        <p style={{ fontSize: 16, textAlign: 'center' }}>{error ?? 'Something went wrong'}</p>
        <Button variant="solid" onClick={back}>Go back</Button>
      </>
    )
  }
  return <div className="center col gap-md" style={{ height: '100vh', padding: 32 }}>{content}</div>
}
