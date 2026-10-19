import { useState } from 'react'
import { MdArrowForward, MdLock, MdLockReset } from 'react-icons/md'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { auth } from '@/backend'
import { confirmPasswordReset } from '@/backend/auth'
import { Button, Spinner, TextInput } from '@/components/ui'
import { useFeedback } from '@/context/Feedback'
import AuthLayout from './AuthLayout'

/** Landing page for the emailed password-reset link: /reset-password?token=... */
export default function ResetPasswordScreen() {
  const { toast } = useFeedback()
  const navigate = useNavigate()
  const token = useSearchParams()[0].get('token')?.trim() ?? ''
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [saving, setSaving] = useState(false)

  const submit = async () => {
    if (password.length < 8) return toast('Password must be at least 8 characters')
    if (password !== confirm) return toast('Passwords do not match')
    setSaving(true)
    try {
      await confirmPasswordReset(auth, token, password)
      toast('Password updated. Sign in with your new password.')
      navigate('/sign-in', { replace: true })
    } catch (e: any) {
      toast(e?.message ?? 'Could not reset password')
    } finally {
      setSaving(false)
    }
  }

  return (
    <AuthLayout bg="DSC_0318.jpg" icon={<MdLockReset size={28} />} title="Choose a new password" subtitle="Enter a new password for your Trypr account">
      {token ? (
        <form className="col gap-lg" onSubmit={(e) => { e.preventDefault(); void submit() }}>
          <TextInput icon={<MdLock size={20} />} type="password" placeholder="New password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="new-password" />
          <TextInput icon={<MdLock size={20} />} type="password" placeholder="Confirm new password" value={confirm} onChange={(e) => setConfirm(e.target.value)} autoComplete="new-password" />
          {saving ? <div className="center"><Spinner /></div> : <Button type="submit" block icon={<MdArrowForward size={18} />}>Update password</Button>}
        </form>
      ) : (
        <p className="muted">This reset link is missing its token. Request a new one from the <Link to="/sign-in" style={{ fontWeight: 600 }}>sign-in page</Link>.</p>
      )}
    </AuthLayout>
  )
}
