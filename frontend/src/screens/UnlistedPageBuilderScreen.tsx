import { useEffect, useState } from 'react'
import { doc, getDoc, serverTimestamp, setDoc } from 'firebase/firestore'
import { getDownloadURL, ref, uploadBytes } from 'firebase/storage'
import { useLocation, useNavigate, useParams } from 'react-router-dom'
import { MdAddCircleOutline, MdAddPhotoAlternate, MdArrowBack, MdDeleteOutline, MdLink, MdOutlineRemoveCircleOutline, MdRefresh, MdAdd } from 'react-icons/md'
import { auth, db, storage } from '@/firebase'
import { useFeedback } from '@/context/Feedback'
import { Button, SoftCard, Spinner } from '@/components/ui'
import { pickImageDataUrl } from '@/lib/image'
import { dataUrlToBlob } from '@/lib/files'

type Row = Record<string, any>
const FIELD_TYPES: [string, string][] = [
  ['text', 'Text'], ['email', 'Email'], ['phone', 'Phone'], ['number', 'Number'], ['textarea', 'Long Text'], ['dropdown', 'Dropdown'],
  ['radio', 'Radio Buttons'], ['checkbox', 'Checkboxes'], ['date', 'Date'], ['file', 'File Upload'], ['name', 'Full Name'], ['address', 'Address'], ['signature', 'Signature'],
]
const generateSlug = () => {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789'
  return Array.from({ length: 8 }, () => chars[Math.floor(Math.random() * chars.length)]).join('')
}
const DEFAULT_FIELDS: Row[] = [
  { id: 'name', label: 'Full Name', type: 'text', required: true },
  { id: 'email', label: 'Email', type: 'email', required: true },
  { id: 'phone', label: 'Phone Number', type: 'phone', required: false },
]

function OptionsEditor({ options, onChange }: { options: string[]; onChange: (o: string[]) => void }) {
  const opts = options.length ? options : ['Option 1', 'Option 2']
  return (
    <div style={{ padding: 8, borderRadius: 4, background: '#e3f2fd', border: '1px solid #90caf9' }}>
      <div style={{ fontWeight: 600, fontSize: 12, color: '#1976d2', marginBottom: 8 }}>Options</div>
      {opts.map((o, i) => (
        <div key={i} className="row gap-sm" style={{ marginBottom: 6 }}>
          <input className="input" placeholder={`Option ${i + 1}`} value={o} onChange={(e) => onChange(opts.map((x, k) => (k === i ? e.target.value : x)))} />
          <button className="icon-btn" title="Remove option" disabled={opts.length <= 1} style={{ color: '#ef4444' }} onClick={() => onChange(opts.filter((_x, k) => k !== i))}><MdOutlineRemoveCircleOutline size={20} /></button>
        </div>
      ))}
      <Button variant="text" size="sm" icon={<MdAddCircleOutline size={16} />} onClick={() => onChange([...opts, `Option ${opts.length + 1}`])}>Add Option</Button>
    </div>
  )
}

function FieldEditor({ field, onUpdate, onRemove }: { field: Row; onUpdate: (k: string, v: any) => void; onRemove: () => void }) {
  const type = String(field.type ?? 'text')
  return (
    <div style={{ marginBottom: 12, padding: 12, borderRadius: 8, background: '#fafafa', border: '1px solid #eee' }}>
      <div className="row gap-md" style={{ alignItems: 'flex-end' }}>
        <div className="field" style={{ flex: 2 }}><label>Label</label><input className="input" value={String(field.label ?? '')} onChange={(e) => onUpdate('label', e.target.value)} /></div>
        <div className="field" style={{ flex: 1 }}><label>Type</label><select className="select" value={type} onChange={(e) => onUpdate('type', e.target.value)}>{FIELD_TYPES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
        <button className="icon-btn" title="Remove field" style={{ color: '#ef4444' }} onClick={onRemove}><MdDeleteOutline size={22} /></button>
      </div>
      <div className="row gap-md" style={{ marginTop: 8, alignItems: 'flex-end' }}>
        <div className="field grow"><label>Hint/Placeholder</label><input className="input" value={String(field.hint ?? '')} onChange={(e) => onUpdate('hint', e.target.value)} /></div>
        <label className="row gap-sm" style={{ paddingBottom: 10 }}><input type="checkbox" checked={field.required === true} onChange={(e) => onUpdate('required', e.target.checked)} /> Required</label>
      </div>
      {['dropdown', 'radio', 'checkbox'].includes(type) && <div style={{ marginTop: 12 }}><OptionsEditor options={Array.isArray(field.options) ? field.options.map(String) : []} onChange={(o) => onUpdate('options', o)} /></div>}
    </div>
  )
}

function Builder({ existingId, existing }: { existingId?: string; existing?: Row }) {
  const navigate = useNavigate()
  const { toast } = useFeedback()
  const isEditing = !!existingId
  const [title, setTitle] = useState(String(existing?.title ?? ''))
  const [slug, setSlug] = useState(existingId ?? generateSlug())
  const [description, setDescription] = useState(String(existing?.description ?? ''))
  const [content, setContent] = useState(String(existing?.content ?? ''))
  const [cover, setCover] = useState(String(existing?.coverImage ?? ''))
  const [formEnabled, setFormEnabled] = useState(existing ? existing.formEnabled === true : true)
  const [formTitle, setFormTitle] = useState(String(existing?.formTitle ?? 'Sign Up'))
  const [buttonText, setButtonText] = useState(String(existing?.formButtonText ?? 'Submit'))
  const [fields, setFields] = useState<Row[]>(existing ? (Array.isArray(existing.formFields) ? existing.formFields.filter((f: any) => f && typeof f === 'object').map((f: any) => ({ ...f })) : []) : DEFAULT_FIELDS.map((f) => ({ ...f })))
  const [saving, setSaving] = useState(false)
  const [errors, setErrors] = useState<{ title?: string; slug?: string }>({})

  const copyLink = () => {
    if (!slug.trim()) return
    navigator.clipboard?.writeText(`${window.location.origin}/page/${slug}`)
    toast('Link copied to clipboard')
  }

  const save = async () => {
    const errs = { title: title.trim() ? undefined : 'Required', slug: slug.trim() ? undefined : 'Required' }
    setErrors(errs)
    if (errs.title || errs.slug) return
    const user = auth.currentUser
    if (!user) return toast('You must be signed in')
    const clean = slug.trim().toLowerCase().replace(/[^a-z0-9-]/g, '')
    if (!clean) return toast('Please enter a valid page ID/slug')
    setSaving(true)
    try {
      const docRef = doc(db, 'unlistedPages', clean)
      if (!isEditing && (await getDoc(docRef)).exists()) {
        toast('This page ID already exists. Choose a different one.')
        return
      }
      let coverImage = cover
      if (coverImage.startsWith('data:image')) {
        const decoded = dataUrlToBlob(coverImage)
        if (!decoded) throw new Error('Invalid image format')
        const ext = decoded.contentType.includes('png') ? 'png' : decoded.contentType.includes('webp') ? 'webp' : decoded.contentType.includes('gif') ? 'gif' : 'jpg'
        const r = ref(storage, `unlistedPages/${clean}/cover_${Date.now()}.${ext}`)
        await uploadBytes(r, decoded.blob, { contentType: decoded.contentType })
        coverImage = await getDownloadURL(r)
      }
      const page: Row = {
        title: title.trim(), description: description.trim(), content, coverImage, formEnabled, formTitle: formTitle.trim(), formButtonText: buttonText.trim(),
        formFields: JSON.parse(JSON.stringify(fields)), updatedAt: serverTimestamp(), updatedByUid: user.uid,
      }
      if (!isEditing) {
        page.createdAt = serverTimestamp()
        page.createdByUid = user.uid
      }
      await setDoc(docRef, page, { merge: true })
      toast(isEditing ? 'Page updated' : 'Page created', { actionLabel: 'Copy Link', onAction: () => { navigator.clipboard?.writeText(`${window.location.origin}/page/${clean}`); toast('Link copied to clipboard') } })
      navigate(-1)
    } catch (e: any) {
      toast(`Error saving: ${e?.message ?? e}`)
    } finally {
      setSaving(false)
    }
  }

  const updateField = (i: number, k: string, v: any) => setFields((l) => l.map((f, idx) => (idx === i ? { ...f, [k]: v } : f)))

  return (
    <div style={{ minHeight: '100vh', background: 'var(--bg)' }}>
      <div className="plan-topbar" style={{ position: 'sticky', top: 0, zIndex: 5 }}>
        <button className="icon-btn" title="Back" onClick={() => navigate(-1)}><MdArrowBack size={22} /></button>
        <span className="grow" style={{ fontSize: 20, fontWeight: 500 }}>{isEditing ? 'Edit Unlisted Page' : 'Create Unlisted Page'}</span>
        {slug && <button className="icon-btn" title="Copy Link" onClick={copyLink}><MdLink size={22} /></button>}
        <Button variant="text" disabled={saving} onClick={() => void save()}>{saving ? <Spinner size="sm" /> : 'Save'}</Button>
      </div>
      <div style={{ maxWidth: 860, margin: '0 auto', padding: 16 }}>
        <div onClick={async () => { const d = await pickImageDataUrl(1600); if (d) setCover(d) }} style={{ height: 180, borderRadius: 12, background: cover ? `center / cover no-repeat url(${cover})` : '#eee', cursor: 'pointer', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', color: '#9e9e9e' }}>
          {!cover && <><MdAddPhotoAlternate size={48} /><div style={{ marginTop: 8, color: '#757575' }}>Add Cover Image</div></>}
        </div>

        <SoftCard padding={16} style={{ marginTop: 24 }}>
          <h3 style={{ margin: '0 0 16px', fontSize: 18 }}>Page Settings</h3>
          <div className="col gap-md">
            <div className="field"><label>Page Title *</label><input className={errors.title ? 'input error' : 'input'} placeholder="e.g., Boy Scouts Bikepacking Trip 2026" value={title} onChange={(e) => setTitle(e.target.value)} />{errors.title && <div className="form-error">{errors.title}</div>}</div>
            <div className="field">
              <label>Page ID (URL slug) *</label>
              <div className="row gap-sm" style={{ alignItems: 'center' }}>
                <span className="muted">/page/</span>
                <input className={errors.slug ? 'input error' : 'input'} placeholder="e.g., scouts-bikepack-2026" value={slug} disabled={isEditing} onChange={(e) => setSlug(e.target.value)} />
                {!isEditing && <button className="icon-btn" title="Generate new ID" onClick={() => setSlug(generateSlug())}><MdRefresh size={20} /></button>}
              </div>
              <div className="muted" style={{ fontSize: 12 }}>This will be part of the shareable link</div>
              {errors.slug && <div className="form-error">{errors.slug}</div>}
            </div>
            <div className="field"><label>Short Description</label><textarea className="textarea" rows={2} placeholder="A brief summary of this page" value={description} onChange={(e) => setDescription(e.target.value)} /></div>
          </div>
        </SoftCard>

        <SoftCard padding={16} style={{ marginTop: 16 }}>
          <h3 style={{ margin: 0, fontSize: 18 }}>Page Content</h3>
          <div className="muted" style={{ fontSize: 12, margin: '8px 0 16px' }}>Use ## for headings, ### for subheadings, and - for bullet points</div>
          <textarea className="textarea" rows={12} placeholder={'## Trip Details\n\nWe will be biking through...\n\n### What to Bring\n- Bike\n- Helmet\n- Camping gear'} value={content} onChange={(e) => setContent(e.target.value)} />
        </SoftCard>

        <SoftCard padding={16} style={{ marginTop: 16 }}>
          <div className="row">
            <div className="grow"><h3 style={{ margin: 0, fontSize: 18 }}>Sign-up Form</h3><div className="muted" style={{ fontSize: 12 }}>Collect responses from visitors</div></div>
            <input type="checkbox" role="switch" checked={formEnabled} onChange={(e) => setFormEnabled(e.target.checked)} style={{ width: 22, height: 22 }} />
          </div>
          {formEnabled && (
            <>
              <div className="row gap-md" style={{ marginTop: 16 }}>
                <div className="field grow"><label>Form Title</label><input className="input" placeholder="Sign Up" value={formTitle} onChange={(e) => setFormTitle(e.target.value)} /></div>
                <div className="field grow"><label>Button Text</label><input className="input" placeholder="Submit" value={buttonText} onChange={(e) => setButtonText(e.target.value)} /></div>
              </div>
              <div style={{ fontWeight: 600, margin: '20px 0 12px' }}>Form Fields</div>
              {fields.map((f, i) => <FieldEditor key={String(f.id ?? i)} field={f} onUpdate={(k, v) => updateField(i, k, v)} onRemove={() => setFields((l) => l.filter((_x, k) => k !== i))} />)}
              <Button variant="outlined" icon={<MdAdd size={18} />} onClick={() => setFields((l) => [...l, { id: `field_${Date.now()}`, label: '', type: 'text', required: false, hint: '', options: [] }])}>Add Field</Button>
            </>
          )}
        </SoftCard>
      </div>
    </div>
  )
}

/** `/admin/pages/new` and `/admin/pages/:slug/edit` */
export default function UnlistedPageBuilderRoute() {
  const { slug } = useParams()
  const state = (useLocation().state ?? {}) as { data?: Row }
  const [data, setData] = useState<Row | null>(state.data ?? null)
  const [error, setError] = useState('')
  useEffect(() => {
    if (!slug || data) return
    getDoc(doc(db, 'unlistedPages', slug)).then((s) => (s.exists() ? setData(s.data()) : setError('Page not found'))).catch((e) => setError(e?.message ?? 'Failed to load page'))
  }, [slug, data])
  if (slug && !data) return <div className="center" style={{ height: '100vh' }}>{error || <Spinner />}</div>
  return <Builder key={slug ?? 'new'} existingId={slug} existing={data ?? undefined} />
}
