import { useState } from 'react'
import { MdAdd, MdAddCircleOutline, MdClose, MdDeleteOutline, MdOutlineRemoveCircleOutline, MdPersonAddAlt1 } from 'react-icons/md'
import { Button, SoftCard } from '@/components/ui'
import { customBudgetPerson, type BudgetPerson } from '@/models/budgetPerson'
import { BUDGET_CATEGORIES, CURRENCIES, budgetPeopleForItem, currencySymbol, newId, type Row } from '@/lib/planning'
import { budgetPersonById } from '@/models/budgetPerson'

export interface BudgetState {
  currency: string
  items: Row[]
  people: BudgetPerson[]
  finalSplitByCount: number
}

export interface BudgetTabProps {
  budget: BudgetState
  resolvedSplitCount: number
  onChange: (next: BudgetState) => void
  notify: (m: string) => void
}

const numStr = (n: unknown) => {
  if (n == null) return ''
  if (typeof n === 'number') return n === 0 ? '' : String(Number.isInteger(n) ? n : Number(n.toFixed(2)))
  return String(n)
}

function SummaryCell({ label, value, color, symbol }: { label: string; value: number; color?: string; symbol: string }) {
  return (
    <div style={{ textAlign: 'center' }}>
      <div className="faint" style={{ fontSize: 11 }}>{label}</div>
      <div style={{ fontWeight: 700, fontSize: 16, color }}>{symbol}{value.toFixed(2)}</div>
    </div>
  )
}

function Pill({ label, value }: { label: string; value: string }) {
  return (
    <div style={{ padding: '10px 12px', borderRadius: 12, background: '#fff', border: '1px solid rgba(0,0,0,0.07)' }}>
      <div className="faint" style={{ fontSize: 11 }}>{label}</div>
      <div style={{ fontWeight: 700, marginTop: 3 }}>{value}</div>
    </div>
  )
}

export default function BudgetTab({ budget, resolvedSplitCount, onChange, notify }: BudgetTabProps) {
  const [personName, setPersonName] = useState('')
  const sym = currencySymbol(budget.currency)
  const totalEstimated = budget.items.reduce((t, i) => t + (Number(i.estimated) || 0), 0)
  const totalActual = budget.items.reduce((t, i) => t + (Number(i.actual) || 0), 0)
  const diff = totalEstimated - totalActual

  const setItem = (index: number, patch: Row) => onChange({ ...budget, items: budget.items.map((it, i) => (i === index ? { ...it, ...patch } : it)) })
  const removeItemKey = (index: number, ...keys: string[]) =>
    onChange({ ...budget, items: budget.items.map((it, i) => { if (i !== index) return it; const n = { ...it }; keys.forEach((k) => delete n[k]); return n }) })

  const addPerson = () => {
    const name = personName.trim()
    if (!name) return
    if (budget.people.some((p) => p.name.trim().toLowerCase() === name.toLowerCase())) return notify('That person already exists')
    onChange({ ...budget, people: [...budget.people, customBudgetPerson(name)] })
    setPersonName('')
  }

  return (
    <div className="plan-scroll">
      <div className="row" style={{ alignItems: 'center', gap: 8, padding: '16px 0 8px' }}>
        <b style={{ fontSize: 16 }}>Trip Budget</b>
        <span className="grow" />
        <select className="select" style={{ width: 'auto' }} value={budget.currency} onChange={(e) => onChange({ ...budget, currency: e.target.value })}>
          {CURRENCIES.map((c) => <option key={c}>{c}</option>)}
        </select>
        <Button variant="solid" size="sm" icon={<MdAdd size={16} />} onClick={() => onChange({ ...budget, items: [...budget.items, { id: newId(), description: '', category: 'Other', estimated: 0, actual: 0, notes: '' }] })}>
          Add Item
        </Button>
      </div>

      <SoftCard padding={12} radius={10}>
        <div className="row" style={{ justifyContent: 'space-around' }}>
          <SummaryCell label="Estimated" value={totalEstimated} symbol={sym} />
          <SummaryCell label="Actual" value={totalActual} symbol={sym} />
          <SummaryCell label={diff >= 0 ? 'Under budget' : 'Over budget'} value={Math.abs(diff)} symbol={sym} color={diff >= 0 ? 'var(--success, #16a34a)' : 'var(--error)'} />
        </div>
      </SoftCard>

      <SoftCard padding={12} radius={10} style={{ marginTop: 8 }}>
        <div className="row" style={{ alignItems: 'center', gap: 8 }}>
          <b style={{ fontSize: 14 }}>People</b>
          <span className="faint" style={{ fontSize: 12 }}>{budget.people.length} saved</span>
        </div>
        <div className="faint" style={{ fontSize: 12, margin: '4px 0 10px' }}>
          Create people here, then assign who paid. The final split is calculated once in the summary at the end.
        </div>
        {budget.people.length === 0 ? (
          <div className="faint" style={{ fontSize: 12 }}>No people added yet.</div>
        ) : (
          <div className="row wrap gap-sm">
            {budget.people.map((p) => (
              <span key={p.id} className="chip" style={{ gap: 6 }}>
                {p.name}
                <button className="icon-btn" style={{ width: 18, height: 18 }} title={`Remove ${p.name}`} onClick={() => onChange({ ...budget, people: budget.people.filter((x) => x.id !== p.id) })}><MdClose size={14} /></button>
              </span>
            ))}
          </div>
        )}
        <div className="row gap-sm" style={{ marginTop: 10 }}>
          <input className="input" placeholder="Add a person" value={personName} onChange={(e) => setPersonName(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && addPerson()} />
          <Button variant="solid" size="sm" icon={<MdPersonAddAlt1 size={16} />} onClick={addPerson}>Add Person</Button>
        </div>
      </SoftCard>

      <div style={{ marginTop: 8, paddingBottom: 80 }}>
        {budget.items.length === 0 ? (
          <div className="faint" style={{ textAlign: 'center', padding: 24 }}>No budget items yet.<br />Tap "Add Item" to start.</div>
        ) : (
          <>
            {budget.items.map((item, index) => {
              const itemPeople = budgetPeopleForItem(item, budget.people)
              const paidById = String(item.paidByPersonId ?? '').trim()
              return (
                <SoftCard key={String(item.id ?? index)} padding={10} radius={10} style={{ marginBottom: 8 }}>
                  <div className="row gap-sm">
                    <input className="input" placeholder="Description" value={String(item.description ?? '')} onChange={(e) => setItem(index, { description: e.target.value })} />
                    <Button variant="text" size="sm" style={{ color: 'var(--error)' }} icon={<MdDeleteOutline size={18} />} onClick={() => onChange({ ...budget, items: budget.items.filter((_it, i) => i !== index) })}>Delete</Button>
                  </div>
                  <div className="row wrap gap-sm" style={{ marginTop: 8, alignItems: 'flex-end' }}>
                    <div className="field" style={{ width: 180 }}>
                      <label>Category</label>
                      <select className="select" value={BUDGET_CATEGORIES.includes(String(item.category)) ? String(item.category) : 'Other'} onChange={(e) => setItem(index, { category: e.target.value })}>
                        {BUDGET_CATEGORIES.map((c) => <option key={c}>{c}</option>)}
                      </select>
                    </div>
                    <div className="field" style={{ width: 220 }}>
                      <label>Paid by</label>
                      <select
                        className="select" value={paidById}
                        onChange={(e) => {
                          const next = e.target.value.trim()
                          if (!next) return removeItemKey(index, 'paidByPersonId', 'paidByPersonName')
                          setItem(index, { paidByPersonId: next, paidByPersonName: budgetPersonById(itemPeople, next)?.name ?? '' })
                        }}
                      >
                        <option value="">Unassigned</option>
                        {itemPeople.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                      </select>
                    </div>
                    <div className="field" style={{ width: 110 }}>
                      <label>Estimated</label>
                      <input className="input" inputMode="decimal" value={numStr(item.estimated)} onChange={(e) => setItem(index, { estimated: parseFloat(e.target.value) || 0 })} />
                    </div>
                    <div className="field" style={{ width: 110 }}>
                      <label>Actual</label>
                      <input className="input" inputMode="decimal" value={numStr(item.actual)} onChange={(e) => setItem(index, { actual: parseFloat(e.target.value) || 0 })} />
                    </div>
                  </div>
                  <input className="plan-ghost-input faint" style={{ fontSize: 12, marginTop: 6 }} placeholder="Notes…" value={String(item.notes ?? '')} onChange={(e) => setItem(index, { notes: e.target.value })} />
                </SoftCard>
              )
            })}

            <SoftCard padding={12} radius={10}>
              <b style={{ fontSize: 14 }}>Final summary</b>
              <div className="faint" style={{ fontSize: 12, margin: '6px 0 10px' }}>Apply the split once here after all expenses are entered.</div>
              <div className="row" style={{ alignItems: 'center', gap: 6 }}>
                <span style={{ fontWeight: 600 }}>Split total by</span>
                <button className="icon-btn" disabled={resolvedSplitCount <= 1} onClick={() => onChange({ ...budget, finalSplitByCount: resolvedSplitCount - 1 })}><MdOutlineRemoveCircleOutline size={24} /></button>
                <span style={{ minWidth: 44, textAlign: 'center', padding: '8px 10px', borderRadius: 999, background: '#fff', border: '1px solid rgba(0,0,0,0.08)', fontWeight: 700 }}>{resolvedSplitCount}</span>
                <button className="icon-btn" onClick={() => onChange({ ...budget, finalSplitByCount: resolvedSplitCount + 1 })}><MdAddCircleOutline size={24} /></button>
                <span className="grow" />
                <span className="faint" style={{ fontSize: 12 }}>{budget.people.length} people saved</span>
              </div>
              <div className="row wrap gap-sm" style={{ marginTop: 10 }}>
                <Pill label="Each estimated" value={`${sym}${(resolvedSplitCount <= 0 ? 0 : totalEstimated / resolvedSplitCount).toFixed(2)}`} />
                <Pill label="Each actual" value={`${sym}${(resolvedSplitCount <= 0 ? 0 : totalActual / resolvedSplitCount).toFixed(2)}`} />
              </div>
            </SoftCard>
          </>
        )}
      </div>
    </div>
  )
}
