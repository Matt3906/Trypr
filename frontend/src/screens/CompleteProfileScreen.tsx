import { useState } from 'react'
import { doc, setDoc } from 'firebase/firestore'
import { useNavigate } from 'react-router-dom'
import { auth, db } from '@/firebase'
import PageShell from '@/components/PageShell'
import { Dialog } from '@/components/Dialog'
import { Button, Field, Spinner } from '@/components/ui'
import { useFeedback } from '@/context/Feedback'
import { useBack } from '@/hooks/useBack'

export const COMMON_COUNTRIES = [
  'United States', 'Canada', 'Mexico', 'United Kingdom', 'France', 'Germany', 'Italy', 'Spain', 'Portugal',
  'Netherlands', 'Belgium', 'Switzerland', 'Austria', 'Ireland', 'Sweden', 'Norway', 'Denmark', 'Finland',
  'Iceland', 'Poland', 'Czech Republic', 'Greece', 'Turkey', 'Russia', 'China', 'Japan', 'South Korea',
  'India', 'Australia', 'New Zealand', 'South Africa', 'Morocco', 'Egypt', 'Kenya', 'Argentina', 'Brazil',
  'Chile', 'Peru', 'Colombia',
]

export default function CompleteProfileScreen() {
  const { toast } = useFeedback()
  const navigate = useNavigate()
  const back = useBack('/')
  const [name, setName] = useState('')
  const [city, setCity] = useState('')
  const [sex, setSex] = useState('male')
  const [dob, setDob] = useState('')
  const [visited, setVisited] = useState<string[]>([])
  const [saving, setSaving] = useState(false)
  const [editOpen, setEditOpen] = useState(false)
  const [draft, setDraft] = useState<Set<string>>(new Set())

  const save = async () => {
    const uid = auth.currentUser?.uid
    if (!uid) return
    if (!name.trim() || !city.trim()) {
      toast('Please fill name and city')
      return
    }
    setSaving(true)
    const upd: Record<string, any> = {
      name: name.trim(),
      displayName: name.trim(),
      displayNameLower: name.trim().toLowerCase(),
      city: city.trim(),
      sex,
      visitedCountries: visited,
    }
    if (dob) upd.dob = new Date(dob).toISOString()
    try {
      await setDoc(doc(db, 'users', uid), upd, { merge: true })
    } catch (e: any) {
      toast(`Save failed: ${e?.message ?? e}`)
      setSaving(false)
      return
    }
    toast('Profile completed')
    setSaving(false)
    navigate('/account', { replace: true })
  }

  return (
    <PageShell>
      <div className="center" style={{ padding: 16 }}>
        <div className="soft-card col gap-md" style={{ width: '100%', maxWidth: 720, padding: 16 }}>
          <h2 className="t-head-s">Complete your profile</h2>
          <Field label="Name"><input className="input" value={name} onChange={(e) => setName(e.target.value)} /></Field>
          <Field label="City"><input className="input" value={city} onChange={(e) => setCity(e.target.value)} /></Field>
          <div className="row gap-md wrap">
            <div className="grow"><Field label="Sex">
              <select className="select" value={sex} onChange={(e) => setSex(e.target.value)}>
                <option value="male">Male</option>
                <option value="female">Female</option>
              </select>
            </Field></div>
            <div className="grow"><Field label="Date of birth">
              <input className="input" type="date" value={dob} max={new Date().toISOString().slice(0, 10)} onChange={(e) => setDob(e.target.value)} />
            </Field></div>
          </div>
          <div className="row between">
            <span className="t-title-m">Visited countries</span>
            <Button variant="text" onClick={() => { setDraft(new Set(visited)); setEditOpen(true) }}>Edit</Button>
          </div>
          <div className="row wrap gap-sm">{visited.map((c) => <span key={c} className="chip">{c}</span>)}</div>
          <div className="row gap-md">
            <Button variant="solid" block onClick={save} disabled={saving}>{saving ? <Spinner size="sm" white /> : 'Save'}</Button>
            <Button variant="outlined" onClick={back}>Skip</Button>
          </div>
        </div>
      </div>

      <Dialog
        open={editOpen}
        onClose={() => setEditOpen(false)}
        title="Visited countries"
        actions={
          <>
            <Button variant="text" onClick={() => setEditOpen(false)}>Cancel</Button>
            <Button variant="text" onClick={() => { setVisited([...draft]); setEditOpen(false) }}>Done</Button>
          </>
        }
      >
        <div className="row wrap gap-sm">
          {COMMON_COUNTRIES.map((c) => (
            <button
              key={c}
              type="button"
              className={`chip ${draft.has(c) ? 'selected' : ''}`}
              onClick={() => setDraft((d) => { const n = new Set(d); n.has(c) ? n.delete(c) : n.add(c); return n })}
            >
              {c}
            </button>
          ))}
        </div>
      </Dialog>
    </PageShell>
  )
}
