import { useEffect, useMemo, useState, type ReactNode } from 'react'
import {
  addDoc, collection, collectionGroup, deleteDoc, doc, getDoc, getDocs, limit, onSnapshot, orderBy, query, serverTimestamp, setDoc, updateDoc,
  type DocumentReference,
} from 'firebase/firestore'
import { format } from 'date-fns'
import { useNavigate, useParams } from 'react-router-dom'
import {
  MdAdd, MdAddLocation, MdAdminPanelSettings, MdAnalytics, MdArrowBack, MdArrowDownward, MdArrowUpward, MdArticle, MdBackup, MdBugReport,
  MdChevronRight, MdDashboard, MdDelete, MdEdit, MdEditNote, MdInfoOutline, MdLink, MdLinkOff, MdListAlt, MdLocationOn, MdMap, MdMoreVert,
  MdNoteAdd, MdPeople, MdPeopleAlt, MdPersonAdd, MdPushPin, MdOutlinePushPin, MdSearch, MdSecurity, MdSettings, MdStickyNote2, MdTrendingUp, MdVerified,
} from 'react-icons/md'
import { db } from '@/firebase'
import { useAuth } from '@/context/Auth'
import { useFeedback } from '@/context/Feedback'
import { useDocument } from '@/hooks/useFirestore'
import { Dialog } from '@/components/Dialog'
import { Button, CenteredSpinner, Menu, MenuDivider, MenuItem, SoftCard, Spinner, cx } from '@/components/ui'
import TripDetailScreen from './TripDetailScreen'

type Row = Record<string, any>

// ---- helpers -----------------------------------------------------------------------------------

const toDate = (raw: unknown): Date | null => {
  if (!raw) return null
  if (typeof raw === 'object' && raw && 'toDate' in (raw as any)) return (raw as any).toDate()
  if (raw instanceof Date) return raw
  if (typeof raw === 'string' && raw.trim()) {
    const d = new Date(raw.trim())
    return Number.isNaN(d.getTime()) ? null : d
  }
  return null
}
const fmt = (raw: unknown, pattern: string) => {
  const d = toDate(raw)
  return d ? format(d, pattern) : ''
}
const initialFor = (raw: unknown) => {
  const m = /[A-Za-z0-9]/.exec(String(raw ?? '').trim())
  return m ? m[0].toUpperCase() : '?'
}
const timeAgo = (date: Date) => {
  const diffMs = Date.now() - date.getTime()
  const days = Math.floor(diffMs / 86400000)
  const hours = Math.floor(diffMs / 3600000)
  const mins = Math.floor(diffMs / 60000)
  if (days > 365) return `${Math.floor(days / 365)}y ago`
  if (days > 30) return `${Math.floor(days / 30)}mo ago`
  if (days > 0) return `${days}d ago`
  if (hours > 0) return `${hours}h ago`
  if (mins > 0) return `${mins}m ago`
  return 'Just now'
}

interface AdminTrip { ownerUid: string; tripId: string; ref: DocumentReference; data: Row }

async function loadAdminTrips(): Promise<AdminTrip[]> {
  const snap = await getDocs(collectionGroup(db, 'trips'))
  const trips: AdminTrip[] = []
  for (const d of snap.docs) {
    const seg = d.ref.path.split('/')
    const ownerUid = seg.length >= 4 && seg[0] === 'users' ? seg[1] : ''
    if (ownerUid) trips.push({ ownerUid, tripId: d.id, ref: d.ref, data: d.data() })
  }
  const sortDate = (data: Row) => (toDate(data.updatedAt) ?? toDate(data.createdAt) ?? toDate(data.startDate) ?? new Date(0)).getTime()
  return trips.sort((a, b) => sortDate(b.data) - sortDate(a.data))
}

function useAsync<T>(fn: () => Promise<T>, deps: unknown[] = []) {
  const [state, setState] = useState<{ data: T | null; error: Error | null; loading: boolean }>({ data: null, error: null, loading: true })
  useEffect(() => {
    let cancelled = false
    setState({ data: null, error: null, loading: true })
    fn().then((data) => !cancelled && setState({ data, error: null, loading: false })).catch((error) => !cancelled && setState({ data: null, error, loading: false }))
    return () => { cancelled = true }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
  return state
}

const Loading = ({ message }: { message: string }) => (
  <div className="center col gap-sm" style={{ padding: 24 }}><Spinner /><span className="muted">{message}</span></div>
)
const ErrorState = ({ message, error }: { message: string; error?: unknown }) => (
  <div style={{ padding: 16 }}>
    <div style={{ color: '#B00020', fontWeight: 700 }}>{message}</div>
    {error != null && <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>{String((error as any)?.message ?? error)}</div>}
  </div>
)

const confirmDelete = (confirm: ReturnType<typeof useFeedback>['confirm'], title: string, message: string) => confirm({ title, message, confirmLabel: 'Delete', danger: true })

// ---- Dashboard -----------------------------------------------------------------------------------

function StatCard({ title, value, icon, color }: { title: string; value: string; icon: ReactNode; color: string }) {
  return (
    <div style={{ flex: '1 1 160px', minWidth: 160, padding: 20, borderRadius: 12, background: '#fff', border: `1px solid ${color}4d`, boxShadow: '0 2px 8px rgba(0,0,0,0.05)' }}>
      <div style={{ color }}>{icon}</div>
      <div style={{ fontSize: 28, fontWeight: 700, color, marginTop: 12 }}>{value}</div>
      <div style={{ fontSize: 14, color: '#757575', marginTop: 4 }}>{title}</div>
    </div>
  )
}
function ActionButton({ label, icon, color, onClick }: { label: string; icon: ReactNode; color: string; onClick: () => void }) {
  return (
    <button onClick={onClick} style={{ display: 'inline-flex', alignItems: 'center', gap: 8, padding: '16px 20px', borderRadius: 12, background: `${color}1a`, border: `1px solid ${color}4d`, color, fontWeight: 600, cursor: 'pointer' }}>
      {icon} {label}
    </button>
  )
}

function DashboardTab({ goTab }: { goTab: (i: number) => void }) {
  const navigate = useNavigate()
  const { user } = useAuth()
  const hour = new Date().getHours()
  const greeting = hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening'
  const stats = useAsync(async () => {
    const [users, verified, pages] = await Promise.all([getDocs(collection(db, 'users')), getDocs(collection(db, 'verifiedTrips')), getDocs(collection(db, 'unlistedPages'))])
    return [users.size, verified.size, pages.size]
  })
  const [recent, setRecent] = useState<{ docs: Row[]; error: Error | null; loading: boolean }>({ docs: [], error: null, loading: true })
  useEffect(
    () => onSnapshot(query(collection(db, 'users'), orderBy('createdAt', 'desc'), limit(5)), (s) => setRecent({ docs: s.docs.map((d) => d.data()), error: null, loading: false }), (error) => setRecent({ docs: [], error, loading: false })),
    [],
  )

  return (
    <div className="plan-scroll" style={{ padding: 16 }}>
      <div style={{ padding: 24, borderRadius: 16, color: '#fff', background: 'linear-gradient(135deg, #667eea, #764ba2)', boxShadow: '0 4px 10px rgba(0,0,0,0.1)' }}>
        <div style={{ fontSize: 24, fontWeight: 700 }}>{greeting}, {user?.displayName ?? 'Admin'}! 👋</div>
        <div style={{ fontSize: 16, opacity: 0.7, marginTop: 8 }}>Welcome to your command center</div>
        <div style={{ opacity: 0.6, marginTop: 16 }}>{format(new Date(), 'EEEE, MMMM d, y')}</div>
      </div>

      <h3 style={{ fontSize: 20, margin: '24px 0 16px' }}>Platform Overview</h3>
      {stats.error ? <ErrorState message="Could not load platform stats." error={stats.error} /> : stats.loading ? <Loading message="Loading platform stats..." /> : (
        <div className="row wrap" style={{ gap: 16, alignItems: 'stretch' }}>
          <StatCard title="Total Users" value={String(stats.data![0])} icon={<MdPeople size={32} />} color="#6c5ce7" />
          <StatCard title="Verified Trips" value={String(stats.data![1])} icon={<MdVerified size={32} />} color="#00B894" />
          <StatCard title="Unlisted Pages" value={String(stats.data![2])} icon={<MdLink size={32} />} color="#e17055" />
          <StatCard title="Active Today" value="0" icon={<MdTrendingUp size={32} />} color="#fdcb6e" />
        </div>
      )}

      <h3 style={{ fontSize: 20, margin: '24px 0 16px' }}>Recent Activity</h3>
      {recent.error ? <ErrorState message="Could not load recent activity." error={recent.error} /> : recent.loading ? <Loading message="Loading recent activity..." /> : recent.docs.length === 0 ? <div>No recent activity</div> : (
        <SoftCard padding={0}>
          {recent.docs.map((u, i) => {
            const name = u.displayName ?? 'Unknown User'
            const created = toDate(u.createdAt)
            return (
              <div key={i} className="row" style={{ gap: 12, padding: '12px 16px', borderTop: i ? '1px solid var(--border)' : undefined }}>
                <div style={{ width: 40, height: 40, borderRadius: '50%', background: '#00B894', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{initialFor(name)}</div>
                <div className="grow"><div>{name}</div><div className="muted" style={{ fontSize: 13 }}>Joined {created ? timeAgo(created) : 'Recently'}</div></div>
                <MdPersonAdd size={20} />
              </div>
            )
          })}
        </SoftCard>
      )}

      <h3 style={{ fontSize: 20, margin: '24px 0 16px' }}>Quick Actions</h3>
      <div className="row wrap" style={{ gap: 16 }}>
        <ActionButton label="Create Verified Trip" icon={<MdAddLocation size={20} />} color="#00B894" onClick={() => navigate('/verified-trips/new')} />
        <ActionButton label="New Unlisted Page" icon={<MdNoteAdd size={20} />} color="#6c5ce7" onClick={() => navigate('/admin/pages/new')} />
        <ActionButton label="View Analytics" icon={<MdAnalytics size={20} />} color="#e17055" onClick={() => goTab(5)} />
        <ActionButton label="Manage Users" icon={<MdPeopleAlt size={20} />} color="#fdcb6e" onClick={() => goTab(1)} />
      </div>
    </div>
  )
}

// ---- Users ----------------------------------------------------------------------------------------

function EditUserDialog({ current, onClose, onSave }: { current: Row; onClose: () => void; onSave: (v: Row) => void }) {
  const [name, setName] = useState(String(current.name ?? ''))
  const [bio, setBio] = useState(String(current.bio ?? ''))
  const [sex, setSex] = useState(String(current.sex ?? 'Not specified'))
  return (
    <Dialog title="Edit User Details" onClose={onClose} actions={<><Button variant="text" onClick={onClose}>Cancel</Button><Button variant="solid" style={{ background: '#6c5ce7' }} onClick={() => onSave({ name, bio, sex })}>Save Changes</Button></>}>
      <div className="col gap-md">
        <div className="field"><label>Name</label><input className="input" value={name} onChange={(e) => setName(e.target.value)} /></div>
        <div className="field"><label>Email (read-only)</label><input className="input" value={String(current.email ?? '')} disabled /></div>
        <div className="field"><label>Bio</label><textarea className="textarea" rows={3} value={bio} onChange={(e) => setBio(e.target.value)} /></div>
        <div className="field"><label>Sex</label><select className="select" value={sex} onChange={(e) => setSex(e.target.value)}>{['Not specified', 'Male', 'Female', 'Other'].map((s) => <option key={s}>{s}</option>)}</select></div>
      </div>
    </Dialog>
  )
}

function UserTripsDialog({ userId, userName, onClose }: { userId: string; userName: string; onClose: () => void }) {
  const navigate = useNavigate()
  const { toast } = useFeedback()
  const trips = useAsync(async () => (await getDocs(collection(db, 'users', userId, 'trips'))).docs.map((d) => ({ id: d.id, data: d.data() })), [userId])
  const dateLabel = (raw: unknown) => fmt(raw, 'MMM d, y') || String(raw ?? '').trim()
  const range = (d: Row) => {
    const s = dateLabel(d.startDate), e = dateLabel(d.endDate)
    return s && e ? `${s} - ${e}` : s || e || 'No dates set'
  }
  return (
    <Dialog title={`${userName}'s Trips`} onClose={onClose} actions={<Button variant="text" onClick={onClose}>Close</Button>}>
      <div style={{ minHeight: 120 }}>
        {trips.error ? <ErrorState message="Could not load trips." error={trips.error} /> : trips.loading ? <Loading message="Loading trips..." /> : trips.data!.length === 0 ? <div className="center">No trips yet</div> : (
          trips.data!.map((t) => (
            <div key={t.id} className="row" style={{ gap: 12, padding: '10px 0', cursor: 'pointer', borderBottom: '1px solid var(--border)' }}
              onClick={async () => {
                try {
                  const snap = await getDoc(doc(db, 'users', userId, 'trips', t.id))
                  if (!snap.exists()) return toast('Trip no longer exists')
                  onClose()
                  navigate(`/admin/trip/${userId}/${t.id}`)
                } catch (e: any) {
                  toast(`Could not open trip: ${e?.message ?? e}`)
                }
              }}
            >
              <MdMap size={22} />
              <div className="grow"><div>{String(t.data.name ?? t.data.tripName ?? 'Untitled Trip')}</div><div className="muted" style={{ fontSize: 13 }}>{range(t.data)}</div></div>
              <MdChevronRight size={22} />
            </div>
          ))
        )}
      </div>
    </Dialog>
  )
}

function UsersTab() {
  const { toast, confirm } = useFeedback()
  const [search, setSearch] = useState('')
  const [sortBy, setSortBy] = useState('createdAt')
  const [asc, setAsc] = useState(false)
  const [state, setState] = useState<{ docs: { id: string; data: Row }[]; error: Error | null; loading: boolean }>({ docs: [], error: null, loading: true })
  const [expanded, setExpanded] = useState<string | null>(null)
  const [tripsFor, setTripsFor] = useState<{ id: string; name: string } | null>(null)
  const [editing, setEditing] = useState<{ id: string; data: Row } | null>(null)

  useEffect(() => {
    setState((s) => ({ ...s, loading: true }))
    return onSnapshot(query(collection(db, 'users'), orderBy(sortBy, asc ? 'asc' : 'desc')), (s) => setState({ docs: s.docs.map((d) => ({ id: d.id, data: d.data() })), error: null, loading: false }), (error) => setState({ docs: [], error, loading: false }))
  }, [sortBy, asc])

  const docs = useMemo(() => {
    const q = search.toLowerCase()
    return q ? state.docs.filter((d) => String(d.data.displayName ?? '').toLowerCase().includes(q) || String(d.data.email ?? '').toLowerCase().includes(q)) : state.docs
  }, [state.docs, search])

  const makeAdmin = async (id: string, name: string) => {
    if (!(await confirm({ title: 'Grant Admin Access', message: `Make ${name} an admin?`, confirmLabel: 'Confirm' }))) return
    try { await setDoc(doc(db, 'admins', id), { createdAt: serverTimestamp() }); toast(`${name} is now an admin`) } catch (e: any) { toast(`Error: ${e?.message ?? e}`) }
  }
  const deleteUser = async (id: string, name: string) => {
    if (!(await confirmDelete(confirm, 'Delete User', `Are you sure you want to delete ${name}? This will delete all their trips and data. This action cannot be undone.`))) return
    try { await deleteDoc(doc(db, 'users', id)); toast(`Deleted ${name}`) } catch (e: any) { toast(`Error: ${e?.message ?? e}`) }
  }
  const saveUser = async (id: string, current: Row, result: Row) => {
    setEditing(null)
    const updates: Row = {}
    for (const k of ['name', 'bio', 'sex']) if (result[k] !== current[k]) updates[k] = result[k]
    if (!Object.keys(updates).length) return
    try { await updateDoc(doc(db, 'users', id), updates); toast('User details updated') } catch (e: any) { toast(`Error updating user: ${e?.message ?? e}`) }
  }

  return (
    <div className="col" style={{ height: '100%', minHeight: 0 }}>
      <div style={{ padding: 16, background: '#f5f5f5' }}>
        <div className="input-wrap"><span className="input-icon"><MdSearch size={20} /></span><input className="input" placeholder="Search users by name or email..." value={search} onChange={(e) => setSearch(e.target.value)} /></div>
        <div className="row" style={{ gap: 12, marginTop: 12 }}>
          <span>Sort by:</span>
          <select className="select" style={{ width: 'auto' }} value={sortBy} onChange={(e) => setSortBy(e.target.value)}>
            <option value="createdAt">Join Date</option><option value="displayName">Name</option><option value="email">Email</option>
          </select>
          <button className="icon-btn" title={asc ? 'Ascending' : 'Descending'} onClick={() => setAsc((a) => !a)}>{asc ? <MdArrowUpward size={20} /> : <MdArrowDownward size={20} />}</button>
        </div>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: 16 }}>
        {state.error ? <div className="center">Error: {state.error.message}</div> : state.loading ? <CenteredSpinner /> : docs.length === 0 ? <div className="center">No users found</div> : docs.map(({ id, data }) => {
          const name = data.displayName ?? 'Unknown'
          const open = expanded === id
          return (
            <SoftCard key={id} padding={0} style={{ marginBottom: 12 }}>
              <div className="row" style={{ gap: 12, padding: 16, cursor: 'pointer', alignItems: 'flex-start' }} onClick={() => setExpanded(open ? null : id)}>
                <div style={{ width: 40, height: 40, borderRadius: '50%', background: '#00B894', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', flex: 'none' }}>{initialFor(name)}</div>
                <div className="grow">
                  <div style={{ fontWeight: 600 }}>{name}</div>
                  {data.email && <div>{data.email}</div>}
                  {data.city && <div className="muted">📍 {data.city}</div>}
                  <div className="muted">Joined {fmt(data.createdAt, 'MMM d, y') || 'recently'}</div>
                </div>
                <MdChevronRight size={22} style={{ transform: open ? 'rotate(90deg)' : undefined, transition: 'transform 0.15s' }} />
              </div>
              {open && (
                <div style={{ padding: '0 16px 16px' }}>
                  {[['User ID:', id], ['Countries Visited:', String(Array.isArray(data.visitedCountries) ? data.visitedCountries.length : 0)], ['Sex:', String(data.sex ?? 'Not specified')]].map(([l, v]) => (
                    <div key={l} className="row" style={{ alignItems: 'flex-start', marginBottom: 8 }}><div style={{ width: 140, fontWeight: 600 }}>{l}</div><div className="grow" style={{ wordBreak: 'break-all' }}>{v}</div></div>
                  ))}
                  <div className="row wrap gap-sm" style={{ marginTop: 12 }}>
                    <Button variant="solid" size="sm" icon={<MdMap size={16} />} onClick={() => setTripsFor({ id, name })}>View Trips</Button>
                    <Button variant="solid" size="sm" style={{ background: '#6c5ce7' }} icon={<MdEdit size={16} />} onClick={() => setEditing({ id, data })}>Edit User</Button>
                    <Button variant="solid" size="sm" style={{ background: '#e17055' }} icon={<MdAdminPanelSettings size={16} />} onClick={() => void makeAdmin(id, name)}>Make Admin</Button>
                    <Button variant="outlined" size="sm" style={{ color: '#ef4444', borderColor: '#ef4444' }} icon={<MdDelete size={16} />} onClick={() => void deleteUser(id, name)}>Delete</Button>
                  </div>
                </div>
              )}
            </SoftCard>
          )
        })}
      </div>
      {tripsFor && <UserTripsDialog userId={tripsFor.id} userName={tripsFor.name} onClose={() => setTripsFor(null)} />}
      {editing && <EditUserDialog current={editing.data} onClose={() => setEditing(null)} onSave={(r) => void saveUser(editing.id, editing.data, r)} />}
    </div>
  )
}

// ---- Trips ----------------------------------------------------------------------------------------

function TripsTab() {
  const navigate = useNavigate()
  const { toast, confirm } = useFeedback()
  const [version, setVersion] = useState(0)
  const trips = useAsync(loadAdminTrips, [version])

  const open = async (t: AdminTrip) => {
    try {
      const snap = await getDoc(t.ref)
      if (!snap.exists()) return toast('Trip no longer exists')
      navigate(`/admin/trip/${t.ownerUid}/${t.tripId}`)
    } catch (e: any) {
      toast(`Could not open trip: ${e?.message ?? e}`)
    }
  }
  const remove = async (t: AdminTrip) => {
    const name = String(t.data.name ?? 'Untitled Trip')
    if (!(await confirmDelete(confirm, 'Delete Trip', `Delete "${name}"?`))) return
    try { await deleteDoc(t.ref); toast('Trip deleted'); setVersion((v) => v + 1) } catch (e: any) { toast(`Error: ${e?.message ?? e}`) }
  }

  if (trips.error) return <ErrorState message="Could not load trips." error={trips.error} />
  if (trips.loading) return <Loading message="Loading trips..." />
  if (!trips.data!.length) return <div className="center" style={{ padding: 24 }}>No trips found</div>
  return (
    <div className="plan-scroll" style={{ padding: 16 }}>
      {trips.data!.map((t) => (
        <SoftCard key={t.ref.path} padding={12} style={{ marginBottom: 12 }}>
          <div className="row" style={{ gap: 12 }}>
            <div style={{ width: 40, height: 40, borderRadius: '50%', background: '#00B894', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><MdMap size={20} /></div>
            <div className="grow"><div style={{ fontWeight: 500 }}>{String(t.data.name ?? 'Untitled Trip')}</div><div className="muted" style={{ fontSize: 13 }}>{Array.isArray(t.data.waypoints) ? t.data.waypoints.length : 0} destinations • Starts: {String(t.data.startDate ?? '')}</div></div>
            <Menu trigger={<button className="icon-btn"><MdMoreVert size={20} /></button>}>
              {(close) => <><MenuItem onClick={() => { close(); void open(t) }}>View Details</MenuItem><MenuItem color="#ef4444" onClick={() => { close(); void remove(t) }}>Delete</MenuItem></>}
            </Menu>
          </div>
        </SoftCard>
      ))}
    </div>
  )
}

/** `/admin/trip/:ownerUid/:tripId` — read-only view of any user's trip. */
export function AdminTripView() {
  const { ownerUid = '', tripId = '' } = useParams()
  const { isAdmin, loading } = useAuth()
  const [data, setData] = useState<Row | null>(null)
  const [error, setError] = useState('')
  useEffect(() => {
    if (loading || !isAdmin) return
    getDoc(doc(db, 'users', ownerUid, 'trips', tripId))
      .then((s) => {
        if (!s.exists()) return setError('Trip no longer exists')
        const d: Row = { ...s.data(), tripRef: `users/${ownerUid}/trips/${tripId}` }
        delete d.sharedFrom
        setData(d)
      })
      .catch((e) => setError(e?.message ?? 'Could not open trip'))
  }, [ownerUid, tripId, isAdmin, loading])
  if (data) return <TripDetailScreen docId={tripId} data={data} readOnly />
  return <div className="center" style={{ height: '100vh' }}>{error || (loading ? <Spinner /> : isAdmin ? <Spinner /> : 'Admin access is required to view this screen.')}</div>
}

// ---- Verified -------------------------------------------------------------------------------------

function VerifiedTab() {
  const navigate = useNavigate()
  const { toast, confirm } = useFeedback()
  const [state, setState] = useState<{ docs: { id: string; data: Row }[]; loading: boolean }>({ docs: [], loading: true })
  useEffect(() => onSnapshot(query(collection(db, 'verifiedTrips'), orderBy('createdAt', 'desc')), (s) => setState({ docs: s.docs.map((d) => ({ id: d.id, data: d.data() })), loading: false }), () => setState({ docs: [], loading: false })), [])
  const remove = async (id: string, title: string) => {
    if (!(await confirmDelete(confirm, 'Delete Verified Trip', `Delete "${title}"? This will remove it for all users.`))) return
    try { await deleteDoc(doc(db, 'verifiedTrips', id)); toast('Verified trip deleted') } catch (e: any) { toast(`Error: ${e?.message ?? e}`) }
  }
  return (
    <div className="col" style={{ height: '100%', minHeight: 0 }}>
      <div className="row" style={{ gap: 12, padding: 16, background: '#e8f5e9' }}>
        <MdVerified size={24} color="#00B894" /><span className="grow" style={{ fontWeight: 500 }}>Manage curated trips shown to all users</span>
        <Button variant="solid" style={{ background: '#00B894' }} icon={<MdAdd size={18} />} onClick={() => navigate('/verified-trips/new')}>New Trip</Button>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: 16 }}>
        {state.loading ? <CenteredSpinner /> : state.docs.length === 0 ? <div className="center">No verified trips yet</div> : state.docs.map(({ id, data }) => {
          const title = String(data.title ?? 'Untitled')
          return (
            <SoftCard key={id} padding={12} style={{ marginBottom: 12 }}>
              <div className="row" style={{ gap: 12 }}>
                <div style={{ width: 40, height: 40, borderRadius: '50%', background: '#c8e6c9', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 22 }}>{String(data.emoji ?? '🗺️')}</div>
                <div className="grow"><div style={{ fontWeight: 600 }}>{title}</div>{data.subtitle && <div>{String(data.subtitle)}</div>}<div className="muted">{Array.isArray(data.waypoints) ? data.waypoints.length : 0} destinations</div></div>
                <Menu trigger={<button className="icon-btn"><MdMoreVert size={20} /></button>}>
                  {(close) => <><MenuItem onClick={() => { close(); navigate(`/verified-trips/${id}/edit`, { state: { data } }) }}>Edit</MenuItem><MenuItem onClick={() => { close(); toast('Duplicate is not available yet') }}>Duplicate</MenuItem><MenuItem color="#ef4444" onClick={() => { close(); void remove(id, title) }}>Delete</MenuItem></>}
                </Menu>
              </div>
            </SoftCard>
          )
        })}
      </div>
    </div>
  )
}

// ---- Unlisted pages -------------------------------------------------------------------------------

const StatusChip = ({ label, color, icon }: { label: string; color: string; icon: ReactNode }) => (
  <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, padding: '4px 8px', borderRadius: 12, background: `${color}1a`, color, fontSize: 12, fontWeight: 500 }}>{icon}{label}</span>
)

function PagesTab() {
  const navigate = useNavigate()
  const { toast, confirm } = useFeedback()
  const [state, setState] = useState<{ docs: { id: string; data: Row }[]; error: Error | null; loading: boolean }>({ docs: [], error: null, loading: true })
  useEffect(() => onSnapshot(query(collection(db, 'unlistedPages'), orderBy('createdAt', 'desc')), (s) => setState({ docs: s.docs.map((d) => ({ id: d.id, data: d.data() })), error: null, loading: false }), (error) => setState({ docs: [], error, loading: false })), [])
  const remove = async (id: string, title: string) => {
    if (!(await confirmDelete(confirm, 'Delete Page?', `Are you sure you want to delete "${title}"? This will also delete all responses.`))) return
    try { await deleteDoc(doc(db, 'unlistedPages', id)); toast('Page deleted') } catch (e: any) { toast(`Error deleting: ${e?.message ?? e}`) }
  }
  if (state.error) return <div className="center">Error: {state.error.message}</div>
  if (state.loading) return <CenteredSpinner />
  if (!state.docs.length) {
    return <div className="center col gap-sm" style={{ padding: 40 }}><MdLinkOff size={64} className="faint" /><div className="t-title-m">No unlisted pages yet</div><div className="muted">Create your first unlisted page</div></div>
  }
  return (
    <div className="plan-scroll" style={{ padding: 16 }}>
      {state.docs.map(({ id, data }) => {
        const title = String(data.title ?? 'Untitled')
        const description = String(data.description ?? '')
        return (
          <SoftCard key={id} padding={16} style={{ marginBottom: 12 }}>
            <div className="row" style={{ gap: 16, alignItems: 'flex-start' }}>
              <div style={{ width: 48, height: 48, borderRadius: 8, background: '#00B8941a', color: '#00B894', display: 'flex', alignItems: 'center', justifyContent: 'center', flex: 'none' }}><MdArticle size={24} /></div>
              <div className="grow" style={{ minWidth: 0 }}>
                <div style={{ fontWeight: 600 }}>{title}</div>
                {description && <div className="muted ellipsis" style={{ marginTop: 4 }}>{description}</div>}
                <div className="row" style={{ gap: 8, marginTop: 8 }}>
                  <StatusChip label={`/page/${id}`} color="#2196f3" icon={<MdLink size={14} />} />
                  {data.formEnabled === true && <StatusChip label="Form" color="#4caf50" icon={<MdEditNote size={14} />} />}
                </div>
              </div>
              <Menu trigger={<button className="icon-btn"><MdMoreVert size={20} /></button>}>
                {(close) => (
                  <>
                    <MenuItem onClick={() => { close(); navigate(`/admin/pages/${id}/edit`, { state: { data } }) }}><MdEdit size={18} /> Edit</MenuItem>
                    <MenuItem onClick={() => { close(); navigator.clipboard?.writeText(`${window.location.origin}/page/${id}`); toast('Link copied') }}><MdLink size={18} /> Copy Link</MenuItem>
                    <MenuItem onClick={() => { close(); navigate(`/admin/pages/${id}/responses`, { state: { title } }) }}><MdListAlt size={18} /> View Responses</MenuItem>
                    <MenuDivider />
                    <MenuItem color="#ef4444" onClick={() => { close(); void remove(id, title) }}><MdDelete size={18} /> Delete</MenuItem>
                  </>
                )}
              </Menu>
            </div>
          </SoftCard>
        )
      })}
    </div>
  )
}

// ---- Analytics ------------------------------------------------------------------------------------

function Card({ title, children }: { title: string; children: ReactNode }) {
  return <SoftCard padding={16} style={{ marginBottom: 24 }}><h3 style={{ margin: '0 0 16px', fontSize: 18 }}>{title}</h3>{children}</SoftCard>
}

function SettingsItem({ icon, title, subtitle, onClick, trailing }: { icon: ReactNode; title: string; subtitle: string; onClick?: () => void; trailing?: ReactNode }) {
  return (
    <div className="row" style={{ gap: 16, padding: 16, cursor: onClick ? 'pointer' : undefined, borderTop: '1px solid var(--border)' }} onClick={onClick}>
      {icon}<div className="grow"><div>{title}</div><div className="muted" style={{ fontSize: 13 }}>{subtitle}</div></div>{trailing ?? (onClick && <MdChevronRight size={22} />)}
    </div>
  )
}


function AnalyticsTab() {
  const growth = useAsync(async () => {
    const users = (await getDocs(collection(db, 'users'))).docs
    const monthly = new Map<string, number>()
    for (const u of users) {
      const c = toDate(u.data().createdAt)
      if (c) monthly.set(format(c, 'yyyy-MM'), (monthly.get(format(c, 'yyyy-MM')) ?? 0) + 1)
    }
    return { total: users.length, months: [...monthly.entries()].sort((a, b) => a[0].localeCompare(b[0])) }
  })
  const trips = useAsync(loadAdminTrips)
  const metrics = useAsync(async () => {
    const [t, v, p, u] = await Promise.all([loadAdminTrips(), getDocs(collection(db, 'verifiedTrips')), getDocs(collection(db, 'unlistedPages')), getDocs(collection(db, 'users'))])
    return { totalTrips: t.length, verified: v.size, pages: p.size, users: u.size }
  })

  const top10 = useMemo(() => {
    const counts = new Map<string, number>()
    for (const t of trips.data ?? []) for (const wp of Array.isArray(t.data.waypoints) ? t.data.waypoints : []) {
      const name = String(wp?.name ?? '').trim()
      if (name) counts.set(name, (counts.get(name) ?? 0) + 1)
    }
    return [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10)
  }, [trips.data])

  return (
    <div className="plan-scroll" style={{ padding: 16 }}>
      <h2 style={{ fontSize: 24, margin: '0 0 24px' }}>Platform Analytics</h2>
      <Card title="User Growth">
        {growth.error ? <ErrorState message="Could not load user growth data." error={growth.error} /> : growth.loading ? <Loading message="Loading user growth..." /> : (
          <>
            <div style={{ fontSize: 16, marginBottom: 12 }}>Total Users: {growth.data!.total}</div>
            {growth.data!.months.map(([k, v]) => (
              <div key={k} className="row" style={{ gap: 8, padding: '4px 0' }}>
                <span style={{ width: 80 }}>{k}</span>
                <div className="grow" style={{ height: 4, borderRadius: 4, background: '#eee', overflow: 'hidden' }}><div style={{ width: `${growth.data!.total ? (v / growth.data!.total) * 100 : 0}%`, height: '100%', background: '#00B894' }} /></div>
                <span>{v}</span>
              </div>
            ))}
          </>
        )}
      </Card>
      <Card title="Popular Destinations">
        {trips.error ? <ErrorState message="Could not load destination analytics." error={trips.error} /> : trips.loading ? <Loading message="Loading popular destinations..." /> : top10.length === 0 ? <div>No destination data yet</div> : top10.map(([name, n]) => (
          <div key={name} className="row" style={{ gap: 12, padding: '8px 0' }}><MdLocationOn size={22} color="#00B894" /><span className="grow">{name}</span><b>{n} trips</b></div>
        ))}
      </Card>
      <Card title="Engagement Metrics">
        {metrics.error ? <ErrorState message="Could not load engagement metrics." error={metrics.error} /> : metrics.loading ? <Loading message="Loading engagement metrics..." /> : (
          [['Total Trips Created', metrics.data!.totalTrips], ['Verified Trips', metrics.data!.verified], ['Unlisted Pages', metrics.data!.pages], ['Total Users', metrics.data!.users]].map(([l, v]) => (
            <div key={String(l)} className="row between" style={{ padding: '8px 0' }}><span style={{ fontSize: 16 }}>{l}</span><b style={{ fontSize: 20, color: '#00B894' }}>{v}</b></div>
          ))
        )}
      </Card>
    </div>
  )
}

// ---- Personal notes -------------------------------------------------------------------------------

function NotesTab() {
  const { user } = useAuth()
  const { toast, confirm } = useFeedback()
  const [state, setState] = useState<{ docs: { id: string; data: Row }[]; loading: boolean }>({ docs: [], loading: true })
  const [openId, setOpenId] = useState<string | null>(null)
  const [editor, setEditor] = useState<{ id: string | null; title: string; content: string } | null>(null)
  const notesCol = user ? collection(db, 'admins', user.uid, 'notes') : null

  useEffect(() => {
    if (!notesCol) return
    return onSnapshot(query(notesCol, orderBy('createdAt', 'desc')), (s) => setState({ docs: s.docs.map((d) => ({ id: d.id, data: d.data() })), loading: false }), () => setState({ docs: [], loading: false }))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user?.uid])

  if (!user || !notesCol) return <div className="center">Not logged in</div>

  const save = async () => {
    if (!editor || !editor.title.trim()) return
    const data: Row = { title: editor.title.trim(), content: editor.content.trim(), updatedAt: serverTimestamp() }
    try {
      if (editor.id == null) await addDoc(notesCol, { ...data, createdAt: serverTimestamp() })
      else await updateDoc(doc(notesCol, editor.id), data)
      toast('Note saved')
      setEditor(null)
    } catch (e: any) { toast(`Error: ${e?.message ?? e}`) }
  }
  const togglePin = async (id: string, pinned: boolean) => { try { await updateDoc(doc(notesCol, id), { pinned }) } catch (e: any) { toast(`Error: ${e?.message ?? e}`) } }
  const remove = async (id: string, title: string) => {
    if (!(await confirmDelete(confirm, 'Delete Note', `Delete "${title}"?`))) return
    try { await deleteDoc(doc(notesCol, id)); toast('Note deleted') } catch (e: any) { toast(`Error: ${e?.message ?? e}`) }
  }

  return (
    <div className="col" style={{ height: '100%', minHeight: 0 }}>
      <div className="row" style={{ gap: 12, padding: 16, background: '#f3e5f5' }}>
        <MdStickyNote2 size={24} color="#9c27b0" /><span className="grow" style={{ fontWeight: 500 }}>Your personal notes &amp; tasks - accessible only to you</span>
        <Button variant="solid" style={{ background: '#9c27b0' }} icon={<MdAdd size={18} />} onClick={() => setEditor({ id: null, title: '', content: '' })}>New Note</Button>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: 16 }}>
        {state.loading ? <CenteredSpinner /> : state.docs.length === 0 ? <div className="center col gap-sm"><MdStickyNote2 size={64} className="faint" /><div>No notes yet. Create your first note!</div></div> : state.docs.map(({ id, data }) => {
          const pinned = data.pinned === true
          const title = String(data.title ?? 'Untitled')
          return (
            <SoftCard key={id} padding={0} color={pinned ? '#fffde7' : undefined} style={{ marginBottom: 12 }}>
              <div className="row" style={{ gap: 8, padding: 12, cursor: 'pointer' }} onClick={() => setOpenId(openId === id ? null : id)}>
                <button className="icon-btn" onClick={(e) => { e.stopPropagation(); void togglePin(id, !pinned) }}>{pinned ? <MdPushPin size={20} color="#ff9800" /> : <MdOutlinePushPin size={20} />}</button>
                <div className="grow"><div style={{ fontWeight: 600 }}>{title}</div><div className="muted" style={{ fontSize: 13 }}>{fmt(data.createdAt, 'MMM d, y h:mm a')}</div></div>
              </div>
              {openId === id && (
                <div style={{ padding: 16 }}>
                  <div style={{ whiteSpace: 'pre-wrap' }}>{String(data.content ?? '')}</div>
                  <div className="row" style={{ justifyContent: 'flex-end', gap: 4, marginTop: 12 }}>
                    <Button variant="text" size="sm" icon={<MdEdit size={16} />} onClick={() => setEditor({ id, title: String(data.title ?? ''), content: String(data.content ?? '') })}>Edit</Button>
                    <Button variant="text" size="sm" style={{ color: '#ef4444' }} icon={<MdDelete size={16} />} onClick={() => void remove(id, title)}>Delete</Button>
                  </div>
                </div>
              )}
            </SoftCard>
          )
        })}
      </div>
      {editor && (
        <Dialog title={editor.id ? 'Edit Note' : 'New Note'} onClose={() => setEditor(null)} actions={<><Button variant="text" onClick={() => setEditor(null)}>Cancel</Button><Button variant="solid" onClick={() => void save()}>Save</Button></>}>
          <div className="col gap-md">
            <div className="field"><label>Title</label><input className="input" value={editor.title} onChange={(e) => setEditor({ ...editor, title: e.target.value })} autoFocus /></div>
            <div className="field"><label>Content</label><textarea className="textarea" rows={8} value={editor.content} onChange={(e) => setEditor({ ...editor, content: e.target.value })} /></div>
          </div>
        </Dialog>
      )}
    </div>
  )
}

// ---- Settings -------------------------------------------------------------------------------------

function SettingsTab() {
  const { user } = useAuth()
  const { toast } = useFeedback()
  const adminRef = user ? doc(db, 'admins', user.uid) : null
  const adminDoc = useDocument(adminRef, [user?.uid])
  const [updating, setUpdating] = useState(false)
  const [about, setAbout] = useState(false)
  const debugEnabled = adminDoc.data?.data()?.debugMode === true

  const toggleDebug = async (enabled: boolean) => {
    if (!adminRef) return toast('Admin session unavailable')
    setUpdating(true)
    try {
      await setDoc(adminRef, { debugMode: enabled, updatedAt: serverTimestamp() }, { merge: true })
      toast(enabled ? 'Debug mode enabled' : 'Debug mode disabled')
    } catch (e: any) { toast(`Error: ${e?.message ?? e}`) } finally { setUpdating(false) }
  }
  return (
    <div className="plan-scroll" style={{ padding: 16 }}>
      <h2 style={{ fontSize: 24, margin: '0 0 24px' }}>Admin Settings</h2>
      <SoftCard padding={0}>
        <SettingsItem icon={<MdBackup size={24} />} title="Backup Database" subtitle="Export all data" onClick={() => toast('Backup feature coming soon')} />
        <SettingsItem icon={<MdSecurity size={24} />} title="Security Rules" subtitle="View Firestore rules" onClick={() => undefined} />
        <SettingsItem icon={<MdBugReport size={24} />} title="Debug Mode" subtitle="Enable detailed logging for this admin account"
          trailing={updating ? <Spinner size="sm" /> : <input type="checkbox" checked={debugEnabled} disabled={!adminRef} onChange={(e) => void toggleDebug(e.target.checked)} style={{ width: 20, height: 20 }} />} />
        <SettingsItem icon={<MdInfoOutline size={24} />} title="About" subtitle="Version 1.0.0" onClick={() => setAbout(true)} />
      </SoftCard>
      <Dialog open={about} onClose={() => setAbout(false)} title="Trypr Admin" actions={<Button variant="text" onClick={() => setAbout(false)}>Close</Button>}>
        <div className="row" style={{ gap: 16 }}><MdAdminPanelSettings size={48} color="#00B894" /><div>Version 1.0.0</div></div>
      </Dialog>
    </div>
  )
}

// ---- Shell ------------------------------------------------------------------------------------------

const TABS: { label: string; icon: ReactNode }[] = [
  { label: 'Dashboard', icon: <MdDashboard size={20} /> }, { label: 'Users', icon: <MdPeople size={20} /> }, { label: 'Trips', icon: <MdMap size={20} /> },
  { label: 'Verified', icon: <MdVerified size={20} /> }, { label: 'Pages', icon: <MdLink size={20} /> }, { label: 'Analytics', icon: <MdAnalytics size={20} /> },
  { label: 'My Notes', icon: <MdNoteAdd size={20} /> }, { label: 'Settings', icon: <MdSettings size={20} /> },
]

function AccessState({ message, error }: { message: string; error?: unknown }) {
  const navigate = useNavigate()
  return (
    <div style={{ minHeight: '100vh', background: 'var(--bg)' }}>
      <div className="plan-topbar"><button className="icon-btn" onClick={() => navigate(-1)}><MdArrowBack size={22} /></button><b style={{ fontSize: 18 }}>Admin Control Center</b></div>
      <div className="center" style={{ padding: 24 }}>
        <SoftCard padding={24} style={{ maxWidth: 440, textAlign: 'center' }} className="col gap-md">
          <MdAdminPanelSettings size={42} color="#1a1a2e" style={{ alignSelf: 'center' }} />
          <div style={{ fontSize: 16, fontWeight: 600 }}>{message}</div>
          {error != null && <div className="muted" style={{ fontSize: 12 }}>{String((error as any)?.message ?? error)}</div>}
          <Button variant="solid" onClick={() => navigate(-1)}>Back</Button>
        </SoftCard>
      </div>
    </div>
  )
}

export default function AdminPanelScreen() {
  const navigate = useNavigate()
  const { user, loading } = useAuth()
  const adminDoc = useDocument(user ? doc(db, 'admins', user.uid) : null, [user?.uid])
  const [tab, setTab] = useState(0)

  if (loading || (user && adminDoc.loading)) return <div className="center" style={{ height: '100vh' }}><Loading message="Checking admin access..." /></div>
  if (!user) return <AccessState message="Sign in with an admin account to open the admin panel." />
  if (adminDoc.error) return <AccessState message="Could not verify admin access." error={adminDoc.error} />
  if (!adminDoc.data?.exists()) return <AccessState message="Admin access is required to view this screen." />

  const body = [
    <DashboardTab key="d" goTab={setTab} />, <UsersTab key="u" />, <TripsTab key="t" />, <VerifiedTab key="v" />, <PagesTab key="p" />,
    <AnalyticsTab key="a" />, <NotesTab key="n" />, <SettingsTab key="s" />,
  ][tab]

  return (
    <div style={{ position: 'fixed', inset: 0, display: 'flex', flexDirection: 'column', background: 'var(--bg)' }}>
      <div style={{ background: '#1a1a2e', color: '#fff' }}>
        <div className="row" style={{ gap: 12, padding: '10px 12px' }}>
          <button className="icon-btn" style={{ color: '#fff' }} title="Back" onClick={() => navigate('/')}><MdArrowBack size={22} /></button>
          <MdAdminPanelSettings size={24} color="#FFD700" />
          <span style={{ fontSize: 20, fontWeight: 500 }}>Admin Control Center</span>
        </div>
        <div className="row" style={{ overflowX: 'auto' }}>
          {TABS.map((t, i) => (
            <button key={t.label} onClick={() => setTab(i)} className={cx('admin-tab', tab === i && 'selected')}>{t.icon}<span>{t.label}</span></button>
          ))}
        </div>
      </div>
      <div style={{ flex: 1, minHeight: 0 }}>{body}</div>
    </div>
  )
}
