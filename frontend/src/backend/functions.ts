import { apiFetch } from './api'

export class Functions { readonly type = 'functions' }
export const getFunctions = () => new Functions()

/** Mirrors Firebase's httpsCallable: resolves { data }, rejects with an error carrying `code` and `message`. */
export function httpsCallable<Req = unknown, Res = unknown>(_f: Functions, name: string) {
  return async (data?: Req): Promise<{ data: Res }> => {
    const r = await apiFetch<{ data: Res }>(`/api/fn/${encodeURIComponent(name)}`, { json: { data: data ?? {} } })
    return { data: r.data }
  }
}
