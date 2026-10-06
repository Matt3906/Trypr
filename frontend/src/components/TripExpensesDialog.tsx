import { useEffect, useMemo, useState } from 'react'
import { addDoc, collection, deleteDoc, deleteField, doc, onSnapshot, orderBy, query, Timestamp, updateDoc } from 'firebase/firestore'
import { MdAdd, MdAddCircleOutline, MdDeleteOutline, MdPersonAddAlt1, MdPieChartOutline, MdRemoveCircleOutline, MdClose } from 'react-icons/md'
import { db } from '@/firebase'
import { Dialog } from './Dialog'
import { Button, cx, Spinner } from './ui'
import { useFeedback } from '@/context/Feedback'
import { ensureNameCache } from '@/services/nameLookup'
import {
  budgetPersonById, budgetPersonLabelForId, customBudgetPerson, encodeBudgetPeople, mergeBudgetPeople, parseBudgetPeople, type BudgetPerson,
} from '@/models/budgetPerson'

const CATEGORIES = ['Accommodation', 'Food', 'Transport', 'Activities', 'Groceries', 'Shopping', 'Other']
const PALETTE = ['#4e79a7', '#f28e2b', '#e15759', '#76b7b2', '#59a14f', '#edc948', '#b07aa1', '#ff9da7', '#9c755f', '#bab0ac']

type ExpenseDoc = { id: string; data: Record<string, any> }

const two = (v: number) => String(v).padStart(2, '0')
const fmtWhen = (d: Date) => `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}`
const expenseDate = (d: Record<string, any>) => (d.createdAt instanceof Timestamp ? d.createdAt.toDate() : null)
const paidById = (d: Record<string, any>) => {
  const pid = String(d.paidByPersonId ?? '').trim()
  if (pid) return pid
  const uid = String(d.paidByUid ?? '').trim()
  return uid || null
}
const paidByName = (d: Record<string, any>) => String(d.paidByPersonName ?? '').trim()

function resolveFinalSplitCount(raw: unknown, people: BudgetPerson[]): number {
  const n = typeof raw === 'number' ? Math.round(raw) : parseInt(String(raw ?? ''), 10)
  return Number.isFinite(n) && n > 0 ? n : Math.max(1, people.length)
}

function resolvedPaidBy(people: BudgetPerson[], selectedId: string | null, currentUid: string): string | null {
  const sel = (selectedId ?? '').trim()
  if (sel && budgetPersonById(people, sel)) return sel
  if (currentUid.trim() && budgetPersonById(people, currentUid)) return currentUid
  return null
}

function peopleForSelection(people: BudgetPerson[], selectedId: string | null, fallbackName?: string): BudgetPerson[] {
  const sel = (selectedId ?? '').trim()
  if (!sel || budgetPersonById(people, sel)) return people
  return [...people, customBudgetPerson((fallbackName ?? '').trim() || sel, sel)]
}

function PieChart({ segments }: { segments: { label: string; value: number }[] }) {
  const nonZero = segments.filter((s) => s.value > 0)
  const total = nonZero.reduce((a, s) => a + s.value, 0)
  if (!nonZero.length || total <= 0) return <div className="center muted" style={{ height: '100%' }}>No data</div>
  let start = -Math.PI / 2
  const r = 100
  return (
    <svg viewBox="-100 -100 200 200" width="100%" height="100%">
      {nonZero.length === 1 ? (
        <circle r={r} fill={PALETTE[0]} />
      ) : (
        nonZero.map((s, i) => {
          const sweep = (s.value / total) * Math.PI * 2
          const x1 = r * Math.cos(start), y1 = r * Math.sin(start)
          const end = start + sweep
          const x2 = r * Math.cos(end), y2 = r * Math.sin(end)
          const d = `M0 0 L${x1} ${y1} A${r} ${r} 0 ${sweep > Math.PI ? 1 : 0} 1 ${x2} ${y2} Z`
          start = end
          return <path key={s.label + i} d={d} fill={PALETTE[i % PALETTE.length]}><title>{s.label}</title></path>
        })
      )}
    </svg>
  )
}

function FinalSplitCard({ count, total, each, onDec, onInc }: { count: number; total: number; each: number; onDec?: () => void; onInc: () => void }) {
  return (
    <div style={{ padding: 12, background: '#f8fafc', borderRadius: 12, border: '1px solid rgba(0,0,0,.08)' }}>
      <div className="semibold">Final split</div>
      <div className="row gap-sm" style={{ marginTop: 8 }}>
        <span>Split total by</span>
        <button className="icon-btn" disabled={!onDec} onClick={onDec} title="Decrease"><MdRemoveCircleOutline size={20} /></button>
        <span style={{ minWidth: 42, textAlign: 'center', padding: '7px 10px', background: '#fff', borderRadius: 999, border: '1px solid rgba(0,0,0,.08)', fontWeight: 700 }}>{count}</span>
        <button className="icon-btn" onClick={onInc} title="Increase"><MdAddCircleOutline size={20} /></button>
      </div>
      <div className="muted" style={{ fontSize: 12, fontWeight: 600, marginTop: 6 }}>Total {total.toFixed(2)} • Each {each.toFixed(2)}</div>
    </div>
  )
}

interface Props {
  open: boolean
  onClose: () => void
  tripRefPath: string
  currentUid: string
  participants: string[]
}

export default function TripExpensesDialog({ open, onClose, tripRefPath, currentUid, participants }: Props) {
  const { toast, confirm } = useFeedback()
  const [names, setNames] = useState<Record<string, string>>({})
  const [tripData, setTripData] = useState<Record<string, any>>({})
  const [expenses, setExpenses] = useState<ExpenseDoc[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)

  const [viewMode, setViewMode] = useState<'group' | 'personal' | 'group_categories'>('group')
  const [splitMode, setSplitMode] = useState<'group' | 'personal'>('group')
  const [title, setTitle] = useState('')
  const [amount, setAmount] = useState('')
  const [personName, setPersonName] = useState('')
  const [paidBy, setPaidBy] = useState<string | null>(participants.includes(currentUid) ? currentUid : null)
  const [category, setCategory] = useState('Other')
  const [saving, setSaving] = useState(false)
  const [personSaving, setPersonSaving] = useState(false)
  const [editing, setEditing] = useState<ExpenseDoc | null>(null)

  const tripRef = useMemo(() => doc(db, tripRefPath), [tripRefPath])

  useEffect(() => {
    if (!open) return
    const cache: Record<string, string> = {}
    ensureNameCache(cache, participants, currentUid).then(() => setNames(cache))
    const u1 = onSnapshot(tripRef, (s) => setTripData(s.data() ?? {}), () => {})
    const u2 = onSnapshot(
      query(collection(db, tripRefPath, 'expenses'), orderBy('createdAt', 'desc')),
      (s) => { setExpenses(s.docs.map((d) => ({ id: d.id, data: d.data() }))); setLoadError(null) },
      (e) => setLoadError(e.message),
    )
    return () => { u1(); u2() }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, tripRefPath])

  const tripBudget = tripData.tripBudget
  const customPeople = useMemo(() => (tripBudget && typeof tripBudget === 'object' ? parseBudgetPeople(tripBudget.people) : []), [tripBudget])
  const allPeople = useMemo(() => mergeBudgetPeople({ participantUids: participants, nameCache: names, customPeople }), [participants, names, customPeople])
  const resolvedPaidByPerson = resolvedPaidBy(allPeople, paidBy, currentUid)
  const finalSplitCount = resolveFinalSplitCount(tripBudget && typeof tripBudget === 'object' ? tripBudget.finalSplitByCount : null, allPeople)

  const addCustomPerson = async () => {
    const name = personName.trim()
    if (!name || personSaving) return
    if (allPeople.some((p) => p.name.trim().toLowerCase() === name.toLowerCase())) return toast('That person already exists')
    setPersonSaving(true)
    try {
      await updateDoc(tripRef, { 'tripBudget.people': encodeBudgetPeople([...customPeople, customBudgetPerson(name)]) })
      setPersonName('')
    } catch (e: any) {
      toast(`Could not add person: ${e?.message ?? e}`)
    } finally {
      setPersonSaving(false)
    }
  }

  const removeCustomPerson = async (person: BudgetPerson) => {
    if (personSaving) return
    setPersonSaving(true)
    try {
      await updateDoc(tripRef, { 'tripBudget.people': encodeBudgetPeople(customPeople.filter((p) => p.id !== person.id)) })
      if (paidBy === person.id) setPaidBy(null)
    } catch (e: any) {
      toast(`Could not remove person: ${e?.message ?? e}`)
    } finally {
      setPersonSaving(false)
    }
  }

  const updateFinalSplit = async (n: number) => {
    try {
      await updateDoc(tripRef, { 'tripBudget.finalSplitByCount': Math.max(1, n) })
    } catch (e: any) {
      toast(`Could not update final split: ${e?.message ?? e}`)
    }
  }

  const addExpense = async () => {
    const t = title.trim()
    if (!t) return toast('Title is required')
    const parsed = parseFloat(amount.trim())
    if (!Number.isFinite(parsed) || parsed <= 0) return toast('Enter a valid amount > 0')
    const payer = budgetPersonById(allPeople, resolvedPaidByPerson)
    setSaving(true)
    try {
      const payload: Record<string, any> = { title: t, amount: parsed, splitMode, category, createdAt: Timestamp.now(), createdByUid: currentUid }
      if (payer) {
        payload.paidByPersonId = payer.id
        payload.paidByPersonName = payer.name
        if (payer.uid && payer.uid.trim()) payload.paidByUid = payer.uid
      }
      await addDoc(collection(db, tripRefPath, 'expenses'), payload)
      setTitle('')
      setAmount('')
    } catch (e: any) {
      toast(`Add failed: ${e?.message ?? e}`)
    } finally {
      setSaving(false)
    }
  }

  const deleteExpense = async (id: string): Promise<boolean> => {
    const ok = await confirm({ title: 'Delete expense?', message: 'This removes it for everyone on the trip.', confirmLabel: 'Delete' })
    if (!ok) return false
    try {
      await deleteDoc(doc(db, tripRefPath, 'expenses', id))
      return true
    } catch (e: any) {
      toast(`Delete failed: ${e?.message ?? e}`)
      return false
    }
  }

  const filtered = (expenses ?? []).filter((e) => {
    const mode = String(e.data.splitMode ?? 'group')
    return viewMode === 'personal' ? mode === 'personal' : mode !== 'personal'
  })
  const expensePeople = useMemo(() => {
    let resolved = allPeople
    for (const e of filtered) resolved = peopleForSelection(resolved, paidById(e.data), paidByName(e.data))
    return resolved
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [allPeople, expenses, viewMode])
  const totalGroup = filtered.reduce((a, e) => a + (Number(e.data.amount) || 0), 0)

  const finalSplit =
    viewMode === 'personal' ? null : (
      <FinalSplitCard count={finalSplitCount} total={totalGroup} each={finalSplitCount <= 0 ? 0 : totalGroup / finalSplitCount} onDec={finalSplitCount <= 1 ? undefined : () => updateFinalSplit(finalSplitCount - 1)} onInc={() => updateFinalSplit(finalSplitCount + 1)} />
    )

  const expenseRow = (e: ExpenseDoc, showMode: boolean) => {
    const d = e.data
    const pid = paidById(d)
    const name = budgetPersonLabelForId({ people: expensePeople, id: pid, fallbackName: paidByName(d) })
    const cat = String(d.category ?? 'Other')
    const when = expenseDate(d)
    const mode = String(d.splitMode ?? 'group')
    return (
      <div key={e.id} className="row gap-md" style={{ padding: '8px 4px', borderTop: '1px solid var(--border)', cursor: 'pointer' }} onClick={() => setEditing(e)}>
        <div className="grow">
          <div>{String(d.title ?? '')}</div>
          <div className="muted" style={{ fontSize: 12 }}>
            {showMode ? `${mode === 'personal' ? 'Personal' : 'Group'} • ` : ''}{cat || 'Other'} • Paid by {name}{when ? ` • ${fmtWhen(when)}` : ''}
          </div>
        </div>
        <span>{(Number(d.amount) || 0).toFixed(2)}</span>
        <button className="icon-btn" title="Delete" onClick={(ev) => { ev.stopPropagation(); void deleteExpense(e.id) }}><MdDeleteOutline size={20} /></button>
      </div>
    )
  }

  let body: React.ReactNode
  if (loadError) body = <div className="center">Failed to load: {loadError}</div>
  else if (!expenses) body = <div className="center" style={{ padding: 24 }}><Spinner /></div>
  else if (!expenses.length) body = <div className="center muted" style={{ padding: 24 }}>No expenses yet</div>
  else if (!filtered.length) body = <div className="center muted" style={{ padding: 24 }}>{viewMode === 'personal' ? 'No personal expenses yet' : 'No group expenses yet'}</div>
  else if (viewMode === 'group_categories') {
    const byCat = new Map<string, number>()
    for (const e of filtered) {
      const a = Number(e.data.amount) || 0
      if (a <= 0) continue
      const c = String(e.data.category ?? 'Other')
      byCat.set(c, (byCat.get(c) ?? 0) + a)
    }
    const ordered = [...byCat.entries()].sort((a, b) => b[1] - a[1])
    body = (
      <div className="exp-split">
        <div style={{ width: 220, height: 220, flex: 'none' }}><PieChart segments={ordered.map(([label, value]) => ({ label, value }))} /></div>
        <div className="grow col gap-sm">
          <div className="semibold">Group expenses by category</div>
          {finalSplit}
          <div className="row wrap" style={{ gap: 8 }}>{ordered.map(([k, v]) => <span key={k} className="chip">{k}: {v.toFixed(2)}</span>)}</div>
          <div>{filtered.map((e) => expenseRow(e, false))}</div>
        </div>
      </div>
    )
  } else {
    const totals: Record<string, number> = Object.fromEntries(expensePeople.map((p) => [p.id, 0]))
    const myByCat = new Map<string, number>()
    for (const e of filtered) {
      const a = Number(e.data.amount) || 0
      const pid = paidById(e.data)
      const cat = String(e.data.category ?? 'Other')
      if (a <= 0) continue
      if (pid) totals[pid] = (totals[pid] ?? 0) + a
      if (viewMode === 'personal') {
        if (pid === currentUid) myByCat.set(cat, (myByCat.get(cat) ?? 0) + a)
      } else if (participants.includes(currentUid)) {
        myByCat.set(cat, (myByCat.get(cat) ?? 0) + a / finalSplitCount)
      }
    }
    const totalPaid = Object.values(totals).reduce((a, b) => a + b, 0)
    const orderedPeople = [...expensePeople].sort((a, b) => (totals[b.id] ?? 0) - (totals[a.id] ?? 0))
    body = (
      <div className="exp-split">
        <div style={{ width: 220, height: 220, flex: 'none' }}><PieChart segments={orderedPeople.map((p) => ({ label: p.name, value: totals[p.id] ?? 0 }))} /></div>
        <div className="grow col gap-sm">
          <div className="semibold">{viewMode === 'personal' ? 'Personal paid breakdown' : 'Paid breakdown'}</div>
          {finalSplit}
          <div style={{ maxHeight: 94, overflowY: 'auto' }}>
            {orderedPeople.map((p) => {
              const v = totals[p.id] ?? 0
              const pct = totalPaid <= 0 ? 0 : (v / totalPaid) * 100
              return (
                <div key={p.id} style={{ marginBottom: 6 }}>
                  <div className="ellipsis semibold">{p.name}</div>
                  <div className="muted ellipsis" style={{ fontSize: 12 }}>{pct.toFixed(0)}% • {v.toFixed(2)}</div>
                </div>
              )
            })}
          </div>
          {myByCat.size > 0 && (
            <>
              <div className="semibold">Your breakdown</div>
              <div className="row wrap" style={{ gap: 8 }}>
                {[...myByCat.entries()].sort((a, b) => b[1] - a[1]).map(([k, v]) => <span key={k} className="chip">{k}: {v.toFixed(2)}</span>)}
              </div>
            </>
          )}
          <div>{filtered.map((e) => expenseRow(e, true))}</div>
        </div>
      </div>
    )
  }

  return (
    <>
      <Dialog open={open} onClose={onClose} size="wide" title="Expenses" actions={<Button variant="text" onClick={onClose}>Close</Button>} contentStyle={{ height: 'min(760px, 85vh)', display: 'flex', flexDirection: 'column' }}>
        <div className="row gap-sm wrap">
          <button className={cx('chip', viewMode === 'group' && 'selected')} onClick={() => { setViewMode('group'); setSplitMode('group') }}>Group split</button>
          <button className={cx('chip', viewMode === 'personal' && 'selected')} onClick={() => { setViewMode('personal'); setSplitMode('personal') }}>Personal</button>
          <button className={cx('chip', viewMode === 'group_categories' && 'selected')} onClick={() => { setViewMode('group_categories'); setSplitMode('group') }}><MdPieChartOutline size={16} />Group expenses</button>
          <span className="grow" />
          <span>People: {allPeople.length}</span>
        </div>
        {customPeople.length > 0 && (
          <div className="row wrap" style={{ gap: 8, marginTop: 10 }}>
            {customPeople.map((p) => (
              <span key={p.id} className="chip">{p.name}<button className="icon-btn" style={{ width: 20, height: 20 }} disabled={personSaving} onClick={() => removeCustomPerson(p)}><MdClose size={14} /></button></span>
            ))}
          </div>
        )}
        <div className="row gap-sm" style={{ marginTop: 8 }}>
          <input className="input" placeholder="Add person — Mom, Jake, Roommate..." value={personName} onChange={(e) => setPersonName(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && void addCustomPerson()} />
          <Button variant="solid" loading={personSaving} icon={<MdPersonAddAlt1 size={18} />} onClick={addCustomPerson}>Add person</Button>
        </div>
        <div className="row wrap gap-sm" style={{ marginTop: 10, alignItems: 'flex-end' }}>
          <input className="input" style={{ width: 240 }} placeholder="Expense — gas, hotel, tickets..." value={title} onChange={(e) => setTitle(e.target.value)} />
          <input className="input" style={{ width: 130 }} placeholder="0.00" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
          <select className="select" style={{ width: 170 }} value={resolvedPaidByPerson ?? ''} onChange={(e) => setPaidBy(e.target.value || null)} disabled={saving}>
            <option value="">Unassigned</option>
            {allPeople.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
          <select className="select" style={{ width: 150 }} value={CATEGORIES.includes(category) ? category : 'Other'} onChange={(e) => setCategory(e.target.value)} disabled={saving}>
            {CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
          </select>
          <Button variant="solid" loading={saving} icon={<MdAdd size={18} />} onClick={addExpense}>Add</Button>
        </div>
        <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', marginTop: 12 }}>{body}</div>
      </Dialog>
      {editing && <EditExpense expense={editing} people={peopleForSelection(allPeople, paidById(editing.data), paidByName(editing.data))} currentUid={currentUid} tripRefPath={tripRefPath} onClose={() => setEditing(null)} onDelete={deleteExpense} />}
    </>
  )
}

function EditExpense({ expense, people, currentUid, tripRefPath, onClose, onDelete }: { expense: ExpenseDoc; people: BudgetPerson[]; currentUid: string; tripRefPath: string; onClose: () => void; onDelete: (id: string) => Promise<boolean> }) {
  const { toast } = useFeedback()
  const d = expense.data
  const [title, setTitle] = useState(String(d.title ?? ''))
  const [amount, setAmount] = useState(String(Number(d.amount) || 0))
  const [splitMode, setSplitMode] = useState<string>(String(d.splitMode ?? 'group'))
  const [paidBy, setPaidBy] = useState<string | null>(paidById(d))
  const [category, setCategory] = useState(String(d.category ?? 'Other'))
  const [saving, setSaving] = useState(false)
  const resolved = resolvedPaidBy(people, paidBy, currentUid)

  const save = async () => {
    const t = title.trim()
    const a = parseFloat(amount.trim())
    if (!t) return toast('Title is required')
    if (!Number.isFinite(a) || a <= 0) return toast('Enter a valid amount > 0')
    const payer = budgetPersonById(people, resolved)
    setSaving(true)
    try {
      await updateDoc(doc(db, tripRefPath, 'expenses', expense.id), {
        title: t, amount: a, splitMode, splitByCount: deleteField(), category,
        ...(payer
          ? { paidByPersonId: payer.id, paidByPersonName: payer.name, paidByUid: payer.uid && payer.uid.trim() ? payer.uid : deleteField() }
          : { paidByPersonId: deleteField(), paidByPersonName: deleteField(), paidByUid: deleteField() }),
      })
      onClose()
    } catch (e: any) {
      toast(`Save failed: ${e?.message ?? e}`)
    } finally {
      setSaving(false)
    }
  }

  return (
    <Dialog
      open onClose={onClose} title="Edit expense"
      actions={
        <>
          <Button variant="text" disabled={saving} onClick={onClose}>Cancel</Button>
          <Button variant="text" disabled={saving} onClick={async () => { if (await onDelete(expense.id)) onClose() }}>Delete</Button>
          <Button variant="solid" loading={saving} onClick={save}>Save</Button>
        </>
      }
    >
      <div className="col gap-md">
        <div className="row gap-sm">
          <button className={cx('chip', splitMode === 'group' && 'selected')} disabled={saving} onClick={() => setSplitMode('group')}>Group split</button>
          <button className={cx('chip', splitMode === 'personal' && 'selected')} disabled={saving} onClick={() => setSplitMode('personal')}>Personal</button>
        </div>
        <input className="input" placeholder="Expense" value={title} onChange={(e) => setTitle(e.target.value)} />
        <input className="input" placeholder="Amount" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
        <div className="row gap-sm">
          <select className="select" value={CATEGORIES.includes(category) ? category : 'Other'} onChange={(e) => setCategory(e.target.value)} disabled={saving}>
            {CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
          </select>
          <select className="select" value={resolved ?? ''} onChange={(e) => setPaidBy(e.target.value || null)} disabled={saving}>
            <option value="">Unassigned</option>
            {people.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
        </div>
      </div>
    </Dialog>
  )
}
