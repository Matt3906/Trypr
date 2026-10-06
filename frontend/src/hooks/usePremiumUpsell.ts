import { useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { auth } from '@/firebase'
import { useFeedback } from '@/context/Feedback'

/** Sends signed-in users to /premium; asks signed-out users to sign in first. */
export function usePremiumUpsell() {
  const navigate = useNavigate()
  const { toast } = useFeedback()
  return useCallback(() => {
    if (!auth.currentUser) {
      toast('Sign in to unlock premium features.')
      return
    }
    navigate('/premium')
  }, [navigate, toast])
}
