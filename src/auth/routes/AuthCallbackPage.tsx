import { useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth } from '../AuthProvider'
import { Splash } from '@/shell/Splash'

// Email confirmation links land here. supabase-js (detectSessionInUrl) does
// the code exchange on load; we just wait for the session and move on.
export function AuthCallbackPage() {
  const navigate = useNavigate()
  const { session, loading } = useAuth()

  useEffect(() => {
    if (loading) return
    navigate(session ? '/' : '/login', { replace: true })
  }, [session, loading, navigate])

  return <Splash />
}
