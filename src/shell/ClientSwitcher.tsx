import { useNavigate } from 'react-router-dom'
import { useClients } from '@/features/clients/hooks'
import { rememberLastClient } from '@/features/clients/lastClient'

// A bare RLS-filtered select on clients IS the switcher query — membership
// logic lives server-side, deliberately not in a SQL view (ADR-0001).
export function ClientSwitcher({ activeClientId }: { activeClientId?: string }) {
  const navigate = useNavigate()
  const { data: clients } = useClients()
  const active = clients?.filter((c) => !c.archived_at) ?? []

  if (active.length === 0) return null

  return (
    <div style={{ padding: '0 4px', display: 'flex', flexDirection: 'column', gap: 6 }}>
      <div
        style={{
          font: 'var(--type-overline)',
          letterSpacing: 'var(--tracking-caps)',
          textTransform: 'uppercase',
          color: 'var(--ink-400)',
          padding: '0 6px',
        }}
      >
        Client
      </div>
      <select
        aria-label="Switch client"
        value={activeClientId ?? ''}
        onChange={(e) => {
          const id = e.target.value
          if (!id) {
            navigate('/select-client')
            return
          }
          rememberLastClient(id)
          navigate(`/c/${id}`)
        }}
        style={{
          width: '100%',
          height: 34,
          padding: '0 8px',
          background: 'var(--ink-900)',
          color: 'var(--sand-100)',
          border: '1px solid var(--ink-700)',
          borderRadius: 'var(--radius-md)',
          font: '500 13px/1.2 var(--font-sans)',
        }}
      >
        <option value="">All clients…</option>
        {active.map((c) => (
          <option key={c.id} value={c.id}>
            {c.name}
          </option>
        ))}
      </select>
    </div>
  )
}
