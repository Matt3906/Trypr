import { useEffect, useMemo, useState } from 'react'
import { arrayRemove, doc, setDoc, updateDoc, deleteField } from 'firebase/firestore'
import { signOut } from 'firebase/auth'
import { useNavigate } from 'react-router-dom'
import {
  MdBadge, MdBugReport, MdCake, MdEdit, MdFlag, MdLocationOn, MdLogin, MdLogout, MdOutlinePeopleAlt, MdPeopleOutline, MdPublic, MdOutlineRoute,
  MdSaveAlt, MdTravelExplore, MdUploadFile, MdWorkspacePremium, MdOutlineWorkspacePremium, MdPerson,
} from 'react-icons/md'
import { auth, db } from '@/firebase'
import { useAuth } from '@/context/Auth'
import { useFeedback } from '@/context/Feedback'
import { useDocument } from '@/hooks/useFirestore'
import PageShell from '@/components/PageShell'
import VisitedMap from '@/components/VisitedMap'
import { Dialog } from '@/components/Dialog'
import { Button, CenteredSpinner, SoftCard } from '@/components/ui'
import { pickImageDataUrl } from '@/lib/image'

type Row = Record<string, any>
const TOTAL_SUPPORTED = 195
const PALETTE = ['#4aade8', '#00897b', '#ff7f6b', '#4ecdc4', '#ffb17a', '#a78bfa', '#fb7185']

const initialsFor = (v: string) => {
  const parts = v.trim().split(/\s+/).filter(Boolean)
  if (!parts.length) return '?'
  if (parts.length === 1) return parts[0][0].toUpperCase()
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase()
}
const chipAccent = (seed: string) => PALETTE[[...seed].reduce((t, c) => t + c.charCodeAt(0), 0) % PALETTE.length]

const useCompact = (max = 760) => {
  const [c, setC] = useState(() => window.innerWidth < max)
  useEffect(() => {
    const on = () => setC(window.innerWidth < max)
    window.addEventListener('resize', on)
    return () => window.removeEventListener('resize', on)
  }, [max])
  return c
}

const dobToString = (d: unknown): string => {
  if (d == null) return ''
  try {
    const dt = typeof d === 'object' && d && 'toDate' in (d as any) ? (d as any).toDate() : new Date(String(d))
    if (Number.isNaN(dt.getTime())) return ''
    return `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, '0')}-${String(dt.getDate()).padStart(2, '0')}`
  } catch {
    return ''
  }
}

function Pill({ icon, text }: { icon: React.ReactNode; text: string }) {
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '6px 10px', borderRadius: 999, background: 'rgba(255,255,255,0.2)', border: '1px solid rgba(255,255,255,0.28)', color: '#fff', fontSize: 12, fontWeight: 600 }}>
      {icon} {text}
    </span>
  )
}

function Metric({ icon, label, value, accent }: { icon: React.ReactNode; label: string; value: string; accent: string }) {
  return (
    <div className="vt-stat" style={{ borderColor: `${accent}4d` }}>
      <div className="vt-stat-icon" style={{ background: `${accent}24`, color: accent }}>{icon}</div>
      <div><div style={{ fontSize: 16, fontWeight: 700 }}>{value}</div><div className="muted" style={{ fontSize: 12, fontWeight: 500 }}>{label}</div></div>
    </div>
  )
}

function Section({ icon, accent, title, subtitle, trailing, children }: { icon: React.ReactNode; accent: string; title: string; subtitle?: string; trailing?: React.ReactNode; children: React.ReactNode }) {
  return (
    <div style={{ background: '#fff', borderRadius: 20, border: '1px solid #E8EEF5', padding: 16, marginTop: 12 }}>
      <div className="row" style={{ gap: 12, alignItems: 'center' }}>
        <div style={{ width: 36, height: 36, borderRadius: 10, background: `${accent}24`, color: accent, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{icon}</div>
        <div className="grow"><div style={{ fontWeight: 700, fontSize: 16 }}>{title}</div>{subtitle && <div className="muted" style={{ fontSize: 12 }}>{subtitle}</div>}</div>
        {trailing}
      </div>
      <div style={{ marginTop: 12 }}>{children}</div>
    </div>
  )
}

function EditProfileDialog({ uid, data, onClose }: { uid: string; data: Row; onClose: () => void }) {
  const { toast } = useFeedback()
  const [name, setName] = useState(String(data.name ?? data.displayName ?? ''))
  const [city, setCity] = useState(String(data.city ?? ''))
  const [dob, setDob] = useState(dobToString(data.dob))
  const [sex, setSex] = useState(String(data.sex ?? data.gender ?? '').toLowerCase() === 'female' ? 'female' : 'male')
  const [image, setImage] = useState<string | null>((data.profileImageDataUrl as string) ?? null)
  const [removeImage, setRemoveImage] = useState(false)
  const [saving, setSaving] = useState(false)

  const save = async () => {
    setSaving(true)
    const upd: Row = {
      name: name.trim(), displayName: name.trim(), displayNameLower: name.trim().toLowerCase(), city: city.trim(), sex,
      dob: dob ? new Date(`${dob}T00:00:00`).toISOString() : null,
      visitedCountries: Array.isArray(data.visitedCountries) ? data.visitedCountries : [],
    }
    if (image) upd.profileImageDataUrl = image
    for (const k of Object.keys(upd)) if (upd[k] == null || upd[k] === '') delete upd[k]
    if (removeImage) upd.profileImageDataUrl = deleteField()
    try {
      await setDoc(doc(db, 'users', uid), upd, { merge: true })
      toast('Profile updated')
      onClose()
    } catch (e: any) {
      toast(`Failed to save profile: ${e?.message ?? e}`)
      setSaving(false)
    }
  }

  return (
    <Dialog
      title="Edit profile" onClose={onClose}
      actions={<><Button variant="text" onClick={onClose}>Cancel</Button><Button variant="solid" loading={saving} onClick={save}>Save</Button></>}
    >
      <div className="col gap-md">
        <div className="field"><label>Name</label><input className="input" value={name} onChange={(e) => setName(e.target.value)} /></div>
        <div className="field"><label>City</label><input className="input" value={city} onChange={(e) => setCity(e.target.value)} /></div>
        <div className="row wrap gap-md" style={{ alignItems: 'center' }}>
          <div style={{ width: 72, height: 72, borderRadius: '50%', overflow: 'hidden', background: 'var(--surface-variant)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            {image ? <img src={image} alt="" style={{ width: '100%', height: '100%', objectFit: 'cover' }} /> : <MdPerson size={36} className="faint" />}
          </div>
          <Button variant="solid" size="sm" icon={<MdUploadFile size={18} />} onClick={async () => { const p = await pickImageDataUrl(); if (p) { setImage(p); setRemoveImage(false) } }}>Upload profile picture</Button>
          {image && <Button variant="text" size="sm" onClick={() => { setImage(null); setRemoveImage(true) }}>Remove</Button>}
        </div>
        <div className="row wrap gap-md">
          <div className="field grow"><label>Sex</label><select className="select" value={sex} onChange={(e) => setSex(e.target.value)}><option value="male">Male</option><option value="female">Female</option></select></div>
          <div className="field grow"><label>Date of birth</label><input className="input" type="date" value={dob} min="1900-01-01" max={new Date().toISOString().slice(0, 10)} onChange={(e) => setDob(e.target.value)} /></div>
        </div>
      </div>
    </Dialog>
  )
}

export default function AccountScreen() {
  const navigate = useNavigate()
  const { user, loading: authLoading } = useAuth()
  const { toast } = useFeedback()
  const compact = useCompact()
  const userDoc = useDocument(user ? doc(db, 'users', user.uid) : null, [user?.uid])
  const [staged, setStaged] = useState<Set<string>>(new Set())
  const [editing, setEditing] = useState(false)
  const [editProfile, setEditProfile] = useState(false)
  const [rawOpen, setRawOpen] = useState(false)

  const data: Row = userDoc.data?.data() ?? {}
  const visitedRaw: string[] = useMemo(() => (Array.isArray(data.visitedCountries) ? data.visitedCountries.map(String) : []), [data.visitedCountries]) // eslint-disable-line react-hooks/exhaustive-deps
  const visitedKey = visitedRaw.join('|')

  // Keep staged in sync with Firestore unless the user is actively editing on the map.
  useEffect(() => {
    if (!editing) setStaged(new Set(visitedRaw))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [visitedKey, editing])

  if (authLoading || (user && userDoc.loading)) return <PageShell><CenteredSpinner pad={120} /></PageShell>

  if (!user) {
    return (
      <PageShell>
        <div className="container" style={{ maxWidth: 920, padding: 24 }}>
          <SoftCard elevated padding={20}>
            <div style={{ padding: 20, borderRadius: 20, color: '#fff', background: 'linear-gradient(135deg, #1F6FAE, #4aade8, #2BA9A0)' }}>
              <h2 style={{ margin: 0, fontWeight: 700 }}>Account</h2>
              <p style={{ marginTop: 8, fontSize: 14 }}>Sign in to view your profile, travel map, and social circle.</p>
              <button className="btn" style={{ background: '#fff', color: 'var(--primary-dark)', marginTop: 16 }} onClick={() => navigate('/sign-in')}><MdLogin size={18} /> Sign in</button>
            </div>
          </SoftCard>
        </div>
      </PageShell>
    )
  }

  const displayName = String(data.name ?? data.displayName ?? user.displayName ?? '—')
  const email = String(user.email ?? data.email ?? '—')
  const subscription = String(data.subscriptionType ?? data.subscription ?? 'Free')
  const city = String(data.city ?? '—')
  const dobStr = dobToString(data.dob) || '—'
  const sex = String(data.sex ?? data.gender ?? '—')
  const profileImage = (data.profileImageDataUrl as string | undefined) || ''
  const friends: Row[] = (Array.isArray(data.friends) ? data.friends : []).map((f: any) => (f && typeof f === 'object' ? f : { id: String(f) }))
  const visitedCount = staged.size
  const progress = TOTAL_SUPPORTED > 0 ? visitedCount / TOTAL_SUPPORTED : 0
  const percent = Math.round(progress * 100)
  const sorted = [...new Set(visitedRaw)].sort()

  const persistVisited = async () => {
    try {
      await setDoc(doc(db, 'users', user.uid), { visitedCountries: [...staged] }, { merge: true })
      setEditing(false)
    } catch (e: any) {
      toast(`Failed to save: ${e?.message ?? e}`)
    }
  }
  const removeRegion = async (name: string) => {
    try {
      await updateDoc(doc(db, 'users', user.uid), { visitedCountries: arrayRemove(name) })
      setStaged((s) => { const n = new Set(s); n.delete(name); return n })
      setEditing(false)
    } catch (e: any) {
      toast(`Failed to remove: ${e?.message ?? e}`)
    }
  }
  const doSignOut = async () => {
    await signOut(auth)
    navigate('/sign-in', { replace: true })
    toast('Signed out')
  }

  const avatar = (size: number, fs: number) => (
    <div style={{ width: size, height: size, borderRadius: '50%', flex: 'none', overflow: 'hidden', background: 'rgba(255,255,255,0.22)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', fontWeight: 700, fontSize: fs }}>
      {profileImage ? <img src={profileImage} alt="" style={{ width: '100%', height: '100%', objectFit: 'cover' }} /> : initialsFor(displayName)}
    </div>
  )

  return (
    <PageShell>
      <div className="container" style={{ maxWidth: 920, padding: 16 }}>
        <SoftCard elevated padding={20}>
          <div style={{ position: 'relative', overflow: 'hidden', borderRadius: 20, padding: 16, color: '#fff', background: 'linear-gradient(135deg, #1F6FAE, #4aade8, #2BA9A0)', boxShadow: 'var(--shadow-soft)' }}>
            <div style={{ position: 'absolute', right: -28, top: -22, width: 120, height: 120, borderRadius: '50%', background: 'rgba(255,255,255,0.11)' }} />
            <div style={{ position: 'absolute', left: -24, bottom: -28, width: 110, height: 110, borderRadius: '50%', background: 'rgba(255,255,255,0.07)' }} />
            <div style={{ position: 'relative' }}>
              <div className="row" style={{ gap: 12 }}>
                {avatar(compact ? 56 : 68, compact ? 18 : 20)}
                <div className="grow" style={{ minWidth: 0 }}>
                  <div style={{ fontSize: 24, fontWeight: 700 }}>{displayName}</div>
                  <div style={{ fontSize: compact ? 13 : 14 }}>{email}</div>
                  {!compact && (
                    <div className="row wrap gap-sm" style={{ marginTop: 10 }}>
                      <Pill icon={<MdLocationOn size={14} />} text={city === '—' ? 'City not set' : city} />
                      <Pill icon={<MdBadge size={14} />} text={sex} />
                      <Pill icon={<MdCake size={14} />} text={dobStr} />
                      <Pill icon={<MdWorkspacePremium size={14} />} text={subscription} />
                    </div>
                  )}
                </div>
              </div>
              {compact && (
                <div className="row wrap gap-sm" style={{ marginTop: 12 }}>
                  <Pill icon={<MdWorkspacePremium size={14} />} text={subscription} />
                  <Pill icon={<MdPublic size={14} />} text={`${visitedCount} countries`} />
                  <Pill icon={<MdOutlinePeopleAlt size={14} />} text={`${friends.length} friends`} />
                </div>
              )}
            </div>
          </div>

          <div className="stat-grid" style={{ marginTop: 16, gap: 8 }}>
            <Metric icon={<MdPublic size={18} />} label="Countries visited" value={String(visitedCount)} accent="#4aade8" />
            <Metric icon={<MdOutlineRoute size={18} />} label="World coverage" value={`${percent}%`} accent="#00897b" />
            <Metric icon={<MdOutlinePeopleAlt size={18} />} label="Friends" value={String(friends.length)} accent="#ffb17a" />
            <Metric icon={<MdOutlineWorkspacePremium size={18} />} label="Membership" value={subscription} accent="#4ecdc4" />
          </div>

          <Section
            icon={<MdPeopleOutline size={20} />} accent="#00897b" title="Travel Circle" subtitle="People connected to your account"
            trailing={!compact && <span style={{ padding: '6px 10px', borderRadius: 999, background: 'var(--surface-variant)', fontWeight: 600, fontSize: 12 }}>{friends.length} total</span>}
          >
            {friends.length === 0 ? (
              <div style={{ padding: 12, borderRadius: 12, background: 'var(--surface-variant)' }}>No friends added yet. Invite someone and start planning together.</div>
            ) : (
              <div className="row wrap gap-sm">
                {friends.map((f, i) => {
                  const fname = String(f.name ?? f.displayName ?? f.email ?? f.id ?? 'Friend')
                  const accent = chipAccent(fname)
                  return (
                    <span key={i} style={{ display: 'inline-flex', alignItems: 'center', gap: 8, padding: '8px 10px', borderRadius: 999, background: `${accent}1f`, border: `1px solid ${accent}4d` }}>
                      <span style={{ width: 22, height: 22, borderRadius: '50%', background: `${accent}38`, fontSize: 10, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{initialsFor(fname)}</span>
                      <span className="ellipsis" style={{ maxWidth: compact ? 170 : 220, fontWeight: 600, fontSize: 13 }}>{fname}</span>
                    </span>
                  )
                })}
              </div>
            )}
          </Section>

          <Section
            icon={<MdTravelExplore size={20} />} accent="#4aade8" title="My Travel Map" subtitle="Tap countries to mark places you have visited"
            trailing={<span style={{ padding: '6px 10px', borderRadius: 999, background: 'rgba(74,173,232,0.12)', fontWeight: 700, fontSize: 12, color: 'var(--primary-dark)' }}>{percent}% explored</span>}
          >
            <div style={{ borderRadius: 12, overflow: 'hidden', border: '1px solid var(--border)', padding: 8 }}>
              <VisitedMap
                height={compact ? 320 : 460} visited={staged}
                onAdd={(name) => { setStaged((s) => new Set(s).add(name)); setEditing(true) }}
              />
            </div>
            <div className="row" style={{ gap: 12, marginTop: 12, alignItems: 'center', flexWrap: 'wrap' }}>
              <div className="row grow" style={{ gap: 10, alignItems: 'center', minWidth: 200 }}>
                <progress value={progress} max={1} style={{ flex: 1, height: 8 }} />
                <span>{percent}%</span>
              </div>
              <Button variant="primary" disabled={!editing} icon={<MdSaveAlt size={18} />} block={compact} onClick={persistVisited}>Save travel map</Button>
            </div>
            <div className="muted" style={{ fontSize: 12, marginTop: 8 }}>{visitedCount} visited / {TOTAL_SUPPORTED} supported</div>
          </Section>

          <Section
            icon={<MdFlag size={20} />} accent="#f59e0b" title="Visited Regions"
            trailing={<span style={{ padding: '5px 10px', borderRadius: 999, background: 'var(--surface-variant)', fontWeight: 700, fontSize: 12 }}>{sorted.length}</span>}
          >
            {sorted.length ? (
              <div className="row wrap gap-sm">
                {sorted.map((c) => {
                  const accent = chipAccent(c)
                  return (
                    <span key={c} className="chip" style={{ background: `${accent}1f`, border: `1px solid ${accent}47`, fontSize: 12, fontWeight: 600, gap: 6 }}>
                      {c}
                      <button className="icon-btn" style={{ width: 18, height: 18, color: accent }} title={`Remove ${c}`} onClick={() => void removeRegion(c)}>✕</button>
                    </span>
                  )
                })}
              </div>
            ) : (
              <div style={{ padding: 12, borderRadius: 12, background: 'var(--surface-variant)' }}>No regions marked yet. Use the map above to start building your footprint.</div>
            )}
          </Section>

          <div className="row wrap gap-sm" style={{ marginTop: 16, flexDirection: compact ? 'column' : 'row', alignItems: compact ? 'stretch' : 'center' }}>
            <Button variant="primary" icon={<MdEdit size={18} />} onClick={() => setEditProfile(true)}>Edit profile</Button>
            <Button variant="outlined" icon={<MdLogout size={18} />} onClick={() => void doSignOut()}>Sign out</Button>
          </div>
          <div style={{ marginTop: 8 }}>
            <Button variant="text" size="sm" icon={<MdBugReport size={16} />} onClick={() => setRawOpen(true)}>Show raw doc</Button>
          </div>
        </SoftCard>
      </div>

      {editProfile && <EditProfileDialog uid={user.uid} data={data} onClose={() => setEditProfile(false)} />}
      <Dialog open={rawOpen} onClose={() => setRawOpen(false)} title="Raw user document" actions={<Button variant="text" onClick={() => setRawOpen(false)}>Close</Button>}>
        <pre style={{ whiteSpace: 'pre-wrap', fontSize: 12, userSelect: 'text' }}>{JSON.stringify(data, null, 2)}</pre>
      </Dialog>
    </PageShell>
  )
}
