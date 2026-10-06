import { useEffect, useMemo, useRef, useState } from 'react'
import { addDoc, collection, doc, getDoc, onSnapshot, orderBy, query, serverTimestamp, Timestamp } from 'firebase/firestore'
import { MdSend } from 'react-icons/md'
import { auth, db } from '@/firebase'
import { Dialog } from './Dialog'
import { Button, Spinner } from './ui'
import { ensureNameCache } from '@/services/nameLookup'
import { useFeedback } from '@/context/Feedback'

interface Props {
  open: boolean
  onClose: () => void
  /** Trip document path, e.g. `users/{uid}/trips/{id}`. */
  tripRefPath: string
  title?: string
  allowImageUrl?: boolean
}

const formatTime = (dt: Date) => `${dt.getHours() % 12 === 0 ? 12 : dt.getHours() % 12}:${String(dt.getMinutes()).padStart(2, '0')} ${dt.getHours() >= 12 ? 'PM' : 'AM'}`
const formatDate = (dt: Date) => `${dt.getMonth() + 1}/${dt.getDate()}/${dt.getFullYear()}`

function Bubble({ isMe, name, text, imageUrl, createdAt }: { isMe: boolean; name: string; text: string; imageUrl: string; createdAt: Date | null }) {
  const now = new Date()
  const ts = createdAt
    ? createdAt.toDateString() === now.toDateString()
      ? formatTime(createdAt)
      : `${formatDate(createdAt)}  ${formatTime(createdAt)}`
    : ''
  return (
    <div style={{ display: 'flex', justifyContent: isMe ? 'flex-end' : 'flex-start', padding: '6px 0' }}>
      <div
        style={{
          maxWidth: 420, background: isMe ? 'var(--primary)' : '#e5e7eb', color: isMe ? '#fff' : '#212121', padding: '10px 12px 8px',
          borderRadius: `14px 14px ${isMe ? '4px' : '14px'} ${isMe ? '14px' : '4px'}`,
        }}
      >
        <div style={{ fontSize: 12, fontWeight: 600, color: isMe ? 'rgba(255,255,255,.7)' : 'rgba(0,0,0,.54)', textAlign: isMe ? 'right' : 'left' }}>{name}</div>
        {text && <div style={{ marginTop: 6, whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>{text}</div>}
        {imageUrl && <img src={imageUrl} alt="" style={{ marginTop: 8, width: 240, maxWidth: '100%', borderRadius: 10 }} onError={(e) => { (e.currentTarget as HTMLImageElement).replaceWith(document.createTextNode('Image failed to load')) }} />}
        {ts && <div style={{ marginTop: 6, fontSize: 11, color: isMe ? 'rgba(255,255,255,.7)' : 'rgba(0,0,0,.45)', textAlign: isMe ? 'right' : 'left' }}>{ts}</div>}
      </div>
    </div>
  )
}

export default function TripChatDialog({ open, onClose, tripRefPath, title = 'Trip chat', allowImageUrl = false }: Props) {
  const me = auth.currentUser
  const { toast } = useFeedback()
  const [participants, setParticipants] = useState<string[]>([])
  const [names, setNames] = useState<Record<string, string>>({})
  const [messages, setMessages] = useState<{ id: string; data: Record<string, any> }[] | null>(null)
  const [expenses, setExpenses] = useState<Record<string, any>[]>([])
  const [packing, setPacking] = useState<Record<string, any>[]>([])
  const [text, setText] = useState('')
  const [img, setImg] = useState('')
  const [caret, setCaret] = useState(0)
  const inputRef = useRef<HTMLTextAreaElement>(null)
  const listRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open || !me) return
    ;(async () => {
      const parts = new Set<string>()
      const p = tripRefPath.split('/')
      if (p.length >= 2 && p[0] === 'users') parts.add(p[1])
      parts.add(me.uid)
      try {
        const snap = await getDoc(doc(db, tripRefPath))
        for (const s of (snap.data()?.sharedWith as any[]) ?? []) parts.add(String(s))
      } catch { /* ignore */ }
      const list = [...parts]
      const cache: Record<string, string> = {}
      await ensureNameCache(cache, list, me.uid)
      setParticipants(list)
      setNames((n) => ({ ...n, ...cache }))
    })()
    const unsubs = [
      onSnapshot(query(collection(db, tripRefPath, 'messages'), orderBy('createdAt', 'desc')), (s) => setMessages(s.docs.map((d) => ({ id: d.id, data: d.data() }))), () => setMessages([])),
      onSnapshot(query(collection(db, tripRefPath, 'expenses'), orderBy('createdAt', 'desc')), (s) => setExpenses(s.docs.map((d) => d.data())), () => {}),
      onSnapshot(query(collection(db, tripRefPath, 'packing'), orderBy('createdAt', 'desc')), (s) => setPacking(s.docs.map((d) => d.data())), () => {}),
    ]
    return () => unsubs.forEach((u) => u())
  }, [open, tripRefPath, me?.uid])

  // Resolve sender names for the visible messages.
  useEffect(() => {
    if (!messages || !me) return
    const uids = [...new Set(messages.map((m) => String(m.data.senderUid ?? '')).filter(Boolean))]
    const missing = uids.filter((u) => !(u in names))
    if (!missing.length) return
    const cache = { ...names }
    ensureNameCache(cache, missing, me.uid).then(() => setNames(cache))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [messages])

  const mentionSuggestions = useMemo(() => {
    const before = text.slice(0, caret)
    const token = before.slice(Math.max(before.lastIndexOf(' '), before.lastIndexOf('\n')) + 1)
    const q = token.slice(1).toLowerCase()
    const filt = (items: { label: string; insert: string }[]) => items.filter((i) => !q || i.label.toLowerCase().includes(q))
    if (token.startsWith('@')) return filt(participants.map((u) => ({ label: names[u] ?? u, insert: `@${names[u] ?? u}` })))
    if (token.startsWith('$')) return filt(expenses.map((e) => ({ label: String(e.title ?? ''), insert: `$${String(e.title ?? '')}` })))
    if (token.startsWith('%')) return filt(packing.map((p) => ({ label: String(p.name ?? ''), insert: `%${String(p.name ?? '')}` })))
    return []
  }, [text, caret, participants, names, expenses, packing])

  const insertMention = (insert: string) => {
    const before = text.slice(0, caret)
    const after = text.slice(caret)
    const start = Math.max(before.lastIndexOf(' '), before.lastIndexOf('\n')) + 1
    const next = `${before.slice(0, start)}${insert} ${after}`
    setText(next)
    const pos = start + insert.length + 1
    setCaret(pos)
    setTimeout(() => { inputRef.current?.focus(); inputRef.current?.setSelectionRange(pos, pos) }, 0)
  }

  const send = async () => {
    if (!me) return
    const t = text.trim()
    const i = img.trim()
    if (!t && (!allowImageUrl || !i)) return
    try {
      const cache = { ...names }
      await ensureNameCache(cache, [me.uid], me.uid)
      await addDoc(collection(db, tripRefPath, 'messages'), {
        senderUid: me.uid, senderName: cache[me.uid] ?? me.displayName ?? '', text: t,
        ...(allowImageUrl && i ? { imageUrl: i } : {}), createdAt: serverTimestamp(),
      })
      setText('')
      setImg('')
    } catch (e: any) {
      toast(`Send failed: ${e?.message ?? e}`)
    }
  }

  return (
    <Dialog open={open} onClose={onClose} title={title} actions={<Button variant="text" onClick={onClose}>Close</Button>} contentStyle={{ height: 'min(620px, 75vh)', display: 'flex', flexDirection: 'column' }}>
      <div ref={listRef} style={{ flex: 1, overflowY: 'auto', display: 'flex', flexDirection: 'column-reverse', padding: '8px 6px' }}>
        {!messages ? <div className="center" style={{ padding: 24 }}><Spinner /></div> : messages.length === 0 ? <div className="center muted" style={{ padding: 24 }}>No messages yet</div> : (
          messages.map(({ id, data }) => {
            const senderUid = String(data.senderUid ?? '')
            const isMe = senderUid === me?.uid
            const display = isMe ? 'You' : names[senderUid] ?? (String(data.senderName ?? '') || senderUid)
            return <Bubble key={id} isMe={isMe} name={display} text={String(data.text ?? '')} imageUrl={String(data.imageUrl ?? '')} createdAt={data.createdAt instanceof Timestamp ? data.createdAt.toDate() : null} />
          })
        )}
      </div>
      <div style={{ marginTop: 10 }}>
        <div className="row gap-sm">
          <textarea
            ref={inputRef} className="textarea" rows={1} placeholder="Message" value={text} style={{ minHeight: 40, padding: '10px 12px' }}
            onChange={(e) => { setText(e.target.value); setCaret(e.target.selectionStart) }}
            onSelect={(e) => setCaret((e.target as HTMLTextAreaElement).selectionStart)}
            onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); void send() } }}
          />
          <button type="button" className="icon-btn" title="Send" onClick={send}><MdSend size={22} /></button>
        </div>
        {mentionSuggestions.length > 0 && (
          <div style={{ marginTop: 6, maxHeight: 180, overflowY: 'auto', background: '#fff', border: '1px solid #d1d5db', borderRadius: 8, boxShadow: '0 0 8px rgba(0,0,0,.06)' }}>
            {mentionSuggestions.map((m, i) => (
              <button key={i} type="button" className="menu-item" onClick={() => insertMention(m.insert)}>{m.label}</button>
            ))}
          </div>
        )}
        <div className="t-body-s" style={{ marginTop: 6, color: 'rgba(0,0,0,.54)' }}>Tip: use @ to mention people, $ for expenses, % for packing.</div>
        {allowImageUrl && <input className="input" style={{ marginTop: 8 }} placeholder="Image URL (optional)" value={img} onChange={(e) => setImg(e.target.value)} />}
      </div>
    </Dialog>
  )
}
