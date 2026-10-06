import { useEffect, useRef, useState } from 'react'
import { addDoc, collection, doc, onSnapshot, serverTimestamp } from 'firebase/firestore'
import { getDownloadURL, ref, uploadBytes } from 'firebase/storage'
import ReactMarkdown from 'react-markdown'
import { useParams } from 'react-router-dom'
import { MdCheckCircleOutline, MdErrorOutline, MdLinkOff, MdUploadFile, MdOutlineCalendarToday, MdDeleteOutline } from 'react-icons/md'
import { auth, db, storage } from '@/firebase'
import { useFeedback } from '@/context/Feedback'
import PageShell from '@/components/PageShell'
import { Button, SoftCard, Spinner, cx } from '@/components/ui'
import { pickFile, sanitizeUploadName } from '@/lib/files'

type Row = Record<string, any>

const normalizeMarkdown = (raw: string) => raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim()
const EMAIL_RE = /^[\w-.]+@([\w-]+\.)+[\w-]{2,4}$/
const empty = (v: unknown) => !String(v ?? '').trim()

/** Returns an error message for a field, or null. Mirrors the Flutter validators (only enforced when required). */
export function validateField(field: Row, value: any): string | null {
  if (field.required !== true) return null
  const type = String(field.type ?? 'text')
  switch (type) {
    case 'email':
      if (empty(value)) return 'Required'
      return EMAIL_RE.test(String(value)) ? null : 'Invalid email'
    case 'number':
      if (empty(value)) return 'Required'
      return Number.isNaN(parseFloat(String(value))) ? 'Invalid number' : null
    case 'checkbox':
      return Array.isArray(value) && value.length ? null : 'Select at least one'
    case 'file':
      return empty(value?.url) ? 'Required' : null
    case 'name':
      if (!value) return 'Required'
      if (empty(value.first)) return 'First name required'
      if (empty(value.last)) return 'Last name required'
      return null
    case 'address':
      if (!value) return 'Required'
      if (empty(value.street)) return 'Street required'
      if (empty(value.city)) return 'City required'
      if (empty(value.province)) return 'Province required'
      if (empty(value.postal)) return 'Postal code required'
      return null
    case 'signature':
      return empty(value) ? 'Signature is required' : null
    default:
      return empty(value) ? 'Required' : null
  }
}

function SignaturePad({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const canvas = useRef<HTMLCanvasElement>(null)
  const drawing = useRef(false)

  useEffect(() => {
    const c = canvas.current
    if (!c) return
    const rect = c.getBoundingClientRect()
    c.width = rect.width * 2
    c.height = rect.height * 2
    const ctx = c.getContext('2d')!
    ctx.scale(2, 2)
    ctx.lineWidth = 2
    ctx.lineCap = 'round'
    ctx.strokeStyle = '#111'
  }, [])
  useEffect(() => {
    if (!value) canvas.current?.getContext('2d')?.clearRect(0, 0, canvas.current.width, canvas.current.height)
  }, [value])

  const pos = (e: React.PointerEvent) => {
    const r = canvas.current!.getBoundingClientRect()
    return { x: e.clientX - r.left, y: e.clientY - r.top }
  }
  return (
    <div>
      <div className="sig-pad">
        <canvas
          ref={canvas}
          onPointerDown={(e) => { drawing.current = true; canvas.current!.setPointerCapture(e.pointerId); const p = pos(e); const ctx = canvas.current!.getContext('2d')!; ctx.beginPath(); ctx.moveTo(p.x, p.y) }}
          onPointerMove={(e) => { if (!drawing.current) return; const p = pos(e); const ctx = canvas.current!.getContext('2d')!; ctx.lineTo(p.x, p.y); ctx.stroke() }}
          onPointerUp={() => { if (drawing.current) { drawing.current = false; onChange(`SIGNED_${Date.now()}`) } }}
        />
        {!value && <div className="center faint" style={{ position: 'absolute', inset: 0, pointerEvents: 'none', fontSize: 18 }}>Sign Here</div>}
      </div>
      {value && <div style={{ textAlign: 'right', marginTop: 8 }}><Button variant="text" size="sm" onClick={() => onChange('')}>Clear</Button></div>}
    </div>
  )
}

function FieldBlock({ field, value, error, onChange, pageSlug }: { field: Row; value: any; error?: string; onChange: (v: any) => void; pageSlug: string }) {
  const { toast } = useFeedback()
  const [uploading, setUploading] = useState(false)
  const id = String(field.id ?? '')
  const label = String(field.label ?? 'Field')
  const type = String(field.type ?? 'text')
  const required = field.required === true
  const title = required ? `${label} *` : label
  const options: string[] = Array.isArray(field.options) ? field.options.map(String) : []
  const hint = String(field.hint ?? '')
  const Err = error ? <div className="form-error">{error}</div> : null
  const Label = <div style={{ fontSize: 16, fontWeight: 500, marginBottom: 8 }}>{title}</div>

  switch (type) {
    case 'email': case 'phone': case 'number': case 'text':
      return <div className="field"><label>{title}</label><input className={cx('input', error && 'error')} type={type === 'email' ? 'email' : type === 'number' ? 'text' : type === 'phone' ? 'tel' : 'text'} inputMode={type === 'number' ? 'decimal' : undefined} placeholder={hint} value={value ?? ''} onChange={(e) => onChange(e.target.value)} />{Err}</div>
    case 'textarea':
      return <div className="field"><label>{title}</label><textarea className={cx('textarea', error && 'error')} rows={4} placeholder={hint} value={value ?? ''} onChange={(e) => onChange(e.target.value)} />{Err}</div>
    case 'dropdown':
      return <div className="field"><label>{title}</label><select className={cx('select', error && 'error')} value={value ?? ''} onChange={(e) => onChange(e.target.value)}><option value="" disabled>{hint || 'Select…'}</option>{options.map((o) => <option key={o}>{o}</option>)}</select>{Err}</div>
    case 'radio':
      return <div>{Label}{options.map((o) => <label key={o} className="row gap-sm" style={{ padding: '4px 0' }}><input type="radio" name={id} checked={value === o} onChange={() => onChange(o)} />{o}</label>)}{Err}</div>
    case 'checkbox': {
      const selected: string[] = Array.isArray(value) ? value : []
      return <div>{Label}{options.map((o) => <label key={o} className="row gap-sm" style={{ padding: '4px 0' }}><input type="checkbox" checked={selected.includes(o)} onChange={(e) => onChange(e.target.checked ? [...selected, o] : selected.filter((x) => x !== o))} />{o}</label>)}{Err}</div>
    }
    case 'date':
      return <div>{Label}<div className="row gap-sm" style={{ alignItems: 'center' }}><MdOutlineCalendarToday size={20} /><input className="input" type="date" min="1900-01-01" max="2100-12-31" value={value ?? ''} onChange={(e) => onChange(e.target.value)} /></div>{Err}</div>
    case 'file': {
      const current: Row = value && typeof value === 'object' ? value : {}
      const has = !empty(current.url)
      return (
        <div>
          {Label}
          <Button
            variant="outlined" loading={uploading} icon={<MdUploadFile size={18} />} style={{ justifyContent: 'flex-start', maxWidth: '100%' }}
            onClick={async () => {
              const file = await pickFile('.pdf,.png,.jpg,.jpeg,.webp,.txt,.doc,.docx,.xls,.xlsx,.csv,.rtf')
              if (!file) return
              setUploading(true)
              try {
                const path = `unlistedFormUploads/${pageSlug}/${id}/${Date.now()}_${sanitizeUploadName(file.name)}`
                const r = ref(storage, path)
                const contentType = file.type || 'application/octet-stream'
                await uploadBytes(r, file, { contentType, customMetadata: { pageSlug, fieldId: id, fieldLabel: label, originalName: file.name } })
                onChange({ fileName: file.name, url: await getDownloadURL(r), contentType, sizeBytes: file.size, storagePath: path, uploadedAt: new Date().toISOString() })
              } catch (e: any) {
                toast(`File upload failed: ${e?.message ?? e}`)
              } finally {
                setUploading(false)
              }
            }}
          >
            <span className="ellipsis">{uploading ? 'Uploading...' : has ? String(current.fileName ?? 'File') : 'Choose File'}</span>
          </Button>
          {has && <div style={{ textAlign: 'right' }}><Button variant="text" size="sm" icon={<MdDeleteOutline size={16} />} onClick={() => onChange(undefined)}>Remove file</Button></div>}
          {Err}
        </div>
      )
    }
    case 'name': {
      const v: Row = value ?? {}
      return (
        <div>{Label}
          <div className="row wrap gap-md">
            <div className="field grow" style={{ minWidth: 200 }}><label>First Name</label><input className="input" value={v.first ?? ''} onChange={(e) => onChange({ ...v, first: e.target.value })} /></div>
            <div className="field grow" style={{ minWidth: 200 }}><label>Last Name</label><input className="input" value={v.last ?? ''} onChange={(e) => onChange({ ...v, last: e.target.value })} /></div>
          </div>{Err}
        </div>
      )
    }
    case 'address': {
      const v: Row = value ?? {}
      const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement>) => onChange({ ...v, [k]: e.target.value })
      return (
        <div>{Label}
          <div className="col gap-md">
            <div className="field"><label>Street Address</label><input className="input" value={v.street ?? ''} onChange={set('street')} /></div>
            <div className="field"><label>Apt, Suite, etc. (Optional)</label><input className="input" value={v.street2 ?? ''} onChange={set('street2')} /></div>
            <div className="row wrap gap-md">
              <div className="field grow" style={{ flex: '2 1 200px' }}><label>City</label><input className="input" value={v.city ?? ''} onChange={set('city')} /></div>
              <div className="field grow" style={{ minWidth: 140 }}><label>Province</label><input className="input" value={v.province ?? ''} onChange={set('province')} /></div>
              <div className="field grow" style={{ minWidth: 120 }}><label>Postal</label><input className="input" value={v.postal ?? ''} onChange={set('postal')} /></div>
            </div>
          </div>{Err}
        </div>
      )
    }
    case 'signature':
      return <div>{Label}<SignaturePad value={String(value ?? '')} onChange={onChange} />{Err}</div>
    default:
      return <div className="field"><label>{title}</label><input className={cx('input', error && 'error')} placeholder={hint} value={value ?? ''} onChange={(e) => onChange(e.target.value)} />{Err}</div>
  }
}

function SignupForm({ slug, page }: { slug: string; page: Row }) {
  const fields: Row[] = (Array.isArray(page.formFields) ? page.formFields : []).filter((f: any) => f && typeof f === 'object')
  const [values, setValues] = useState<Record<string, any>>({})
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [submitting, setSubmitting] = useState(false)
  const [submitted, setSubmitted] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const pad = window.innerWidth < 600 ? 16 : 24

  if (submitted) {
    return (
      <SoftCard elevated padding={pad} color="#e8f5e9" className="center col gap-sm" style={{ textAlign: 'center' }}>
        <MdCheckCircleOutline size={64} color="#2e7d32" />
        <div style={{ fontSize: 24, fontWeight: 700, color: '#1b5e20' }}>Thank You!</div>
        <div style={{ fontSize: 16, color: '#2e7d32' }}>Your submission has been received.</div>
      </SoftCard>
    )
  }

  const submit = async () => {
    const errs: Record<string, string> = {}
    for (const f of fields) {
      const id = String(f.id ?? '')
      if (!id) continue
      const e = validateField(f, values[id])
      if (e) errs[id] = e
    }
    setErrors(errs)
    if (Object.keys(errs).length) return
    setSubmitting(true)
    setSubmitError(null)
    try {
      const responses: Row = {}
      const formatted: Row[] = []
      for (const f of fields) {
        const id = String(f.id ?? '')
        if (!id) continue
        const label = String(f.label ?? 'Unlabeled Field')
        const type = String(f.type ?? 'text')
        const raw = values[id]
        let value: any
        if (['dropdown', 'radio', 'date', 'checkbox'].includes(type)) value = raw ?? ''
        else if (type === 'file') value = raw && typeof raw === 'object' ? { ...raw } : {}
        else if (type === 'name') value = `${raw?.first ?? ''} ${raw?.last ?? ''}`.trim()
        else if (type === 'address') value = { street: raw?.street ?? '', street2: raw?.street2 ?? '', city: raw?.city ?? '', province: raw?.province ?? '', postal: raw?.postal ?? '' }
        else if (type === 'signature') value = raw ? 'Signed' : ''
        else value = raw ?? ''
        responses[id] = value
        formatted.push({ label, type, value })
      }
      const user = auth.currentUser
      await addDoc(collection(db, 'unlistedPages', slug, 'responses'), {
        responses, formattedResponses: formatted, submittedAt: serverTimestamp(),
        submittedByUid: user?.uid ?? null, submittedByEmail: user?.email ?? null, submittedByName: user?.displayName ?? null,
      })
      setSubmitted(true)
    } catch (e: any) {
      setSubmitError(String(e?.message ?? e))
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <SoftCard elevated padding={pad}>
      <h2 style={{ margin: '0 0 24px', fontSize: 24 }}>{String(page.formTitle ?? 'Sign Up')}</h2>
      <div className="col" style={{ gap: 16 }}>
        {fields.map((f, i) => (
          <FieldBlock key={String(f.id ?? i)} field={f} pageSlug={slug} value={values[String(f.id ?? '')]} error={errors[String(f.id ?? '')]} onChange={(v) => { setValues((s) => ({ ...s, [String(f.id)]: v })); setErrors((s) => ({ ...s, [String(f.id)]: '' })) }} />
        ))}
      </div>
      {submitError && <div style={{ color: 'red', marginTop: 16 }}>Error: {submitError}</div>}
      <Button variant="solid" block loading={submitting} style={{ marginTop: 24, background: '#00B894', minHeight: 52, fontSize: 16 }} onClick={() => void submit()}>
        {String(page.formButtonText ?? 'Submit')}
      </Button>
    </SoftCard>
  )
}

/** Public view for unlisted pages — `/page/:slug`. */
export default function UnlistedPageScreen() {
  const { slug = '' } = useParams()
  const [state, setState] = useState<{ loading: boolean; error: Error | null; exists: boolean; data: Row }>({ loading: true, error: null, exists: false, data: {} })
  useEffect(() => onSnapshot(doc(db, 'unlistedPages', slug), (s) => setState({ loading: false, error: null, exists: s.exists(), data: s.data() ?? {} }), (error) => setState({ loading: false, error, exists: false, data: {} })), [slug])

  let body: React.ReactNode
  if (state.error) {
    body = <div className="center col gap-sm" style={{ padding: 40 }}><MdErrorOutline size={64} color="red" /><h2>Error loading page</h2><div className="muted">{state.error.message}</div></div>
  } else if (state.loading) {
    body = <div className="center" style={{ padding: 60 }}><Spinner /></div>
  } else if (!state.exists) {
    body = (
      <div className="center col gap-sm" style={{ padding: 40, textAlign: 'center' }}>
        <MdLinkOff size={64} className="faint" /><h2 style={{ margin: 0 }}>Page not found</h2>
        <div className="muted">This link may have expired or been removed.</div><div className="faint" style={{ fontSize: 12 }}>Looking for: {slug}</div>
      </div>
    )
  } else {
    const d = state.data
    const title = String(d.title ?? 'Untitled Page')
    const description = normalizeMarkdown(String(d.description ?? ''))
    const content = normalizeMarkdown(String(d.content ?? ''))
    const cover = String(d.coverImage ?? '')
    const vw = window.innerWidth
    const heroHeight = Math.max(220, Math.min(420, vw * 0.42))
    const hp = vw < 600 ? 16 : 24
    body = (
      <>
        {cover ? (
          <div style={{ position: 'relative', height: heroHeight }}>
            <img src={cover} alt={`${title} cover image`} style={{ position: 'absolute', inset: 0, width: '100%', height: '100%', objectFit: 'cover', background: '#e0e0e0' }} />
            <div style={{ position: 'absolute', inset: 0, background: 'linear-gradient(to bottom, transparent, rgba(0,0,0,0.6))' }} />
            <h1 style={{ position: 'absolute', left: hp, right: hp, bottom: hp, margin: 0, fontSize: 32, fontWeight: 700, color: '#fff', textShadow: '0 0 10px rgba(0,0,0,0.54)' }}>{title}</h1>
          </div>
        ) : (
          <h1 style={{ margin: 0, padding: hp + 8, fontSize: 32, fontWeight: 700 }}>{title}</h1>
        )}
        <div style={{ maxWidth: 860 + hp * 2, margin: '0 auto', padding: `24px ${hp}px 60px` }}>
          {description && <div className="md lead" style={{ marginBottom: 24 }}><ReactMarkdown>{description}</ReactMarkdown></div>}
          {content && <div className="md" style={{ marginBottom: 32 }}><ReactMarkdown>{content}</ReactMarkdown></div>}
          {d.formEnabled === true && <SignupForm slug={slug} page={d} />}
        </div>
      </>
    )
  }
  return <PageShell bodyStyle={{ overflowY: 'auto' }}>{body}</PageShell>
}
