/**
 * Wire format shared with backend/app/docstore/fields.py:
 *   Timestamp -> {"$ts": ISO}      sentinels -> {"$op": "serverTimestamp" | "increment" | ...}
 */

export class Timestamp {
  constructor(readonly seconds: number, readonly nanoseconds: number) {}
  static now(): Timestamp { return Timestamp.fromMillis(Date.now()) }
  static fromDate(d: Date): Timestamp { return Timestamp.fromMillis(d.getTime()) }
  static fromMillis(ms: number): Timestamp {
    const seconds = Math.floor(ms / 1000)
    return new Timestamp(seconds, Math.round((ms - seconds * 1000) * 1e6))
  }
  toMillis(): number { return this.seconds * 1000 + Math.floor(this.nanoseconds / 1e6) }
  toDate(): Date { return new Date(this.toMillis()) }
  isEqual(o: Timestamp): boolean { return this.seconds === o.seconds && this.nanoseconds === o.nanoseconds }
  toJSON() { return { $ts: this.toDate().toISOString() } }
  valueOf(): string { return this.toDate().toISOString() }
}

type Op = 'serverTimestamp' | 'increment' | 'arrayUnion' | 'arrayRemove' | 'deleteField'
export class FieldValue {
  constructor(readonly op: Op, readonly arg?: unknown) {}
}
export const serverTimestamp = () => new FieldValue('serverTimestamp')
export const deleteField = () => new FieldValue('deleteField')
export const increment = (n: number) => new FieldValue('increment', n)
export const arrayUnion = (...v: unknown[]) => new FieldValue('arrayUnion', v)
export const arrayRemove = (...v: unknown[]) => new FieldValue('arrayRemove', v)

export function encode(value: unknown): unknown {
  if (value === undefined) return undefined
  if (value === null || typeof value !== 'object') return value
  if (value instanceof Timestamp) return { $ts: value.toDate().toISOString() }
  if (value instanceof Date) return { $ts: value.toISOString() }
  if (value instanceof FieldValue) {
    switch (value.op) {
      case 'increment': return { $op: 'increment', n: value.arg }
      case 'arrayUnion':
      case 'arrayRemove': return { $op: value.op, v: (value.arg as unknown[]).map(encode) }
      default: return { $op: value.op }
    }
  }
  if (Array.isArray(value)) return value.map((v) => (v === undefined ? null : encode(v)))
  const out: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    const e = encode(v)
    if (e !== undefined) out[k] = e // undefined fields are dropped, as JSON.stringify would
  }
  return out
}

export function decode(value: any): any {
  if (value === null || typeof value !== 'object') return value
  if (Array.isArray(value)) return value.map(decode)
  const keys = Object.keys(value)
  if (keys.length === 1 && keys[0] === '$ts' && typeof value.$ts === 'string') return Timestamp.fromDate(new Date(value.$ts))
  const out: Record<string, any> = {}
  for (const k of keys) out[k] = decode(value[k])
  return out
}
