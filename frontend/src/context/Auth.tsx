import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { onAuthStateChanged, type User } from 'firebase/auth'
import { doc, getDoc, onSnapshot, serverTimestamp, setDoc } from 'firebase/firestore'
import { auth, db } from '@/firebase'
import { isPremiumFromData } from '@/services/premiumAccess'

interface AuthValue {
  user: User | null
  /** True until the first auth state callback has fired. */
  loading: boolean
  signedIn: boolean
  isAdmin: boolean
  isPremium: boolean
  userData: Record<string, any> | null
}

const Ctx = createContext<AuthValue>({
  user: null, loading: true, signedIn: false, isAdmin: false, isPremium: false, userData: null,
})

/** Keeps users/{uid} and publicUsers/{uid} in sync (best-effort) for friend discovery. */
export async function ensureUserDoc(u: User): Promise<void> {
  try {
    const ref = doc(db, 'users', u.uid)
    const snap = await getDoc(ref)
    const upd: Record<string, any> = {}
    if (!snap.exists()) upd.createdAt = serverTimestamp()
    upd.email = (u.email ?? '').toLowerCase()
    const dn = u.displayName ?? ''
    if (dn) {
      upd.displayName = dn
      upd.displayNameLower = dn.toLowerCase()
    } else {
      upd.displayNameLower = ''
    }
    await setDoc(ref, upd, { merge: true })
    await setDoc(
      doc(db, 'publicUsers', u.uid),
      { displayName: dn, displayNameLower: dn.toLowerCase(), email: (u.email ?? '').toLowerCase(), updatedAt: serverTimestamp() },
      { merge: true },
    )
  } catch {
    /* best-effort */
  }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(auth.currentUser)
  const [loading, setLoading] = useState(true)
  const [isAdmin, setIsAdmin] = useState(false)
  const [userData, setUserData] = useState<Record<string, any> | null>(null)

  useEffect(
    () =>
      onAuthStateChanged(auth, (u) => {
        setUser(u)
        setLoading(false)
        if (u) void ensureUserDoc(u)
      }),
    [],
  )

  useEffect(() => {
    if (!user) {
      setIsAdmin(false)
      setUserData(null)
      return
    }
    const unsubAdmin = onSnapshot(
      doc(db, 'admins', user.uid),
      (s) => setIsAdmin(s.exists()),
      () => setIsAdmin(false),
    )
    const unsubUser = onSnapshot(
      doc(db, 'users', user.uid),
      (s) => setUserData(s.data() ?? null),
      () => setUserData(null),
    )
    return () => {
      unsubAdmin()
      unsubUser()
    }
  }, [user])

  return (
    <Ctx.Provider value={{ user, loading, signedIn: !!user, isAdmin, isPremium: isPremiumFromData(userData), userData }}>
      {children}
    </Ctx.Provider>
  )
}

export const useAuth = () => useContext(Ctx)
