import { useEffect, useMemo, useState } from 'react'
import { collection, doc, getDoc, onSnapshot, orderBy, query } from 'firebase/firestore'
import { format } from 'date-fns'
import { jsPDF } from 'jspdf'
import { useLocation, useNavigate, useParams } from 'react-router-dom'
import { MdArrowBack, MdChevronRight, MdEmail, MdInbox, MdPictureAsPdf } from 'react-icons/md'
import { db } from '@/firebase'
import { useFeedback } from '@/context/Feedback'
import { Button, CenteredSpinner, SoftCard } from '@/components/ui'

type Row = Record<string, any>
interface FieldInfo { label: string; type: string; order: number }

const META_KEYS = new Set(['submittedAt', 'submittedByUid', 'submittedByEmail', 'submittedByName', 'responses', 'formattedResponses'])
const BIG = 1 << 30
const toDate = (raw: any): Date | null => (raw && typeof raw.toDate === 'function' ? raw.toDate() : raw instanceof Date ? raw : null)
const looksLikeFieldId = (v: string) => /^(field_|fld_)/.test(v.trim().toLowerCase())

function cleanFieldId(value: string): string {
  let out = value
  if (out.startsWith('field_')) out = out.slice('field_'.length)
  out = out.replace(/[_-]+/g, ' ').trim().replace(/\d+$/, '').trim()
  return out ? out.split(' ').filter(Boolean).map((p) => p[0].toUpperCase() + p.slice(1)).join(' ') : ''
}

function resolveLabel(map: Record<string, FieldInfo> | null, fieldId: string | null, fallbackLabel: string | null, fallbackIndex: number): string {
  if (fieldId && map?.[fieldId]?.label?.trim()) return map[fieldId].label.trim()
  const label = (fallbackLabel ?? '').trim()
  if (label) {
    if (map?.[label]?.label?.trim()) return map[label].label.trim()
    if (!looksLikeFieldId(label)) return label
    const cleaned = cleanFieldId(label)
    if (cleaned) return cleaned
  }
  if (fieldId) {
    const cleaned = cleanFieldId(fieldId)
    if (cleaned) return cleaned
  }
  return `Field ${fallbackIndex + 1}`
}
const resolveType = (map: Record<string, FieldInfo> | null, fieldId: string | null, fallback: string | null) =>
  (fieldId && map?.[fieldId]?.type?.trim()) || (fallback ?? '').trim() || 'text'

/** Rows of {label,type,value} for a stored response, supporting new and legacy shapes. */
function formattedResponses(data: Row, map: Record<string, FieldInfo> | null): { label: string; type: string; value: any }[] {
  const rows: { label: string; type: string; value: any; order: number; fallback: number }[] = []
  if (Array.isArray(data.formattedResponses)) {
    data.formattedResponses.forEach((item: any, i: number) => {
      if (!item || typeof item !== 'object') return
      const rawLabel = item.label != null ? String(item.label) : null
      let fieldId: string | null = String(item.fieldId ?? item.id ?? item.key ?? '') || null
      if (!fieldId && rawLabel && map && rawLabel in map) fieldId = rawLabel
      rows.push({
        label: resolveLabel(map, fieldId, rawLabel, i), type: resolveType(map, fieldId, item.type != null ? String(item.type) : null),
        value: item.value, order: (fieldId ? map?.[fieldId]?.order : undefined) ?? BIG, fallback: i,
      })
    })
  }
  if (!rows.length) {
    const raw: Row = data.responses && typeof data.responses === 'object' ? data.responses : data
    Object.entries(raw).filter(([k]) => !META_KEYS.has(k)).forEach(([k, v], i) => {
      rows.push({ label: resolveLabel(map, k, k, i), type: resolveType(map, k, null), value: v, order: map?.[k]?.order ?? BIG, fallback: i })
    })
  }
  rows.sort((a, b) => a.order - b.order || a.fallback - b.fallback)
  return rows.map(({ label, type, value }) => ({ label, type, value }))
}

const isAnswered = (v: any): boolean => {
  if (v == null) return false
  if (typeof v === 'string') return !!v.trim()
  if (Array.isArray(v)) return v.length > 0
  if (typeof v === 'object') return Object.values(v).some((x) => x != null && String(x).trim())
  return true
}

function displayValue(value: any): string {
  if (value == null) return '(not answered)'
  if (Array.isArray(value)) return value.length ? value.map(String).join(', ') : '(none selected)'
  if (typeof value === 'object') {
    if (typeof value.toDate === 'function') return format(value.toDate(), 'MMM dd, yyyy • h:mm a')
    if ('street' in value || 'city' in value) {
      const parts: string[] = []
      if (String(value.street ?? '')) parts.push(String(value.street))
      if (String(value.street2 ?? '')) parts.push(String(value.street2))
      const cityLine = [value.city, value.province, value.postal].map((x) => String(x ?? '')).filter(Boolean)
      if (cityLine.length) parts.push(cityLine.join(', '))
      return parts.length ? parts.join('\n') : '(not provided)'
    }
    if ('url' in value && value.fileName) return `${value.fileName}\n${value.url}`
    const entries = Object.entries(value).filter(([, v]) => String(v ?? '')).map(([k, v]) => `${k[0].toUpperCase()}${k.slice(1)}: ${v}`)
    return entries.length ? entries.join('\n') : '(not provided)'
  }
  if (typeof value === 'boolean') return value ? 'Yes' : 'No'
  const s = String(value)
  return s.trim() ? s : '(not answered)'
}

function ResponseCard({ data, index, map }: { data: Row; index: number; map: Record<string, FieldInfo> | null }) {
  const [open, setOpen] = useState(false)
  const submittedAt = toDate(data.submittedAt)
  const name = data.submittedByName ? String(data.submittedByName) : null
  const email = data.submittedByEmail ? String(data.submittedByEmail) : null
  const rows = useMemo(() => formattedResponses(data, map), [data, map])
  const answered = rows.filter((r) => isAnswered(r.value)).length
  return (
    <SoftCard padding={0} radius={14} elevated style={{ marginBottom: 16, overflow: 'hidden' }}>
      <div className="row" style={{ gap: 12, padding: '8px 16px', cursor: 'pointer', minHeight: 64 }} onClick={() => setOpen((o) => !o)}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: '#00B894', color: '#fff', fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{index}</div>
        <div className="grow"><div style={{ fontWeight: 600 }}>{name ?? email ?? 'Anonymous'}</div><div className="muted" style={{ fontSize: 13 }}>{submittedAt ? format(submittedAt, 'MMM dd, yyyy • h:mm a') : 'Date unknown'} • {answered}/{rows.length} answered</div></div>
        <MdChevronRight size={22} style={{ transform: open ? 'rotate(90deg)' : undefined, transition: 'transform 0.15s' }} />
      </div>
      {open && (
        <div style={{ padding: '0 16px 16px' }}>
          <hr className="divider" style={{ margin: '0 0 16px' }} />
          {email && (
            <div className="row" style={{ gap: 10, padding: 10, marginBottom: 14, borderRadius: 10, background: '#fafafa', border: '1px solid #eee', alignItems: 'flex-start' }}>
              <div style={{ width: 30, height: 30, borderRadius: 8, background: '#eee', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><MdEmail size={17} /></div>
              <div><div style={{ fontSize: 12, color: '#757575', fontWeight: 600 }}>Email</div><div style={{ fontSize: 14, userSelect: 'text' }}>{email}</div></div>
            </div>
          )}
          {rows.length ? (
            <>
              <div style={{ fontSize: 16, fontWeight: 700, marginBottom: 10 }}>Form Responses</div>
              {rows.map((r, i) => {
                const text = displayValue(r.value)
                const empty = text === '(not answered)' || text === '(not provided)' || text === '(none selected)'
                return (
                  <div key={i} style={{ marginBottom: 10, padding: 12, borderRadius: 10, background: empty ? '#f5f5f5' : '#fafafa', border: `1px solid ${empty ? '#e0e0e0' : '#eee'}` }}>
                    <div style={{ fontSize: 13, fontWeight: 700, color: empty ? '#757575' : '#00695C' }}>{r.label}</div>
                    <div style={{ marginTop: 6, fontSize: 14, lineHeight: 1.45, whiteSpace: 'pre-wrap', userSelect: 'text', color: empty ? '#9e9e9e' : '#212121', fontStyle: empty ? 'italic' : 'normal', wordBreak: 'break-word' }}>{text}</div>
                  </div>
                )
              })}
            </>
          ) : <div style={{ color: '#9e9e9e', fontStyle: 'italic' }}>No form data available</div>}
        </div>
      )}
    </SoftCard>
  )
}

function exportPdf(title: string, responses: { id: string; data: Row }[], map: Record<string, FieldInfo> | null) {
  const pdf = new jsPDF({ unit: 'pt', format: 'a4' })
  const W = pdf.internal.pageSize.getWidth()
  const H = pdf.internal.pageSize.getHeight()
  const M = 48
  let y = M
  const ensure = (h: number) => { if (y + h > H - M) { pdf.addPage(); y = M } }
  const text = (s: string, size: number, opts: { bold?: boolean; color?: [number, number, number]; indent?: number } = {}) => {
    pdf.setFont('helvetica', opts.bold ? 'bold' : 'normal')
    pdf.setFontSize(size)
    pdf.setTextColor(...(opts.color ?? [20, 20, 20]))
    const lines = pdf.splitTextToSize(s, W - M * 2 - (opts.indent ?? 0)) as string[]
    for (const line of lines) { ensure(size * 1.35); pdf.text(line, M + (opts.indent ?? 0), y + size); y += size * 1.35 }
  }

  text('Form Responses Report', 24, { bold: true })
  y += 6
  text(title, 18)
  y += 4
  text(`Generated: ${format(new Date(), 'MMMM dd, yyyy • h:mm a')}`, 12, { color: [120, 120, 120] })
  text(`Total Responses: ${responses.length}`, 12, { color: [120, 120, 120] })
  pdf.setDrawColor(150); pdf.setLineWidth(1.5); pdf.line(M, y + 6, W - M, y + 6)

  responses.forEach(({ data }, i) => {
    pdf.addPage(); y = M
    const when = toDate(data.submittedAt)
    pdf.setFillColor(224, 242, 241); pdf.roundedRect(M, y, W - M * 2, 32, 6, 6, 'F')
    pdf.setFont('helvetica', 'bold'); pdf.setFontSize(16); pdf.setTextColor(20, 20, 20); pdf.text(`Response #${i + 1}`, M + 12, y + 21)
    pdf.setFont('helvetica', 'normal'); pdf.setFontSize(11); pdf.text(when ? format(when, 'MMM dd, yyyy • h:mm a') : 'Date unknown', W - M - 12, y + 21, { align: 'right' })
    y += 44
    const name = data.submittedByName ? String(data.submittedByName) : null
    const email = data.submittedByEmail ? String(data.submittedByEmail) : null
    if (name || email) text(`Submitted by: ${name ?? email ?? 'Anonymous'}`, 12)
    if (name && email) text(`Email: ${email}`, 11, { color: [120, 120, 120] })
    y += 8
    for (const r of formattedResponses(data, map)) {
      const raw = displayValue(r.value)
      const answered = raw !== '(not answered)' && raw !== '(not provided)' && raw !== '(none selected)'
      text(r.label, 11, { bold: true, color: [0, 105, 92] })
      text(answered ? raw : '(not answered)', 12, { color: answered ? [20, 20, 20] : [140, 140, 140], indent: 8 })
      y += 8
    }
  })

  pdf.save(`${title.replace(/[^\w\s]/g, '_')}_responses.pdf`)
}

/** `/admin/pages/:slug/responses` */
export default function UnlistedPageResponsesScreen() {
  const { slug = '' } = useParams()
  const navigate = useNavigate()
  const { toast } = useFeedback()
  const state = (useLocation().state ?? {}) as { title?: string }
  const [pageTitle, setPageTitle] = useState(state.title ?? slug)
  const [map, setMap] = useState<Record<string, FieldInfo> | null>(null)
  const [resp, setResp] = useState<{ docs: { id: string; data: Row }[]; error: Error | null; loading: boolean }>({ docs: [], error: null, loading: true })

  useEffect(() => {
    getDoc(doc(db, 'unlistedPages', slug)).then((s) => {
      if (!s.exists()) return
      const d = s.data()
      if (!state.title && d.title) setPageTitle(String(d.title))
      const m: Record<string, FieldInfo> = {}
      ;(Array.isArray(d.formFields) ? d.formFields : []).forEach((f: any, i: number) => {
        const id = String(f?.id ?? '')
        if (id) m[id] = { label: String(f.label ?? 'Unlabeled Field'), type: String(f.type ?? 'text'), order: i }
      })
      setMap(m)
    }).catch(() => undefined)
    return onSnapshot(query(collection(db, 'unlistedPages', slug, 'responses'), orderBy('submittedAt', 'desc')),
      (s) => setResp({ docs: s.docs.map((d) => ({ id: d.id, data: d.data() })), error: null, loading: false }),
      (error) => setResp({ docs: [], error, loading: false }))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [slug])

  const doExport = () => (resp.docs.length ? exportPdf(pageTitle, resp.docs, map) : toast('No responses to export'))

  return (
    <div style={{ minHeight: '100vh', background: 'var(--bg)' }}>
      <div className="plan-topbar" style={{ position: 'sticky', top: 0, zIndex: 5 }}>
        <button className="icon-btn" title="Back" onClick={() => navigate(-1)}><MdArrowBack size={22} /></button>
        <span className="grow ellipsis" style={{ fontSize: 20, fontWeight: 500 }}>Responses: {pageTitle}</span>
        <button className="icon-btn" title="Export to PDF" onClick={doExport}><MdPictureAsPdf size={22} /></button>
      </div>
      {resp.error ? <div className="center" style={{ padding: 24 }}>Error: {resp.error.message}</div>
        : resp.loading ? <CenteredSpinner pad={80} />
        : resp.docs.length === 0 ? <div className="center col gap-sm" style={{ padding: 60, color: '#9e9e9e' }}><MdInbox size={64} /><div style={{ fontSize: 18 }}>No responses yet</div></div>
        : (
          <>
            <div className="row" style={{ padding: 16, background: '#f5f5f5' }}>
              <b style={{ fontSize: 16 }}>{resp.docs.length} response{resp.docs.length === 1 ? '' : 's'}</b>
              <span className="grow" />
              <Button variant="solid" size="sm" style={{ background: '#00B894' }} icon={<MdPictureAsPdf size={18} />} onClick={doExport}>Export All to PDF</Button>
            </div>
            <div style={{ maxWidth: 900, margin: '0 auto', padding: 16 }}>
              {resp.docs.map((d, i) => <ResponseCard key={d.id} data={d.data} index={i + 1} map={map} />)}
            </div>
          </>
        )}
    </div>
  )
}
