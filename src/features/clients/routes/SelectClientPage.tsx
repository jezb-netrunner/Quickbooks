import { Link, useNavigate } from 'react-router-dom'
import { Badge, Button, Card, Icon } from '@/design-system'
import { useClients, useMyMemberships } from '../hooks'
import { rememberLastClient } from '../lastClient'
import { Splash } from '@/shell/Splash'
import { signOut } from '@/auth/api'

export function SelectClientPage() {
  const navigate = useNavigate()
  const { data: memberships, isPending: loadingMemberships } = useMyMemberships()
  const { data: clients, isPending: loadingClients } = useClients()

  if (loadingMemberships || loadingClients) return <Splash />

  const isAdmin = (memberships ?? []).some((m) => m.role === 'firm_admin')
  const firmName = memberships?.[0]?.firms?.name
  const active = (clients ?? []).filter((c) => !c.archived_at)

  return (
    <div style={{ minHeight: '100vh', background: 'var(--surface-page)', padding: '48px 24px' }}>
      <div style={{ maxWidth: 720, margin: '0 auto', display: 'flex', flexDirection: 'column', gap: 20 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 16 }}>
          <div>
            <h1 style={{ font: 'var(--type-h1)', letterSpacing: 'var(--tracking-tight)' }}>
              {firmName ?? 'Larkspur'}
            </h1>
            <p style={{ marginTop: 4, font: 'var(--type-body-sm)', color: 'var(--text-muted)' }}>
              {active.length === 0
                ? 'No clients yet'
                : `${active.length} client ${active.length === 1 ? 'company' : 'companies'}`}
            </p>
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            {isAdmin && (
              <Button variant="secondary" size="sm" iconLeft="settings" onClick={() => navigate('/firm')}>
                Firm settings
              </Button>
            )}
            <Button
              variant="ghost"
              size="sm"
              iconLeft="log-out"
              onClick={() => {
                void signOut().then(() => navigate('/login'))
              }}
            >
              Sign out
            </Button>
          </div>
        </div>

        {(memberships ?? []).length === 0 ? (
          <Card title="Welcome to Larkspur" subtitle="You are not part of a firm yet">
            <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-secondary)' }}>
                Create your practice firm to start adding client companies, or ask your firm admin to
                add this account ({/* exact fact, per voice rules */}your confirmed email) as a member.
              </p>
              <div>
                <Button iconLeft="plus" onClick={() => navigate('/create-firm')}>
                  Create your firm
                </Button>
              </div>
            </div>
          </Card>
        ) : active.length === 0 ? (
          <Card title="No clients to show">
            <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-secondary)' }}>
              {isAdmin
                ? 'Add your first client company from firm settings.'
                : 'Your admin has not assigned any clients to you yet.'}
            </p>
          </Card>
        ) : (
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))', gap: 16 }}>
            {active.map((c) => (
              <Link
                key={c.id}
                to={`/c/${c.id}`}
                onClick={() => rememberLastClient(c.id)}
                style={{ textDecoration: 'none' }}
              >
                <Card>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                    <span
                      style={{
                        width: 36,
                        height: 36,
                        borderRadius: 'var(--radius-sm)',
                        background: 'var(--ink-100)',
                        display: 'grid',
                        placeItems: 'center',
                        color: 'var(--ink-700)',
                      }}
                    >
                      <Icon name="building-2" size={17} />
                    </span>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ font: 'var(--weight-medium) var(--text-sm)/1.3 var(--font-sans)' }}>{c.name}</div>
                      <div style={{ marginTop: 2, font: 'var(--type-label)', color: 'var(--text-muted)' }}>
                        {c.code ?? c.reporting_basis}
                      </div>
                    </div>
                    <Badge tone="neutral">{c.reporting_basis}</Badge>
                  </div>
                </Card>
              </Link>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
