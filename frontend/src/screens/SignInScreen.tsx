import { useState } from 'react'
import { sendPasswordResetEmail, signInWithEmailAndPassword } from '@/backend/auth'
import { MdArrowForward, MdEmail, MdLock, MdWavingHand } from 'react-icons/md'
import { Link, useNavigate } from 'react-router-dom'
import { auth } from '@/backend'
import { Button, Spinner, TextInput } from '@/components/ui'
import { Dialog } from '@/components/Dialog'
import { useFeedback } from '@/context/Feedback'
import { useBack } from '@/hooks/useBack'
import AuthLayout from './AuthLayout'

export default function SignInScreen() {
  const { toast } = useFeedback()
  const navigate = useNavigate()
  const back = useBack('/')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(false)
  const [resetOpen, setResetOpen] = useState(false)
  const [resetEmail, setResetEmail] = useState('')

  const signIn = async () => {
    setLoading(true)
    try {
      await signInWithEmailAndPassword(auth, email.trim(), password)
      back()
    } catch (e: any) {
      toast(e?.message ?? 'Sign in failed')
    } finally {
      setLoading(false)
    }
  }

  const sendReset = async () => {
    setResetOpen(false)
    try {
      await sendPasswordResetEmail(auth, resetEmail.trim())
      toast('If that email has an account, a reset link is on its way')
    } catch (e: any) {
      toast(e?.message ?? 'Failed to send reset email')
    }
  }

  return (
    <AuthLayout bg="DSC_0318.jpg" icon={<MdWavingHand size={28} />} title="Welcome back" subtitle="Sign in to continue your next adventure">
      <form
        className="col gap-lg"
        onSubmit={(e) => {
          e.preventDefault()
          void signIn()
        }}
      >
        <TextInput icon={<MdEmail size={20} />} type="email" placeholder="Enter your email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" />
        <TextInput icon={<MdLock size={20} />} type="password" placeholder="Enter your password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" />
        <div style={{ textAlign: 'right', marginTop: -8 }}>
          <button type="button" className="btn btn-text" onClick={() => { setResetEmail(email); setResetOpen(true) }}>Forgot password?</button>
        </div>
        {loading ? (
          <div className="center"><Spinner /></div>
        ) : (
          <Button type="submit" block icon={<MdArrowForward size={18} />}>Sign in</Button>
        )}
      </form>

      <div className="row center gap-xs" style={{ marginTop: 24 }}>
        <span className="muted">Don't have an account?</span>
        <Link to="/create-account" style={{ fontWeight: 600 }}>Create one</Link>
      </div>

      <Dialog
        open={resetOpen}
        onClose={() => setResetOpen(false)}
        title="Reset password"
        actions={
          <>
            <Button variant="text" onClick={() => setResetOpen(false)}>Cancel</Button>
            <Button variant="solid" onClick={sendReset}>Send</Button>
          </>
        }
      >
        <TextInput placeholder="Email" value={resetEmail} onChange={(e) => setResetEmail(e.target.value)} autoFocus />
      </Dialog>
      {/* navigate kept for parity with Flutter's pushReplacement flows */}
      <span hidden onClick={() => navigate('/')} />
    </AuthLayout>
  )
}
