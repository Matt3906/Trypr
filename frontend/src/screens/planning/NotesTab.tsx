import { useMemo, useRef } from 'react'
import ReactQuill from 'react-quill-new'
import 'react-quill-new/dist/quill.snow.css'
import { MdAdd, MdArrowBack, MdDeleteOutline, MdOutlineStickyNote2 } from 'react-icons/md'
import { getDownloadURL, ref, uploadBytes } from 'firebase/storage'
import { storage } from '@/firebase'
import { cx } from '@/components/ui'
import { NOTE_COLORS, newId, normalizeNotePlainText, parseNoteDelta, sanitizeFileName, type Row } from '@/lib/planning'

export interface NotesTabProps {
  tripId: string
  notes: Row[]
  selectedIndex: number | null
  isWide: boolean
  onSelect: (i: number | null) => void
  onAdd: () => void
  onDelete: (i: number) => void
  onPatch: (i: number, patch: Row) => void
  notify: (m: string) => void
}

function NotesList({ p }: { p: NotesTabProps }) {
  return (
    <div className="col" style={{ height: '100%', minHeight: 0 }}>
      <div className="row" style={{ alignItems: 'center', padding: '16px 16px 8px' }}>
        <b style={{ fontSize: 16 }}>Notes</b>
        <span className="grow" />
        <button className="icon-btn" title="New note" onClick={p.onAdd}><MdAdd size={22} /></button>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '0 12px' }}>
        {p.notes.length === 0 ? (
          <div className="faint" style={{ textAlign: 'center', padding: 24 }}>No notes yet.<br />Tap + to create one.</div>
        ) : (
          p.notes.map((n, i) => {
            const selected = p.selectedIndex === i
            return (
              <div
                key={String(n.id ?? i)}
                onClick={() => p.onSelect(i)}
                style={{ display: 'flex', alignItems: 'center', gap: 8, padding: 12, marginBottom: 6, borderRadius: 10, cursor: 'pointer', background: selected ? 'rgba(74,173,232,0.08)' : String(n.color ?? '#FFFFFF') }}
              >
                <MdOutlineStickyNote2 size={18} className="muted" />
                <span className="grow ellipsis" style={{ fontSize: 13, fontWeight: selected ? 600 : 500 }}>{String(n.title ?? '') || 'Untitled Note'}</span>
                <button className="icon-btn" title="Delete note" onClick={(e) => { e.stopPropagation(); p.onDelete(i) }}><MdDeleteOutline size={16} /></button>
              </div>
            )
          })
        )}
      </div>
    </div>
  )
}

function NoteEditor({ p, showBack }: { p: NotesTabProps; showBack: boolean }) {
  const idx = p.selectedIndex
  const quillRef = useRef<ReactQuill>(null)
  const note = idx != null ? p.notes[idx] : null
  const noteId = String(note?.id ?? '')

  const uploadImage = () => {
    const input = document.createElement('input')
    input.type = 'file'
    input.accept = '.png,.jpg,.jpeg,.webp,.gif,.bmp'
    input.onchange = async () => {
      const file = input.files?.[0]
      if (!file) return
      if (!file.type.startsWith('image/')) return p.notify('Please choose a valid image file.')
      try {
        const path = `tripNotes/${p.tripId}/${Date.now()}_${sanitizeFileName(file.name)}`
        const r = ref(storage, path)
        await uploadBytes(r, file, { contentType: file.type, customMetadata: { tripId: p.tripId, originalName: file.name, source: 'tripNotes' } })
        const url = await getDownloadURL(r)
        const editor = quillRef.current?.getEditor()
        if (!editor) return
        const range = editor.getSelection(true)
        editor.insertEmbed(range.index, 'image', url, 'user')
        editor.setSelection(range.index + 1, 0)
      } catch {
        p.notify('Image upload failed. Please try again.')
      }
    }
    input.click()
  }
  const uploadRef = useRef(uploadImage)
  uploadRef.current = uploadImage

  // Quill modules must be stable across renders or the editor re-initialises.
  const modules = useMemo(
    () => ({
      toolbar: {
        container: [
          [{ header: [1, 2, 3, false] }],
          ['bold', 'italic', 'underline', 'strike'],
          [{ list: 'ordered' }, { list: 'bullet' }, { list: 'check' }],
          ['link', 'image'],
          ['clean'],
        ],
        handlers: { image: () => uploadRef.current() },
      },
    }),
    [],
  )

  if (idx == null || !note) {
    return <div className="center faint" style={{ height: '100%' }}>Select a note to edit</div>
  }

  const colorHex = String(note.color ?? '#FFFFFF')
  const ops = parseNoteDelta(note.contentDelta)
  const initial = ops && ops.length ? { ops } : String(note.content ?? '')

  return (
    <div className="col" style={{ height: '100%', minHeight: 0, background: `${colorHex}4d` }}>
      <div className="row" style={{ alignItems: 'center', padding: '8px 12px' }}>
        {showBack && <button className="icon-btn" onClick={() => p.onSelect(null)}><MdArrowBack size={22} /></button>}
        <input
          className="plan-ghost-input" style={{ fontWeight: 700, fontSize: 18 }} placeholder="Note title…"
          value={String(note.title ?? '')}
          onChange={(e) => p.onPatch(idx, { title: e.target.value, updatedAt: new Date().toISOString() })}
        />
      </div>
      <div className="row" style={{ gap: 6, padding: '0 16px 8px', overflowX: 'auto' }}>
        {NOTE_COLORS.map((c) => (
          <button
            key={c} aria-label={`Note colour ${c}`}
            onClick={() => p.onPatch(idx, { color: c, updatedAt: new Date().toISOString() })}
            style={{ width: 28, height: 28, borderRadius: '50%', flex: 'none', background: c, border: `${colorHex.toLowerCase() === c.toLowerCase() ? 2.5 : 1}px solid ${colorHex.toLowerCase() === c.toLowerCase() ? 'var(--primary)' : '#d4d4d8'}` }}
          />
        ))}
      </div>
      <div className={cx('plan-quill')} style={{ flex: 1, minHeight: 0, margin: '0 16px', borderRadius: 12, background: 'rgba(255,255,255,0.82)', border: '1px solid rgba(0,0,0,0.08)', overflow: 'hidden', display: 'flex' }}>
        <ReactQuill
          key={noteId}
          ref={quillRef}
          theme="snow"
          modules={modules}
          defaultValue={initial as any}
          placeholder="Write your notes here (supports bold, italics, lists, and images)…"
          onChange={(_content, _delta, source, editor) => {
            if (source !== 'user') return
            p.onPatch(idx, {
              contentDelta: editor.getContents().ops,
              content: normalizeNotePlainText(editor.getText()),
              updatedAt: new Date().toISOString(),
            })
          }}
        />
      </div>
      <div className="muted" style={{ fontSize: 12, padding: '12px 16px' }}>
        Tip: paste images directly from clipboard when supported by your browser/device.
      </div>
    </div>
  )
}

export default function NotesTab(p: NotesTabProps) {
  if (p.isWide) {
    return (
      <div className="row" style={{ height: '100%', minHeight: 0, alignItems: 'stretch' }}>
        <div style={{ width: 260, flex: 'none', borderRight: '1px solid var(--border)' }}><NotesList p={p} /></div>
        <div className="grow" style={{ minWidth: 0 }}><NoteEditor p={p} showBack={false} /></div>
      </div>
    )
  }
  return p.selectedIndex != null ? <NoteEditor p={p} showBack /> : <NotesList p={p} />
}

export const newNote = (): Row => ({
  id: newId(), title: '', content: '', contentDelta: null, color: '#FFFFFF', createdAt: new Date().toISOString(),
})
