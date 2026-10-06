import { doc, getDoc } from 'firebase/firestore'
import { db } from '@/firebase'

/** Fills `cache` (uid -> display name) for any uids not yet present. */
export async function ensureNameCache(
  cache: Record<string, string>,
  uids: string[],
  currentUidForFriendsFallback?: string | null,
): Promise<void> {
  const missing = uids.filter((u) => u && !(u in cache))
  if (!missing.length) return

  const friendsName: Record<string, string> = {}
  if (currentUidForFriendsFallback) {
    try {
      const me = await getDoc(doc(db, 'users', currentUidForFriendsFallback))
      const friends = (me.data()?.friends as any[]) ?? []
      for (const entry of friends) {
        if (!entry || typeof entry !== 'object') continue
        const uid = String(entry.uid ?? entry.id ?? '')
        if (!uid) continue
        const name = String(entry.displayName ?? entry.name ?? entry.email ?? '').trim()
        if (name) friendsName[uid] = name
      }
    } catch {
      /* ignore */
    }
  }

  await Promise.all(
    missing.map(async (uid) => {
      try {
        const pub = await getDoc(doc(db, 'publicUsers', uid))
        const d = pub.data()
        if (d) {
          cache[uid] = String(d.displayName || d.name || d.email || uid)
          return
        }
        const f = friendsName[uid]
        if (f && f.trim()) {
          cache[uid] = f
          return
        }
      } catch {
        /* fall through */
      }
      cache[uid] = uid
    }),
  )
}
