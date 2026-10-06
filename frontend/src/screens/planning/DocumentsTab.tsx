import { useState } from 'react'
import { MdAdd, MdAttachFile, MdDeleteOutline, MdEditNote, MdFolderOpen, MdLink, MdOpenInNew, MdUploadFile } from 'react-icons/md'
import { getDownloadURL, ref, uploadBytes } from 'firebase/storage'
import { storage } from '@/firebase'
import { Dialog } from '@/components/Dialog'
import { Button, SoftCard } from '@/components/ui'
import { openExternalUrl } from '@/services/openExternalUrl'
import { DOCUMENT_CATEGORIES, DOC_CATEGORY_EMOJIS, documentAttachmentsFor, formatBytes, newId, sanitizeFileName, type Row } from '@/lib/planning'

interface Props {
  tripId: string
  documents: Row[]
  onChange: (next: Row[]) => void
  notify: (m: string) => void
}

function DocumentDialog({ tripId, existing, onClose, onSave, notify }: { tripId: string; existing: Row | null; onClose: () => void; onSave: (entry: Row) => void; notify: (m: string) => void }) {
  const [title, setTitle] = useState(String(existing?.title ?? ''))
  const [content, setContent] = useState(String(existing?.content ?? ''))
  const [category, setCategory] = useState(String(existing?.category ?? 'Other'))
  const [attachments, setAttachments] = useState<Row[]>(existing ? documentAttachmentsFor(existing) : [])
  const [uploading, setUploading] = useState(false)

  const upload = () => {
    const input = document.createElement('input')
    input.type = 'file'
    input.accept = '.pdf,.png,.jpg,.jpeg,.webp,.txt,.doc,.docx,.xls,.xlsx,.csv,.rtf'
    input.onchange = async () => {
      const file = input.files?.[0]
      if (!file) return
      setUploading(true)
      try {
        const storagePath = `tripDocuments/${tripId}/${Date.now()}_${sanitizeFileName(file.name)}`
        const r = ref(storage, storagePath)
        const contentType = file.type || 'application/octet-stream'
        await uploadBytes(r, file, { contentType, customMetadata: { tripId, originalName: file.name } })
        const url = await getDownloadURL(r)
        setAttachments((a) => [...a, { fileName: file.name, url, contentType, sizeBytes: file.size, storagePath, uploadedAt: new Date().toISOString() }])
      } catch (e: any) {
        notify(`Upload failed: ${e?.message ?? e}`)
      } finally {
        setUploading(false)
      }
    }
    input.click()
  }

  return (
    <Dialog
      onClose={onClose}
      title={existing ? 'Edit Document' : 'Add Document'}
      actions={
        <>
          <Button variant="text" onClick={onClose}>Cancel</Button>
          <Button
            variant="solid"
            onClick={() => {
              if (!title.trim()) return notify('Please enter a title')
              const entry: Row = { id: existing?.id ?? newId(), title: title.trim(), content: content.trim(), category }
              if (attachments.length) {
                entry.attachments = attachments
                entry.attachment = attachments[0]
              }
              onSave(entry)
            }}
          >
            Save
          </Button>
        </>
      }
    >
      <div className="col gap-md">
        <div className="field"><label>Title</label><input className="input" value={title} onChange={(e) => setTitle(e.target.value)} autoFocus /></div>
        <div className="field">
          <label>Category</label>
          <select className="select" value={DOCUMENT_CATEGORIES.includes(category) ? category : 'Other'} onChange={(e) => setCategory(e.target.value)}>
            {DOCUMENT_CATEGORIES.map((c) => <option key={c} value={c}>{DOC_CATEGORY_EMOJIS[c] ?? '📄'} {c}</option>)}
          </select>
        </div>
        <div className="field"><label>Details</label><textarea className="textarea" rows={6} placeholder="Confirmation numbers, addresses, phone numbers…" value={content} onChange={(e) => setContent(e.target.value)} /></div>
        <div style={{ padding: 10, borderRadius: 8, border: '1px solid rgba(0,0,0,0.12)', background: 'var(--surface-variant)' }}>
          <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 8 }}>{attachments.length === 1 ? 'Attachment' : 'Attachments'}</div>
          {attachments.length ? (
            <div className="col gap-xs" style={{ maxHeight: 160, overflowY: 'auto' }}>
              {attachments.map((a, i) => (
                <div key={i} className="row" style={{ alignItems: 'center', gap: 6, padding: '8px 10px', borderRadius: 8, background: '#fff', border: '1px solid rgba(0,0,0,0.1)' }}>
                  <MdAttachFile size={15} />
                  <div className="grow" style={{ minWidth: 0 }}>
                    <div className="ellipsis" style={{ fontSize: 12, fontWeight: 600 }}>{String(a.fileName ?? 'Attachment')}</div>
                    <div className="faint" style={{ fontSize: 11 }}>{formatBytes(Number(a.sizeBytes) || 0)}</div>
                  </div>
                  <button className="icon-btn" title="Remove" onClick={() => setAttachments((l) => l.filter((_x, k) => k !== i))}>✕</button>
                </div>
              ))}
            </div>
          ) : <div className="faint" style={{ fontSize: 12 }}>No files attached</div>}
          <div style={{ marginTop: 6 }}>
            <Button variant="outlined" size="sm" loading={uploading} icon={<MdUploadFile size={18} />} onClick={upload}>
              {uploading ? 'Uploading…' : attachments.length === 0 ? 'Upload file' : 'Add another file'}
            </Button>
          </div>
        </div>
      </div>
    </Dialog>
  )
}

export default function DocumentsTab({ tripId, documents, onChange, notify }: Props) {
  const [dialog, setDialog] = useState<{ index: number | null; existing: Row | null } | null>(null)

  const open = (url: string) => {
    if (!url.trim()) return
    if (!openExternalUrl(url.trim(), { sameTab: true })) notify('Could not open this attachment.')
  }
  const copy = async (url: string) => {
    try {
      await navigator.clipboard.writeText(url)
      notify('Attachment link copied')
    } catch {
      /* clipboard unavailable */
    }
  }

  return (
    <div className="plan-scroll">
      <div className="row" style={{ alignItems: 'center', padding: '16px 0 8px' }}>
        <b style={{ fontSize: 16 }}>Documents &amp; Info</b>
        <span className="grow" />
        <Button variant="solid" size="sm" icon={<MdAdd size={16} />} onClick={() => setDialog({ index: null, existing: null })}>Add</Button>
      </div>

      {documents.length === 0 ? (
        <div className="center col gap-sm faint" style={{ padding: 40, textAlign: 'center' }}>
          <MdFolderOpen size={48} />
          <div>No documents yet.<br />Store flight info, hotel confirmations,<br />emergency contacts, and more.</div>
        </div>
      ) : (
        <div style={{ paddingBottom: 80 }}>
          {documents.map((doc, index) => {
            const cat = String(doc.category ?? 'Other')
            const attachments = documentAttachmentsFor(doc)
            return (
              <SoftCard key={String(doc.id ?? index)} padding={14} radius={12} style={{ marginBottom: 8 }}>
                <div className="row" style={{ alignItems: 'center', gap: 8 }}>
                  <span style={{ fontSize: 20 }}>{DOC_CATEGORY_EMOJIS[cat] ?? '📄'}</span>
                  <div className="grow">
                    <div style={{ fontWeight: 600, fontSize: 14 }}>{String(doc.title ?? 'Untitled')}</div>
                    <div className="faint" style={{ fontSize: 11 }}>{cat}</div>
                  </div>
                  <button className="icon-btn" title="Edit" onClick={() => setDialog({ index, existing: doc })}><MdEditNote size={20} /></button>
                  <button className="icon-btn" title="Delete" onClick={() => onChange(documents.filter((_d, i) => i !== index))}><MdDeleteOutline size={18} color="var(--error)" /></button>
                </div>
                {String(doc.content ?? '') && (
                  <div style={{ marginTop: 8, padding: 10, borderRadius: 8, background: 'var(--surface-variant)', fontSize: 13, whiteSpace: 'pre-wrap', userSelect: 'text' }} className="muted">{String(doc.content)}</div>
                )}
                {attachments.length > 0 && (
                  <div style={{ marginTop: 8, padding: 10, borderRadius: 8, background: 'rgba(74,173,232,0.08)', border: '1px solid rgba(74,173,232,0.2)' }}>
                    <div className="row" style={{ alignItems: 'center', gap: 6, fontSize: 12, fontWeight: 700 }}><MdAttachFile size={16} /> {attachments.length === 1 ? '1 attachment' : `${attachments.length} attachments`}</div>
                    {attachments.map((a, i) => (
                      <div key={i} style={{ marginTop: 8, paddingTop: i ? 8 : 0, borderTop: i ? '1px solid rgba(74,173,232,0.14)' : undefined }}>
                        <div className="row" style={{ gap: 8 }}>
                          <span className="grow ellipsis" style={{ fontSize: 12, fontWeight: 600 }}>{String(a.fileName ?? 'Attachment')}</span>
                          <span className="faint" style={{ fontSize: 11 }}>{formatBytes(Number(a.sizeBytes) || 0)}</span>
                        </div>
                        <div className="row wrap gap-sm" style={{ marginTop: 4 }}>
                          <Button variant="text" size="sm" icon={<MdOpenInNew size={14} />} onClick={() => open(String(a.url))}>Open</Button>
                          <Button variant="text" size="sm" icon={<MdLink size={14} />} onClick={() => void copy(String(a.url))}>Copy link</Button>
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </SoftCard>
            )
          })}
        </div>
      )}

      {dialog && (
        <DocumentDialog
          tripId={tripId} existing={dialog.existing} notify={notify} onClose={() => setDialog(null)}
          onSave={(entry) => {
            onChange(dialog.index != null && dialog.index < documents.length ? documents.map((d, i) => (i === dialog.index ? entry : d)) : [...documents, entry])
            setDialog(null)
          }}
        />
      )}
    </div>
  )
}
