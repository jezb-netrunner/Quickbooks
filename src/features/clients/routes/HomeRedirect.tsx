import { Navigate } from 'react-router-dom'
import { useClients } from '../hooks'
import { recallLastClient } from '../lastClient'
import { Splash } from '@/shell/Splash'

// "/" resolves to the last-used client (validated against the live RLS-visible
// list) or the picker.
export function HomeRedirect() {
  const { data: clients, isPending } = useClients()
  if (isPending) return <Splash />

  const last = recallLastClient()
  const active = (clients ?? []).filter((c) => !c.archived_at)
  const target = active.find((c) => c.id === last) ?? (active.length === 1 ? active[0] : null)
  return <Navigate to={target ? `/c/${target.id}` : '/select-client'} replace />
}
