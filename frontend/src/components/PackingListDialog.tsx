import { useEffect, useState } from 'react'
import { addDoc, arrayRemove, arrayUnion, collection, onSnapshot, orderBy, query, serverTimestamp, updateDoc, doc } from 'firebase/firestore'
import { MdPersonOutline } from 'react-icons/md'
import { auth, db } from '@/firebase'
import { Dialog } from './Dialog'
import { Button, cx, Spinner } from './ui'
import { ensureNameCache } from '@/services/nameLookup'
import { useFeedback } from '@/context/Feedback'

export function emojiForPackingItem(raw: string): string {
  const name = raw.trim().toLowerCase()
  if (!name) return '🎒'
  const has = (...k: string[]) => k.some((x) => name.includes(x))
  if (has('underwear', 'brief')) return '🩲'
  if (has('sock')) return '🧦'
  if (has('shoe', 'boot')) return '👟'
  if (has('jacket', 'coat')) return '🧥'
  if (has('hat', 'cap')) return '🧢'
  if (has('shirt', 'tee', 't-shirt')) return '👕'
  if (has('pants', 'jeans', 'short')) return '👖'
  if (has('dress')) return '👗'
  if (has('swim', 'bikini')) return '👙'
  if (has('tooth')) return '🪥'
  if (has('soap', 'shampoo')) return '🧴'
  if (has('sunscreen', 'sun screen')) return '🧴'
  if (has('phone', 'charger', 'cable')) return '🔌'
  if (has('camera')) return '📷'
  if (has('passport')) return '🛂'
  if (has('ticket', 'boarding')) return '🎫'
  if (has('water', 'bottle')) return '💧'
  if (has('snack', 'food')) return '🥪'
  if (has('med', 'pill', 'first aid')) return '💊'
  if (has('laptop', 'tablet')) return '💻'
  if (has('map')) return '🗺️'
  if (has('tent')) return '⛺'
  if (has('sleeping bag')) return '🛌'
  return '🎒'
}

interface Props {
  open: boolean
  onClose: () => void
  tripRefPath: string
  participants: string[]
}

export default function PackingListDialog({ open, onClose, tripRefPath, participants }: Props) {
  const me = auth.currentUser
  const { toast } = useFeedback()
  const [items, setItems] = useState<{ id: string; data: Record<string, any> }[] | null>(null)
  const [names, setNames] = useState<Record<string, string>>({})
  const [scope, setScope] = useState<'group' | 'private'>('group')
  const [text, setText] = useState('')
  const [qty, setQty] = useState('1')
  const [assignee, setAssignee] = useState('')
  const [assigning, setAssigning] = useState<{ id: string; current: string } | null>(null)
  const [assignSel, setAssignSel] = useState('')

  useEffect(() => {
    if (!open) return
    const cache: Record<string, string> = {}
    if (me) ensureNameCache(cache, participants, me.uid).then(() => setNames(cache))
    return onSnapshot(
      query(collection(db, tripRefPath, 'packing'), orderBy('createdAt')),
      (s) => setItems(s.docs.map((d) => ({ id: d.id, data: d.data() }))),
      () => setItems([]),
    )
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, tripRefPath])

  if (!me) return null
  const visible = (items ?? []).filter(({ data }) => (scope === 'group' ? data.privateTo == null : data.privateTo != null && data.privateTo === me.uid))

  const add = async () => {
    const t = text.trim()
    if (!t) return
    const q = parseInt(qty.trim(), 10)
    const data: Record<string, any> = { name: t, emoji: emojiForPackingItem(t), createdAt: serverTimestamp(), checkedBy: [] }
    if (Number.isFinite(q) && q > 1) data.quantity = q
    if (scope === 'private') data.privateTo = me.uid
    if (assignee) {
      data.assigneeUid = assignee
      data.assigneeName = names[assignee] ?? assignee
    }
    try {
      await addDoc(collection(db, tripRefPath, 'packing'), data)
      setText('')
      setQty('1')
      setAssignee('')
    } catch (e: any) {
      toast(`Could not add item: ${e?.message ?? e}`)
    }
  }

  const toggle = (id: string, checked: boolean) =>
    updateDoc(doc(db, tripRefPath, 'packing', id), { checkedBy: checked ? arrayUnion(me.uid) : arrayRemove(me.uid) }).catch((e) => toast(`Update failed: ${e?.message ?? e}`))

  return (
    <>
      <Dialog open={open} onClose={onClose} title="Packing list" actions={<Button variant="text" onClick={onClose}>Close</Button>} contentStyle={{ height: 'min(620px, 80vh)', display: 'flex', flexDirection: 'column' }}>
        <div className="row gap-sm">
          <button className={cx('chip', scope === 'group' && 'selected')} onClick={() => setScope('group')}>Group</button>
          <button className={cx('chip', scope === 'private' && 'selected')} onClick={() => setScope('private')}>Private</button>
          <span className="grow" />
          <span>Participants: {participants.length}</span>
        </div>
        <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', marginTop: 8 }}>
          {!items ? <div className="center" style={{ padding: 24 }}><Spinner /></div> : visible.length === 0 ? <div className="center muted" style={{ padding: 24 }}>No packing items</div> : (
            visible.map(({ id, data }) => {
              const name = String(data.name ?? '')
              const emoji = String(data.emoji ?? '') || emojiForPackingItem(name)
              const q = typeof data.quantity === 'number' ? data.quantity : parseInt(String(data.quantity ?? ''), 10) || 1
              const checked = (Array.isArray(data.checkedBy) ? data.checkedBy : []).includes(me.uid)
              const asg = String(data.assigneeUid ?? '')
              const asgName = asg ? names[asg] ?? asg : ''
              const canEdit = scope === 'group' || String(data.privateTo ?? '') === me.uid
              return (
                <div key={id} style={{ padding: '8px 0', borderTop: '1px solid var(--border)' }}>
                  <label className="row gap-md" style={{ cursor: 'pointer' }}>
                    <input type="checkbox" checked={checked} onChange={(e) => void toggle(id, e.target.checked)} />
                    <span style={{ fontSize: 18 }}>{emoji}</span>
                    <span className="grow">{name}</span>
                    {q > 1 && <span className="chip">x{q}</span>}
                    {asgName && <span className="chip">{asgName}</span>}
                  </label>
                  {canEdit && (
                    <div style={{ marginLeft: 28 }}>
                      <button className="btn btn-text btn-sm" onClick={() => { setAssigning({ id, current: asg }); setAssignSel(asg) }}>
                        <MdPersonOutline size={18} />{asgName ? `Assigned: ${asgName}` : 'Assign'}
                      </button>
                    </div>
                  )}
                </div>
              )
            })
          )}
        </div>
        <div className="row wrap gap-sm" style={{ marginTop: 8 }}>
          <input className="input" style={{ flex: 1, minWidth: 140 }} placeholder="Add item" value={text} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && void add()} />
          <input className="input" style={{ width: 80 }} placeholder="Qty" inputMode="numeric" value={qty} onChange={(e) => setQty(e.target.value)} />
          <select className="select" style={{ width: 150 }} value={assignee} onChange={(e) => setAssignee(e.target.value)}>
            <option value="">Unassigned</option>
            {participants.map((u) => <option key={u} value={u}>{names[u] ?? u}</option>)}
          </select>
          <Button variant="solid" onClick={add}>Add</Button>
        </div>
      </Dialog>
      <Dialog
        open={!!assigning} onClose={() => setAssigning(null)} title="Assign item"
        actions={
          <>
            <Button variant="text" onClick={() => setAssigning(null)}>Cancel</Button>
            <Button variant="text" onClick={async () => {
              if (assigning) await updateDoc(doc(db, tripRefPath, 'packing', assigning.id), { assigneeUid: assignSel }).catch(() => {})
              setAssigning(null)
            }}>Save</Button>
          </>
        }
      >
        <select className="select" value={assignSel} onChange={(e) => setAssignSel(e.target.value)}>
          <option value="">Unassigned</option>
          {participants.map((u) => <option key={u} value={u}>{names[u] ?? u}</option>)}
        </select>
      </Dialog>
    </>
  )
}
