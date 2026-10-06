import { useEffect, useState } from 'react'
import { arrayUnion, collection, doc, getDoc, onSnapshot, query, serverTimestamp, setDoc, updateDoc, where } from 'firebase/firestore'
import { MdCheck, MdLink, MdPeopleOutline } from 'react-icons/md'
import { auth, db } from '@/firebase'
import { Dialog } from './Dialog'
import { Button, Spinner } from './ui'
import { useFeedback } from '@/context/Feedback'

interface Props {
  open: boolean
  onClose: () => void
  /** Firestore path to the trip document, e.g. `users/{uid}/trips/{id}`. */
  tripRefPath: string
  tripId: string
  tripName: string
}

const extractOwnerUid = (path: string) => {
  const p = path.split('/')
  return p.length >= 2 && p[0] === 'users' ? p[1] : ''
}

/** Share a trip: copy link, share with friends (grants edit access), approve link requests. */
export default function ShareTripDialog({ open, onClose, tripRefPath, tripId, tripName }: Props) {
  const { toast } = useFeedback()
  const me = auth.currentUser
  const ownerUid = extractOwnerUid(tripRefPath)
  const isOwner = !!me && ownerUid === me.uid
  const tripRef = doc(db, tripRefPath)

  const [friends, setFriends] = useState<Record<string, any>[]>([])
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [loading, setLoading] = useState(true)
  const [sharing, setSharing] = useState(false)
  const [linkCopied, setLinkCopied] = useState(false)
  const [requests, setRequests] = useState<{ id: string; data: Record<string, any> }[] | null>(null)

  useEffect(() => {
    if (!open) return
    setSelected(new Set())
    setLinkCopied(false)
    setLoading(true)
    ;(async () => {
      if (!me) return setLoading(false)
      try {
        const meDoc = await getDoc(doc(db, 'users', me.uid))
        const raw = (meDoc.data()?.friends as any[]) ?? []
        setFriends(raw.map((f) => (f && typeof f === 'object' ? { ...f } : { id: String(f) })))
      } catch (e) {
        console.debug('ShareTripDialog: load friends failed', e)
      }
      setLoading(false)
    })()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, tripRefPath])

  useEffect(() => {
    if (!open || !isOwner) return
    return onSnapshot(
      query(collection(db, 'tripJoinRequests'), where('tripRef', '==', tripRefPath)),
      (s) => setRequests(s.docs.map((d) => ({ id: d.id, data: d.data() }))),
      () => setRequests([]),
    )
  }, [open, isOwner, tripRefPath])

  const shareWithSelected = async () => {
    if (!me || !selected.size) return
    setSharing(true)
    try {
      if (isOwner) await updateDoc(tripRef, { sharedWith: arrayUnion(...selected) })
      const failed: string[] = []
      for (const uid of selected) {
        try {
          await setDoc(
            doc(db, 'users', uid, 'sharedTrips', tripId),
            { ownerUid: ownerUid || me.uid, ownerName: me.displayName ?? me.email ?? me.uid, tripRef: tripRefPath, tripName, createdAt: serverTimestamp() },
            { merge: true },
          )
        } catch (e) {
          failed.push(uid)
          console.debug(`ShareTripDialog: inbox write for ${uid} failed`, e)
        }
      }
      onClose()
      toast(failed.length ? `Shared with some failures: ${failed.join(', ')}` : `Trip shared with ${selected.size} friend${selected.size > 1 ? 's' : ''}`)
    } catch (e: any) {
      toast(`Share failed: ${e?.message ?? e}`)
    } finally {
      setSharing(false)
    }
  }

  const copyLink = async () => {
    const link = `${window.location.origin}/trip/${ownerUid}/${tripId}`
    try { await navigator.clipboard.writeText(link) } catch { /* ignore */ }
    try { await updateDoc(tripRef, { shareLinkEnabled: true }) } catch { /* ignore */ }
    setLinkCopied(true)
    toast('Share link copied to clipboard')
  }

  const approve = async (requestId: string, requesterUid: string) => {
    if (!me) return
    try {
      await updateDoc(tripRef, { sharedWith: arrayUnion(requesterUid) })
      await setDoc(
        doc(db, 'users', requesterUid, 'sharedTrips', tripId),
        { ownerUid, ownerName: me.displayName ?? me.email ?? me.uid, tripRef: tripRefPath, tripName, createdAt: serverTimestamp(), sharedFrom: me.displayName ?? me.email ?? me.uid },
        { merge: true },
      )
      await updateDoc(doc(db, 'tripJoinRequests', requestId), { status: 'approved', handledAt: serverTimestamp() })
      toast('Request approved')
    } catch (e: any) {
      toast(`Approve failed: ${e?.message ?? e}`)
    }
  }
  const deny = async (requestId: string) => {
    try {
      await updateDoc(doc(db, 'tripJoinRequests', requestId), { status: 'denied', handledAt: serverTimestamp() })
    } catch (e: any) {
      toast(`Deny failed: ${e?.message ?? e}`)
    }
  }

  const pending = (requests ?? []).filter((r) => (r.data.status ?? 'pending') === 'pending')

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title="Share trip"
      actions={
        <>
          <Button variant="text" onClick={onClose}>Close</Button>
          {friends.length > 0 && (
            <Button variant="text" onClick={shareWithSelected} disabled={sharing || !selected.size}>
              {sharing ? <Spinner size="sm" /> : `Share (${selected.size})`}
            </Button>
          )}
        </>
      }
    >
      {loading ? (
        <div className="center" style={{ padding: 24 }}><Spinner /></div>
      ) : (
        <div className="col gap-md">
          <div>
            <div className="semibold">Share via link</div>
            <div className="muted" style={{ fontSize: 12, margin: '4px 0 8px' }}>Anyone with the link can view. Signed-in users who are shared-to can edit.</div>
            <Button variant="outlined" icon={linkCopied ? <MdCheck size={18} /> : <MdLink size={18} />} onClick={copyLink}>{linkCopied ? 'Link copied!' : 'Copy share link'}</Button>
          </div>
          <hr className="divider" />
          <div>
            <div className="semibold">Share with friends</div>
            <div className="muted" style={{ fontSize: 12, margin: '4px 0 8px' }}>Friends get full editing access immediately.</div>
            {friends.length === 0 ? (
              <div className="row gap-sm faint"><MdPeopleOutline size={22} /> No friends yet. Add friends from your account.</div>
            ) : (
              <div style={{ maxHeight: 240, overflowY: 'auto' }}>
                {friends.map((f, i) => {
                  const uid = String(f.uid ?? f.id ?? '')
                  const label = String(f.displayName ?? f.name ?? f.email ?? uid ?? 'Friend')
                  return (
                    <label key={uid || i} className="row gap-md" style={{ padding: '6px 0', cursor: 'pointer' }}>
                      <input
                        type="checkbox"
                        checked={!!uid && selected.has(uid)}
                        onChange={(e) => {
                          if (!uid) return
                          setSelected((s) => { const n = new Set(s); e.target.checked ? n.add(uid) : n.delete(uid); return n })
                        }}
                      />
                      <div>
                        <div>{label}</div>
                        {f.email && <div className="muted" style={{ fontSize: 12 }}>{String(f.email)}</div>}
                      </div>
                    </label>
                  )
                })}
              </div>
            )}
          </div>
          {isOwner && (
            <>
              <hr className="divider" />
              <div>
                <div className="semibold" style={{ marginBottom: 8 }}>Link requests</div>
                {requests == null ? <span className="muted">Loading requests…</span> : pending.length === 0 ? (
                  <span className="faint">No pending requests</span>
                ) : (
                  pending.map(({ id, data }) => {
                    const requesterUid = String(data.requesterUid ?? '')
                    const name = String(data.requesterName ?? data.requesterEmail ?? requesterUid)
                    return (
                      <div key={id} className="row gap-sm" style={{ padding: '6px 0', borderTop: '1px solid var(--border)' }}>
                        <div className="grow"><div>{name}</div><div className="muted ellipsis" style={{ fontSize: 12 }}>{requesterUid}</div></div>
                        <Button size="sm" variant="text" onClick={() => approve(id, requesterUid)}>Approve</Button>
                        <Button size="sm" variant="text" onClick={() => deny(id)}>Deny</Button>
                      </div>
                    )
                  })
                )}
              </div>
            </>
          )}
        </div>
      )}
    </Dialog>
  )
}
