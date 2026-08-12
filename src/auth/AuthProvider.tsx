import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

interface AuthState {
  session: Session | null
  // While the first getSession() is in flight we render a splash, never a
  // redirect — otherwise every hard refresh of a deep link bounces to /login.
  loading: boolean
}

const AuthContext = createContext<AuthState>({ session: null, loading: true })

export function AuthProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<AuthState>({ session: null, loading: true })
  const queryClient = useQueryClient()
  const lastUserId = useRef<string | null>(null)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      lastUserId.current = data.session?.user.id ?? null
      setState({ session: data.session, loading: false })
    })
    const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => {
      const userId = session?.user.id ?? null
      // Cross-user cache bleed is a leak vector on shared machines: clear on
      // sign-out AND whenever the signed-in user changes.
      if (userId !== lastUserId.current) {
        queryClient.clear()
        lastUserId.current = userId
      }
      setState({ session, loading: false })
    })
    return () => sub.subscription.unsubscribe()
  }, [queryClient])

  return <AuthContext.Provider value={state}>{children}</AuthContext.Provider>
}

export function useAuth() {
  return useContext(AuthContext)
}
