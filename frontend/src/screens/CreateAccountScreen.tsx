import { useState } from 'react'
import { createUserWithEmailAndPassword, GoogleAuthProvider, signInWithPopup, type User } from 'firebase/auth'
import { doc, serverTimestamp, setDoc } from 'firebase/firestore'
import { MdArrowForward, MdEmail, MdExplore, MdLock } from 'react-icons/md'
import { FcGoogle } from 'react-icons/fc'
import { useNavigate } from 'react-router-dom'
import { auth, db } from '@/firebase'
import { Button, Spinner, TextInput } from '@/components/ui'
import { useFeedback } from '@/context/Feedback'
import AuthLayout, { OrDivider } from './AuthLayout'

/** Ensure a normalized users/{uid} doc exists so friend search works. */
async function upsertUserDoc(user: User) {
  try {
    const email = (user.email ?? '').toLowerCase()
    let displayName = (user.displayName ?? '').trim()
    if (!displayName) displayName = email.split('@')[0] ?? ''
    await setDoc(
      doc(db, 'users', user.uid),
      { name: displayName, displayName, displayNameLower: displayName.toLowerCase(), email, createdAt: serverTimestamp() },
      { merge: true },
    )
  } catch {
    /* don't block sign-up on Firestore write failures */
  }
}

export default function CreateAccountScreen() {
  const { toast } = useFeedback()
  const navigate = useNavigate()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [loading, setLoading] = useState(false)
  const [googleLoading, setGoogleLoading] = useState(false)

  const create = async () => {
    if (password !== confirm) {
      toast('Passwords do not match')
      return
    }
    setLoading(true)
    try {
      const cred = await createUserWithEmailAndPassword(auth, email.trim(), password)
      await upsertUserDoc(cred.user)
      navigate('/complete-profile', { replace: true })
    } catch (e: any) {
      toast(e?.message ?? 'Create account failed')
    } finally {
      setLoading(false)
    }
  }

  const google = async () => {
    setGoogleLoading(true)
    try {
      const cred = await signInWithPopup(auth, new GoogleAuthProvider())
      await upsertUserDoc(cred.user)
      navigate('/complete-profile', { replace: true })
    } catch {
      toast('Google sign up failed')
    } finally {
      setGoogleLoading(false)
    }
  }

  return (
    <AuthLayout bg="DSC_0042.jpg" icon={<MdExplore size={28} />} title="Start your journey" subtitle="Create an account to plan and save your adventures">
      <form className="col gap-lg" onSubmit={(e) => { e.preventDefault(); void create() }}>
        <TextInput icon={<MdEmail size={20} />} type="email" placeholder="Enter your email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" />
        <TextInput icon={<MdLock size={20} />} type="password" placeholder="Create a password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="new-password" />
        <TextInput icon={<MdLock size={20} />} type="password" placeholder="Confirm your password" value={confirm} onChange={(e) => setConfirm(e.target.value)} autoComplete="new-password" />
        {loading ? <div className="center"><Spinner /></div> : <Button type="submit" block icon={<MdArrowForward size={18} />}>Create account</Button>}
      </form>
      <OrDivider />
      {googleLoading ? <div className="center"><Spinner /></div> : <Button variant="neutral" block icon={<FcGoogle size={20} />} onClick={google}>Google</Button>}
    </AuthLayout>
  )
}
