/**
 * Firestore-compatible client backed by the Trypr API (Postgres document store).
 * Only the subset of the Firestore Web SDK that the app uses is implemented. Listeners poll
 * (and refresh immediately after any local write) instead of holding a socket open.
 */
import { apiFetch, BackendError } from './api'
import { arrayRemove, arrayUnion, decode, deleteField, encode, increment, serverTimestamp, Timestamp } from './codec'

export { arrayRemove, arrayUnion, deleteField, increment, serverTimestamp, Timestamp }

export type DocumentData = Record<string, any>
export type Unsubscribe = () => void

export class Firestore { readonly type = 'firestore' }
export const getFirestore = () => new Firestore()

// ---- references --------------------------------------------------------------------------

function splitPath(...parts: string[]): string[] {
  return parts.flatMap((p) => p.split('/')).filter(Boolean)
}

export function autoId(): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  const bytes = crypto.getRandomValues(new Uint8Array(20))
  return Array.from(bytes, (b) => chars[b % chars.length]).join('')
}

interface Constraint { kind: 'where' | 'orderBy' | 'limit' }
type WhereOp = '==' | '!=' | '<' | '<=' | '>' | '>=' | 'in' | 'not-in' | 'array-contains' | 'array-contains-any'
class WhereConstraint implements Constraint { kind = 'where' as const; constructor(readonly field: string, readonly op: WhereOp, readonly value: unknown) {} }
class OrderByConstraint implements Constraint { kind = 'orderBy' as const; constructor(readonly field: string, readonly dir: 'asc' | 'desc') {} }
class LimitConstraint implements Constraint { kind = 'limit' as const; constructor(readonly n: number) {} }
export type QueryConstraint = WhereConstraint | OrderByConstraint | LimitConstraint
export const where = (field: string, op: WhereOp, value: unknown) => new WhereConstraint(field, op, value)
export const orderBy = (field: string, dir: 'asc' | 'desc' = 'asc') => new OrderByConstraint(field, dir)
export const limit = (n: number) => new LimitConstraint(n)

export class Query<T = DocumentData> {
  readonly type: string = 'query'
  declare readonly _t?: T
  constructor(
    readonly path: string | null,
    readonly group: string | null,
    readonly constraints: QueryConstraint[] = [],
  ) {}
}

export class CollectionReference<T = DocumentData> extends Query<T> {
  readonly type = 'collection'
  readonly path: string
  constructor(path: string) {
    super(path, null, [])
    this.path = path
  }
  get id(): string { return this.path.split('/').pop()! }
  get parent(): DocumentReference | null {
    const segs = this.path.split('/')
    return segs.length > 1 ? new DocumentReference(segs.slice(0, -1).join('/')) : null
  }
}

export class DocumentReference<T = DocumentData> {
  readonly type = 'document'
  declare readonly _t?: T
  constructor(readonly path: string) {}
  get id(): string { return this.path.split('/').pop()! }
  get parent(): CollectionReference { return new CollectionReference(this.path.split('/').slice(0, -1).join('/')) }
}

export function doc(base: Firestore | CollectionReference | DocumentReference, ...segments: string[]): DocumentReference {
  if (base instanceof Firestore) {
    const segs = splitPath(...segments)
    if (segs.length === 0 || segs.length % 2 !== 0) throw new BackendError('invalid-argument', `Invalid document path: ${segs.join('/')}`)
    return new DocumentReference(segs.join('/'))
  }
  if (base instanceof CollectionReference) {
    const segs = splitPath(...segments)
    return new DocumentReference([base.path, ...(segs.length ? segs : [autoId()])].join('/'))
  }
  const segs = splitPath(base.path, ...segments)
  if (segs.length % 2 !== 0) throw new BackendError('invalid-argument', `Invalid document path: ${segs.join('/')}`)
  return new DocumentReference(segs.join('/'))
}

export function collection(base: Firestore | DocumentReference, ...segments: string[]): CollectionReference {
  const segs = base instanceof Firestore ? splitPath(...segments) : splitPath(base.path, ...segments)
  if (segs.length % 2 !== 1) throw new BackendError('invalid-argument', `Invalid collection path: ${segs.join('/')}`)
  return new CollectionReference(segs.join('/'))
}

export const collectionGroup = (_db: Firestore, id: string) => new Query(null, id)

export function query<T>(q: Query<T>, ...constraints: QueryConstraint[]): Query<T> {
  return new Query<T>(q.path, q.group, [...q.constraints, ...constraints])
}

// ---- snapshots ---------------------------------------------------------------------------

interface WireDoc { id: string; path: string; data: any; rev: number }

export class DocumentSnapshot<T = DocumentData> {
  readonly metadata = { hasPendingWrites: false, fromCache: false }
  constructor(readonly ref: DocumentReference<T>, private readonly _data: T | undefined, readonly rev: number | null) {}
  get id(): string { return this.ref.id }
  exists(): this is QueryDocumentSnapshot<T> { return this._data !== undefined }
  data(): T | undefined { return this._data }
  get(field: string): any {
    return field.split('.').reduce<any>((o, k) => (o == null ? undefined : o[k]), this._data)
  }
}
export class QueryDocumentSnapshot<T = DocumentData> extends DocumentSnapshot<T> {
  override data(): T { return super.data() as T }
}
export class QuerySnapshot<T = DocumentData> {
  readonly metadata = { hasPendingWrites: false, fromCache: false }
  constructor(readonly docs: QueryDocumentSnapshot<T>[]) {}
  get size(): number { return this.docs.length }
  get empty(): boolean { return this.docs.length === 0 }
  forEach(cb: (d: QueryDocumentSnapshot<T>) => void) { this.docs.forEach(cb) }
}

const toDocSnap = (w: WireDoc) => new QueryDocumentSnapshot(new DocumentReference(w.path), decode(w.data), w.rev)

// ---- reads -------------------------------------------------------------------------------

async function fetchDoc(ref: DocumentReference<any>, ifRev?: number | null): Promise<DocumentSnapshot | 'unchanged'> {
  const r = await apiFetch<any>('/api/db/get', { json: { path: ref.path, ifRev: ifRev ?? undefined } })
  if (r.notModified) return 'unchanged'
  return new DocumentSnapshot(ref, r.exists ? decode(r.data) : undefined, r.exists ? r.rev : null)
}

export async function getDoc<T = DocumentData>(ref: DocumentReference<T>): Promise<DocumentSnapshot<T>> {
  return (await fetchDoc(ref)) as DocumentSnapshot<T>
}

function queryBody(q: Query, etag?: string) {
  return {
    path: q.path ?? undefined,
    group: q.group ?? undefined,
    where: q.constraints.filter((c): c is WhereConstraint => c.kind === 'where').map((c) => [c.field, c.op, encode(c.value)]),
    orderBy: q.constraints.filter((c): c is OrderByConstraint => c.kind === 'orderBy').map((c) => [c.field, c.dir]),
    limit: q.constraints.filter((c): c is LimitConstraint => c.kind === 'limit').pop()?.n,
    etag,
  }
}

async function fetchQuery(q: Query<any>, etag?: string): Promise<{ snap: QuerySnapshot; etag: string } | 'unchanged'> {
  const r = await apiFetch<any>('/api/db/query', { json: queryBody(q, etag) })
  if (r.notModified) return 'unchanged'
  return { snap: new QuerySnapshot((r.docs as WireDoc[]).map(toDocSnap)), etag: r.etag }
}

export async function getDocs<T = DocumentData>(q: Query<T>): Promise<QuerySnapshot<T>> {
  const r = (await fetchQuery(q)) as { snap: QuerySnapshot<T> }
  return r.snap
}

// ---- writes ------------------------------------------------------------------------------

interface WireWrite { op: 'set' | 'update' | 'delete'; path: string; data?: unknown; merge?: boolean; createOnly?: boolean }

const refreshers = new Set<() => void>()
let refreshTimer: ReturnType<typeof setTimeout> | undefined
/** After a local write, re-poll every listener right away so the UI reflects it without waiting for the next tick. */
export function refreshListeners() {
  clearTimeout(refreshTimer)
  refreshTimer = setTimeout(() => refreshers.forEach((fn) => fn()), 30)
}

async function commit(writes: WireWrite[], preconditions?: { path: string; rev: number | null }[]) {
  await apiFetch('/api/db/write', { json: { writes, preconditions } })
  refreshListeners()
}

const flatten = (path: string, data: unknown) => ({ path, data: encode(data) })

export async function setDoc(ref: DocumentReference, data: DocumentData, opts?: { merge?: boolean }): Promise<void> {
  await commit([{ op: 'set', ...flatten(ref.path, data), merge: !!opts?.merge }])
}

export async function updateDoc(ref: DocumentReference, data: DocumentData | string, ...rest: unknown[]): Promise<void> {
  let fields: DocumentData
  if (typeof data === 'string') {
    fields = {}
    const pairs = [data, ...rest]
    for (let i = 0; i < pairs.length; i += 2) fields[String(pairs[i])] = pairs[i + 1]
  } else fields = data
  await commit([{ op: 'update', ...flatten(ref.path, fields) }])
}

export async function addDoc(coll: CollectionReference, data: DocumentData): Promise<DocumentReference> {
  const ref = doc(coll)
  await commit([{ op: 'set', ...flatten(ref.path, data), createOnly: true }])
  return ref
}

export async function deleteDoc(ref: DocumentReference): Promise<void> {
  await commit([{ op: 'delete', path: ref.path }])
}

export class WriteBatch {
  private ops: WireWrite[] = []
  set(ref: DocumentReference, data: DocumentData, opts?: { merge?: boolean }) { this.ops.push({ op: 'set', ...flatten(ref.path, data), merge: !!opts?.merge }); return this }
  update(ref: DocumentReference, data: DocumentData) { this.ops.push({ op: 'update', ...flatten(ref.path, data) }); return this }
  delete(ref: DocumentReference) { this.ops.push({ op: 'delete', path: ref.path }); return this }
  async commit() { if (this.ops.length) await commit(this.ops) }
}
export const writeBatch = (_db: Firestore) => new WriteBatch()

export class Transaction {
  readonly reads = new Map<string, number | null>()
  readonly writes: WireWrite[] = []
  async get<T = DocumentData>(ref: DocumentReference<T>): Promise<DocumentSnapshot<T>> {
    const snap = await getDoc(ref)
    this.reads.set(ref.path, snap.rev)
    return snap
  }
  set(ref: DocumentReference, data: DocumentData, opts?: { merge?: boolean }) { this.writes.push({ op: 'set', ...flatten(ref.path, data), merge: !!opts?.merge }); return this }
  update(ref: DocumentReference, data: DocumentData) { this.writes.push({ op: 'update', ...flatten(ref.path, data) }); return this }
  delete(ref: DocumentReference) { this.writes.push({ op: 'delete', path: ref.path }); return this }
}

/** Optimistic transaction: reads record revisions, the commit fails with `aborted` if any changed, and we retry. */
export async function runTransaction<T>(_db: Firestore, fn: (tx: Transaction) => Promise<T>): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    const tx = new Transaction()
    const result = await fn(tx)
    try {
      if (tx.writes.length) {
        await commit(tx.writes, [...tx.reads].map(([path, rev]) => ({ path, rev })))
      }
      return result
    } catch (e) {
      if (e instanceof BackendError && e.code === 'aborted' && attempt < 4) continue
      throw e
    }
  }
}

// ---- listeners ---------------------------------------------------------------------------

type Observer<S> = { next?: (s: S) => void; error?: (e: Error) => void }

function pollInterval(path: string | null): number {
  return path && /\/messages$/.test(path) ? 1500 : 3000
}

/** Poll `step` until unsubscribed. `step` returns true when it delivered new data. */
function startPolling(intervalMs: number, step: (first: boolean) => Promise<void>, onError?: (e: Error) => void): Unsubscribe {
  let stopped = false
  let timer: ReturnType<typeof setTimeout> | undefined
  let inFlight = false
  let first = true
  let failures = 0

  const run = async () => {
    if (stopped || inFlight) return
    inFlight = true
    try {
      await step(first)
      first = false
      failures = 0
    } catch (e: any) {
      if (stopped) return
      // Network blips keep the listener alive (with backoff); real errors end it, like Firestore does.
      if (e?.code === 'unavailable') failures++
      else {
        stopped = true
        onError?.(e)
        return
      }
    } finally {
      inFlight = false
    }
    if (!stopped) schedule()
  }
  const schedule = () => {
    clearTimeout(timer)
    const hidden = typeof document !== 'undefined' && document.visibilityState === 'hidden'
    const delay = Math.min(intervalMs * (hidden ? 6 : 1) * 2 ** Math.min(failures, 4), 60_000)
    timer = setTimeout(run, delay)
  }
  const kick = () => { clearTimeout(timer); void run() }
  const onVisible = () => { if (document.visibilityState === 'visible') kick() }

  refreshers.add(kick)
  document.addEventListener('visibilitychange', onVisible)
  window.addEventListener('online', kick)
  void run()

  return () => {
    stopped = true
    clearTimeout(timer)
    refreshers.delete(kick)
    document.removeEventListener('visibilitychange', onVisible)
    window.removeEventListener('online', kick)
  }
}

export function onSnapshot<T = DocumentData>(
  target: DocumentReference<T>,
  next: ((s: DocumentSnapshot<T>) => void) | Observer<DocumentSnapshot<T>>,
  error?: (e: Error) => void,
): Unsubscribe
export function onSnapshot<T = DocumentData>(
  target: Query<T>,
  next: ((s: QuerySnapshot<T>) => void) | Observer<QuerySnapshot<T>>,
  error?: (e: Error) => void,
): Unsubscribe
export function onSnapshot(target: any, next: any, error?: (e: Error) => void): Unsubscribe {
  const onNext: (s: any) => void = typeof next === 'function' ? next : (s) => next.next?.(s)
  const onError = typeof next === 'function' ? error : next.error ?? error

  if (target instanceof DocumentReference) {
    let rev: number | null | undefined
    return startPolling(pollInterval(target.path), async () => {
      const r = await fetchDoc(target, rev ?? undefined)
      if (r === 'unchanged') return
      rev = r.rev
      onNext(r)
    }, onError)
  }
  let etag: string | undefined
  return startPolling(pollInterval(target.path), async () => {
    const r = await fetchQuery(target, etag)
    if (r === 'unchanged') return
    etag = r.etag
    onNext(r.snap)
  }, onError)
}
