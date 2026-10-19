/** Email/password auth against the Trypr API (session cookie), exposing the bits of the Firebase Auth API the app uses. */
import { apiFetch, setUnauthenticatedHandler } from './api'
import { refreshListeners } from './firestore'

export interface User {
  uid: string
  email: string | null
  displayName: string | null
}

export class Auth {
  currentUser: User | null = null
}

export const auth = new Auth()

type Listener = (u: User | null) => void
const listeners = new Set<Listener>()
let ready = false
let initStarted = false

function setUser(u: User | null) {
  const changed = (auth.currentUser?.uid ?? null) !== (u?.uid ?? null)
  auth.currentUser = u
  if (!ready || changed) {
    ready = true
    listeners.forEach((l) => l(u))
  }
}

async function refresh() {
  try {
    const r = await apiFetch<{ user: User | null }>('/api/auth/me')
    setUser(r.user)
  } catch {
    // Server unreachable: keep whatever we know, but unblock the UI on first load.
    if (!ready) setUser(null)
  }
}

function init() {
  if (initStarted) return
  initStarted = true
  setUnauthenticatedHandler(() => setUser(null))
  void refresh()
  window.addEventListener('focus', () => void refresh()) // pick up sign-in/out from other tabs
}

export function onAuthStateChanged(_auth: Auth, cb: Listener): () => void {
  init()
  listeners.add(cb)
  if (ready) queueMicrotask(() => listeners.has(cb) && cb(auth.currentUser))
  return () => listeners.delete(cb)
}

async function credentialFlow(path: string, email: string, password: string): Promise<{ user: User }> {
  const r = await apiFetch<{ user: User }>(path, { json: { email, password } })
  setUser(r.user)
  refreshListeners()
  return { user: r.user }
}

export const signInWithEmailAndPassword = (_a: Auth, email: string, password: string) =>
  credentialFlow('/api/auth/login', email, password)

export const createUserWithEmailAndPassword = (_a: Auth, email: string, password: string) =>
  credentialFlow('/api/auth/register', email, password)

export async function signOut(_a: Auth): Promise<void> {
  try {
    await apiFetch('/api/auth/logout', { method: 'POST' })
  } finally {
    setUser(null)
  }
}

export async function sendPasswordResetEmail(_a: Auth, email: string): Promise<void> {
  await apiFetch('/api/auth/forgot-password', { json: { email } })
}

export async function confirmPasswordReset(_a: Auth, token: string, password: string): Promise<void> {
  await apiFetch('/api/auth/reset-password', { json: { token, password } })
}
