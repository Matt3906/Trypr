import { useState } from 'react'
import { collection, deleteDoc, doc, getDoc, orderBy, query, setDoc } from '@/backend/firestore'
import { apiFetch } from '@/backend/api'
import { MdCheck, MdClose, MdMoreVert, MdPerson, MdPersonAddAlt } from 'react-icons/md'
import { useNavigate } from 'react-router-dom'
import { auth, db } from '@/backend'
import PageShell from '@/components/PageShell'
import { Dialog } from '@/components/Dialog'
import { Button, CenteredSpinner, IconButton, Menu, MenuItem, SoftCard, Spinner } from '@/components/ui'
import { useAuth } from '@/context/Auth'
import { useFeedback } from '@/context/Feedback'
import { useDocument, useQuerySnapshot } from '@/hooks/useFirestore'
import { useEffect } from 'react'

const userCache: Record<string, Record<string, any>> = {}

function FriendTile({ f, onRemove }: { f: Record<string, any>; onRemove: (uid: string) => void }) {
  const uid = String(f.uid ?? f.id ?? '')
  const email = String(f.email ?? '')
  const rawName = f.displayName ?? f.name
  const nameStr = typeof rawName === 'string' && rawName.trim() ? rawName : null
  const [data, setData] = useState<Record<string, any> | null>(uid ? userCache[uid] ?? null : null)
  const [loading, setLoading] = useState(!nameStr && !!uid && !userCache[uid])

  useEffect(() => {
    if (nameStr || !uid || userCache[uid]) return
    getDoc(doc(db, 'publicUsers', uid))
      .then((s) => {
        if (s.exists()) {
          userCache[uid] = s.data()
          setData(s.data())
        }
      })
      .catch(() => {})
      .finally(() => setLoading(false))
  }, [uid, nameStr])

  const resolved = data ? String(data.displayName ?? data.name ?? data.email ?? uid) : null
  const city = data ? String(data.city ?? data.location ?? '') : ''
  const title = nameStr ?? resolved ?? (loading ? 'Loading...' : email || uid || 'User')
  const subtitle = data ? `${String(data.email ?? email)}${city ? ` • ${city}` : ''}` : email

  return (
    <div className="row gap-md" style={{ padding: '10px 4px' }}>
      <MdPerson size={24} color="var(--text-2)" />
      <div className="grow">
        <div className="semibold ellipsis">{title}</div>
        <div className="muted ellipsis" style={{ fontSize: 13 }}>{loading ? <Spinner size="sm" /> : subtitle}</div>
      </div>
      {uid && (
        <Menu trigger={<IconButton title="Actions"><MdMoreVert size={20} /></IconButton>}>
          {(close) => <MenuItem onClick={() => { close(); onRemove(uid) }}>Remove friend</MenuItem>}
        </Menu>
      )}
    </div>
  )
}

export default function FriendsScreen() {
  const { user } = useAuth()
  const { toast, confirm } = useFeedback()
  const navigate = useNavigate()
  const [addOpen, setAddOpen] = useState(false)
  const [target, setTarget] = useState('')

  const me = user
  const myDoc = useDocument(me ? doc(db, 'users', me.uid) : null, [me?.uid])
  const requests = useQuerySnapshot(
    me ? query(collection(db, 'users', me.uid, 'friendRequests'), orderBy('createdAt', 'desc')) : null,
    [me?.uid],
  )

  const sendRequest = async () => {
    if (!me) return
    const email = target.trim()
    if (!email) return
    try {
      await apiFetch('/api/friends/request', { json: { email } })
      setAddOpen(false)
      setTarget('')
      toast('Friend request sent')
    } catch (err: any) {
      toast(err?.code === 'not-found' ? 'No user found' : `Failed to send request: ${err?.message ?? err}`)
    }
  }

  const accept = async (reqId: string) => {
    if (!me) return
    try {
      await apiFetch('/api/friends/accept', { json: { requestId: reqId } })
      toast('Friend request accepted')
    } catch (err: any) {
      toast(`Failed to accept request: ${err?.message ?? err}`)
    }
  }

  const decline = async (reqId: string) => {
    if (!me) return
    try {
      await deleteDoc(doc(db, 'users', me.uid, 'friendRequests', reqId))
      toast('Friend request declined')
    } catch (err: any) {
      toast(`Failed to decline request: ${err?.message ?? err}`)
    }
  }

  const removeFriend = async (targetUid: string) => {
    if (!me || !targetUid) return
    const ok = await confirm({ title: 'Remove friend', message: 'Are you sure you want to remove this friend?', confirmLabel: 'Remove' })
    if (!ok) return
    try {
      await apiFetch('/api/friends/remove', { json: { uid: targetUid } })
      toast('Friend removed')
    } catch (err: any) {
      toast(`Failed to remove friend: ${err?.message ?? err}`)
    }
  }

  const friendsRaw: any[] = (myDoc.data?.data()?.friends as any[]) ?? []
  const friends = friendsRaw.map((f) => (f && typeof f === 'object' ? { ...f } : { id: String(f) }))

  if (!me) {
    return (
      <PageShell>
        <div className="container center col gap-md" style={{ paddingTop: 60 }}>
          <p className="muted">Sign in to see your friends.</p>
          <Button onClick={() => navigate('/sign-in')}>Sign in</Button>
        </div>
      </PageShell>
    )
  }

  void auth
  return (
    <PageShell>
      <div className="container col gap-md">
        <div className="row between">
          <h1 className="t-display-s">Friends</h1>
          <Button icon={<MdPersonAddAlt size={18} />} onClick={() => setAddOpen(true)}>Add Friend</Button>
        </div>

        <SoftCard padding={16}>
          {myDoc.loading ? (
            <CenteredSpinner pad={30} />
          ) : friends.length === 0 ? (
            <div className="center" style={{ height: 120 }}>No friends yet</div>
          ) : (
            <div style={{ maxHeight: 260, overflowY: 'auto' }}>
              {friends.map((f, i) => (
                <div key={String(f.uid ?? f.id ?? i)} style={{ borderTop: i ? '1px solid var(--border)' : undefined }}>
                  <FriendTile f={f} onRemove={removeFriend} />
                </div>
              ))}
            </div>
          )}
        </SoftCard>

        <h3 className="t-title-m" style={{ marginTop: 8 }}>Friend Requests</h3>
        <SoftCard padding={12}>
          {requests.loading ? (
            <CenteredSpinner pad={30} />
          ) : requests.data.length === 0 ? (
            <div className="center" style={{ height: 80 }}>No incoming requests</div>
          ) : (
            requests.data.map((d, i) => {
              const x = d.data()
              return (
                <div key={d.id} className="row gap-md" style={{ padding: '8px 4px', borderTop: i ? '1px solid var(--border)' : undefined }}>
                  <div className="grow">
                    <div className="semibold">{x.fromName ?? x.fromEmail ?? 'Someone'}</div>
                    <div className="muted" style={{ fontSize: 13 }}>{x.fromEmail ?? ''}</div>
                  </div>
                  <IconButton title="Accept" onClick={() => accept(d.id)}><MdCheck size={22} color="#16a34a" /></IconButton>
                  <IconButton title="Decline" onClick={() => decline(d.id)}><MdClose size={22} color="#dc2626" /></IconButton>
                </div>
              )
            })
          )}
        </SoftCard>
      </div>

      <Dialog
        open={addOpen}
        onClose={() => setAddOpen(false)}
        title="Add friend (email)"
        actions={
          <>
            <Button variant="text" onClick={() => setAddOpen(false)}>Close</Button>
            <Button variant="text" onClick={sendRequest}>Send</Button>
          </>
        }
      >
        <input className="input" placeholder="Friend email" value={target} onChange={(e) => setTarget(e.target.value)} autoFocus />
      </Dialog>
    </PageShell>
  )
}

void setDoc
