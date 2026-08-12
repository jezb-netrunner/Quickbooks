import { NavLink, useNavigate } from 'react-router-dom'
import { Icon, IconButton } from '@/design-system'
import { useAuth } from '@/auth/AuthProvider'
import { signOut } from '@/auth/api'
import { ClientSwitcher } from './ClientSwitcher'

interface NavItem {
  to: string
  label: string
  icon: string
  end?: boolean
}

export type NavEntry = NavItem | { heading: string }

const navLinkStyle = (on: boolean) =>
  ({
    display: 'flex',
    alignItems: 'center',
    gap: 10,
    padding: '9px 10px',
    width: '100%',
    background: on ? 'var(--ink-700)' : 'transparent',
    borderRadius: 'var(--radius-md)',
    color: on ? 'var(--sand-100)' : 'var(--ink-300)',
    font: 'var(--weight-medium) var(--text-sm)/1 var(--font-sans)',
    textDecoration: 'none',
    transition: 'background var(--dur-fast) var(--ease-standard), color var(--dur-fast) var(--ease-standard)',
  }) as const

export function Sidebar({ items, activeClientId }: { items: NavEntry[]; activeClientId?: string }) {
  const { session } = useAuth()
  const navigate = useNavigate()
  const meta = session?.user.user_metadata as { full_name?: string } | undefined
  const displayName = meta?.full_name || session?.user.email || 'Account'
  const initials = displayName
    .split(/\s+/)
    .map((p) => p.charAt(0))
    .join('')
    .slice(0, 2)
    .toUpperCase()

  return (
    <nav
      style={{
        width: 232,
        flex: '0 0 232px',
        background: 'var(--surface-ink)',
        display: 'flex',
        flexDirection: 'column',
        padding: '20px 12px',
        gap: 26,
      }}
    >
      <div style={{ padding: '0 10px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <span
          style={{
            fontFamily: 'var(--font-display)',
            fontWeight: 600,
            fontSize: 21,
            letterSpacing: '-0.03em',
            color: 'var(--sand-100)',
          }}
        >
          Larkspur
        </span>
        <span style={{ width: 7, height: 7, borderRadius: 2, background: 'var(--amber-500)' }} />
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 2, overflowY: 'auto', minHeight: 0 }}>
        {items.map((item) =>
          'heading' in item ? (
            <span
              key={`h:${item.heading}`}
              style={{
                padding: '12px 10px 4px',
                font: 'var(--type-overline)',
                letterSpacing: 'var(--tracking-caps)',
                textTransform: 'uppercase',
                color: 'var(--ink-400)',
              }}
            >
              {item.heading}
            </span>
          ) : (
            <NavLink key={item.to} to={item.to} end={item.end} style={({ isActive }) => navLinkStyle(isActive)}>
              <Icon name={item.icon} size={17} />
              <span style={{ flex: 1 }}>{item.label}</span>
            </NavLink>
          ),
        )}
      </div>

      <div style={{ marginTop: 'auto', display: 'flex', flexDirection: 'column', gap: 14 }}>
        <ClientSwitcher activeClientId={activeClientId} />
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 10px' }}>
          <span
            style={{
              width: 30,
              height: 30,
              borderRadius: 'var(--radius-sm)',
              background: 'var(--ink-600)',
              display: 'grid',
              placeItems: 'center',
              font: '600 12px/1 var(--font-display)',
              color: 'var(--sand-100)',
            }}
          >
            {initials}
          </span>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div
              style={{
                font: 'var(--weight-medium) var(--text-xs)/1.3 var(--font-sans)',
                color: 'var(--sand-100)',
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
              }}
            >
              {displayName}
            </div>
          </div>
          <IconButton
            icon="log-out"
            label="Sign out"
            size={15}
            style={{ color: 'var(--ink-400)' }}
            onClick={() => {
              void signOut().then(() => navigate('/login'))
            }}
          />
        </div>
      </div>
    </nav>
  )
}
