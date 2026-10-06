export interface BudgetPerson {
  id: string
  name: string
  uid?: string | null
}

export const isLinkedUser = (p: BudgetPerson) => !!p.uid && p.uid.trim().length > 0

export const newCustomPersonId = () => `person_${Date.now()}${Math.floor(Math.random() * 1000)}`

export function budgetPersonFromMap(data: Record<string, any>): BudgetPerson {
  const rawUid = String(data.uid ?? data.linkedUid ?? '').trim()
  const rawName = String(data.name ?? data.label ?? data.title ?? '').trim()
  const rawId = String(data.id ?? '').trim()
  const id = rawId || rawUid || newCustomPersonId()
  return { id, name: rawName || rawUid || 'Person', uid: rawUid || null }
}

export function budgetPersonToMap(p: BudgetPerson): Record<string, any> {
  return { id: p.id, name: p.name, ...(p.uid && p.uid.trim() ? { uid: p.uid } : {}) }
}

export function customBudgetPerson(name: string, id?: string): BudgetPerson {
  const trimmed = name.trim()
  return { id: (id ?? '').trim() || newCustomPersonId(), name: trimmed || 'Person' }
}

export function parseBudgetPeople(raw: unknown): BudgetPerson[] {
  if (!Array.isArray(raw)) return []
  const seen = new Set<string>()
  const people: BudgetPerson[] = []
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue
    const p = budgetPersonFromMap(item as Record<string, any>)
    if (!p.id.trim() || seen.has(p.id)) continue
    seen.add(p.id)
    people.push(p)
  }
  return people
}

export function encodeBudgetPeople(people: Iterable<BudgetPerson>): Record<string, any>[] {
  const seen = new Set<string>()
  const out: Record<string, any>[] = []
  for (const p of people) {
    const id = p.id.trim()
    const name = p.name.trim()
    if (!id || !name || seen.has(id)) continue
    seen.add(id)
    out.push(budgetPersonToMap({ id, name, uid: p.uid?.trim() ? p.uid.trim() : null }))
  }
  return out
}

export function mergeBudgetPeople(opts: {
  participantUids: Iterable<string>
  nameCache: Record<string, string>
  customPeople?: Iterable<BudgetPerson>
}): BudgetPerson[] {
  const merged: BudgetPerson[] = []
  const seen = new Set<string>()
  for (const uid of opts.participantUids) {
    const t = uid.trim()
    if (!t || seen.has(t)) continue
    seen.add(t)
    merged.push({ id: t, name: (opts.nameCache[t] ?? t).trim(), uid: t })
  }
  for (const p of opts.customPeople ?? []) {
    if (!p.id.trim() || seen.has(p.id)) continue
    seen.add(p.id)
    merged.push(p)
  }
  return merged
}

export function budgetPersonById(people: Iterable<BudgetPerson>, id?: string | null): BudgetPerson | null {
  const t = (id ?? '').trim()
  if (!t) return null
  for (const p of people) if (p.id === t) return p
  return null
}

export function budgetPersonLabelForId(opts: {
  people: Iterable<BudgetPerson>
  id?: string | null
  fallbackName?: string
  emptyLabel?: string
}): string {
  const t = (opts.id ?? '').trim()
  if (!t) return opts.emptyLabel ?? 'Unassigned'
  const p = budgetPersonById(opts.people, t)
  if (p && p.name.trim()) return p.name.trim()
  const fb = (opts.fallbackName ?? '').trim()
  return fb || t
}
