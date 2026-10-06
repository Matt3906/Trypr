import { useCallback } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'

/** Mirrors Navigator.pop(): go back if there is history, otherwise fall back to `fallback`. */
export function useBack(fallback = '/') {
  const navigate = useNavigate()
  const location = useLocation()
  return useCallback(() => {
    if (location.key !== 'default') navigate(-1)
    else navigate(fallback, { replace: true })
  }, [navigate, location.key, fallback])
}
