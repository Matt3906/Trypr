import { useState } from 'react'
import { MdAdd, MdAddCircleOutline, MdClose, MdDeleteOutline } from 'react-icons/md'
import { Button, SoftCard } from '@/components/ui'
import { mapList } from '@/lib/tripDetail'
import { newId, type Row } from '@/lib/planning'

function AddItemField({ onAdd }: { onAdd: (text: string) => void }) {
  const [text, setText] = useState('')
  const submit = () => {
    const t = text.trim()
    if (!t) return
    onAdd(t)
    setText('')
  }
  return (
    <div className="row" style={{ alignItems: 'center', paddingLeft: 36 }}>
      <input className="plan-ghost-input" style={{ fontSize: 13 }} placeholder="Add item…" value={text} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && submit()} />
      <button className="icon-btn" title="Add item" onClick={submit}><MdAddCircleOutline size={18} /></button>
    </div>
  )
}

export default function ChecklistsTab({ checklists, onChange }: { checklists: Row[]; onChange: (next: Row[]) => void }) {
  const patchList = (i: number, patch: Row) => onChange(checklists.map((c, k) => (k === i ? { ...c, ...patch } : c)))
  const setItems = (i: number, items: Row[]) => patchList(i, { items })

  return (
    <div className="plan-scroll">
      <div className="row" style={{ alignItems: 'center', padding: '16px 0 8px' }}>
        <b style={{ fontSize: 16 }}>Checklists</b>
        <span className="grow" />
        <Button variant="solid" size="sm" icon={<MdAdd size={16} />} onClick={() => onChange([...checklists, { id: newId(), title: 'New List', items: [] }])}>New List</Button>
      </div>
      {checklists.length === 0 ? (
        <div className="faint" style={{ textAlign: 'center', padding: 24 }}>No checklists yet.</div>
      ) : (
        <div style={{ paddingBottom: 80 }}>
          {checklists.map((cl, li) => {
            const items = mapList(cl.items)
            const done = items.filter((it) => it.done === true).length
            return (
              <SoftCard key={String(cl.id ?? li)} padding={14} radius={12} style={{ marginBottom: 12 }}>
                <div className="row" style={{ alignItems: 'center', gap: 4 }}>
                  <input className="plan-ghost-input" style={{ fontWeight: 700, fontSize: 15 }} value={String(cl.title ?? '')} onChange={(e) => patchList(li, { title: e.target.value })} />
                  <span className="faint" style={{ fontSize: 12, whiteSpace: 'nowrap' }}>{done} / {items.length}</span>
                  <button className="icon-btn" title="Delete list" onClick={() => onChange(checklists.filter((_c, k) => k !== li))}><MdDeleteOutline size={18} /></button>
                </div>
                {items.length > 0 && (
                  <div style={{ height: 4, borderRadius: 4, background: 'var(--surface-variant)', margin: '4px 0 8px', overflow: 'hidden' }}>
                    <div style={{ width: `${(done / items.length) * 100}%`, height: '100%', background: '#16a34a', transition: 'width 0.2s' }} />
                  </div>
                )}
                {items.map((item, ii) => {
                  const isDone = item.done === true
                  return (
                    <div key={String(item.id ?? ii)} className="row" style={{ alignItems: 'center', gap: 8, padding: '2px 0' }}>
                      <input type="checkbox" checked={isDone} onChange={(e) => setItems(li, items.map((it, k) => (k === ii ? { ...it, done: e.target.checked } : it)))} />
                      <input
                        className="plan-ghost-input"
                        style={{ fontSize: 13, textDecoration: isDone ? 'line-through' : undefined, color: isDone ? 'var(--text-3)' : undefined }}
                        value={String(item.text ?? '')}
                        onChange={(e) => setItems(li, items.map((it, k) => (k === ii ? { ...it, text: e.target.value } : it)))}
                      />
                      <button className="icon-btn" title="Remove item" onClick={() => setItems(li, items.filter((_it, k) => k !== ii))}><MdClose size={14} /></button>
                    </div>
                  )
                })}
                <AddItemField onAdd={(text) => setItems(li, [...items, { id: newId(), text, done: false }])} />
              </SoftCard>
            )
          })}
        </div>
      )}
    </div>
  )
}
