import { Navigate, Outlet, useLocation } from 'react-router-dom'
import { useAuth } from './AuthProvider'
import { Splash } from '@/shell/Splash'

export function RequireAuth() {
  const { session, loading } = useAuth()
  const location = useLocation()

  if (loading) return <Splash />
  if (!session) {
    // Router location object, never a raw URL string (open-redirect hygiene).
    return <Navigate to="/login" replace state={{ from: location }} />
  }
  return <Outlet />
}
