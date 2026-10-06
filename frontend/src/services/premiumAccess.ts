import { doc, getDoc } from 'firebase/firestore'
import { auth, db } from '@/firebase'

export function isPremiumFromData(data: Record<string, any> | undefined | null): boolean {
  const d = data ?? {}
  const f = (k: string) => String(d[k] ?? '').toLowerCase()
  return f('subscription') === 'premium' || f('subscriptionType') === 'premium' || f('subscriptionStatus') === 'premium'
}

/** Mirrors backend logic: admin marker doc, entitlements doc, role/roles. */
export async function canAccessPremium(): Promise<boolean> {
  const user = auth.currentUser
  if (!user) return false
  try {
    const uid = user.uid
    const [ent, admin] = await Promise.all([
      getDoc(doc(db, 'userEntitlements', uid)),
      getDoc(doc(db, 'admins', uid)),
    ])
    if (admin.exists()) return true
    const data = ent.data() ?? {}
    if (String(data.subscription ?? '').toLowerCase() === 'premium') return true
    if (String(data.subscriptionStatus ?? '').toLowerCase() === 'premium') return true

    const roles: string[] = []
    for (const r of [data.role, data.roles]) {
      if (typeof r === 'string') roles.push(r.toLowerCase())
      else if (Array.isArray(r)) roles.push(...r.map((e) => String(e).toLowerCase()))
    }
    return roles.includes('admin')
  } catch {
    return false
  }
}
