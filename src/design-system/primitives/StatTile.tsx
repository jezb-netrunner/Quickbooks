import type { ReactNode } from 'react'
import { Amount } from './Amount'
import { Icon } from './Icon'

// The dashboard KPI unit from the Fiscana kit: label overline, big mono
// figure, optional footnote; tone="ink" for the one hero figure per screen.
export interface StatTileProps {
  label: string
  value: number | string
  footnote?: ReactNode
  icon?: string
  tone?: 'default' | 'ink'
  /** Render the value as plain text instead of a money amount. */
  plain?: boolean
}

export function StatTile({ label, value, footnote, icon, tone = 'default', plain }: StatTileProps) {
  const ink = tone === 'ink'
  return (
    <div
      style={{
        background: ink ? 'var(--surface-ink)' : 'var(--surface-card)',
        border: `1px solid ${ink ? 'var(--ink-700)' : 'var(--border-subtle)'}`,
        borderRadius: 'var(--radius-lg)',
        boxShadow: 'var(--shadow-sm)',
        padding: '16px 18px',
        display: 'flex',
        flexDirection: 'column',
        gap: 8,
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
        <span
          style={{
            font: 'var(--type-overline)',
            letterSpacing: 'var(--tracking-caps)',
            textTransform: 'uppercase',
            color: ink ? 'var(--ink-300)' : 'var(--text-muted)',
          }}
        >
          {label}
        </span>
        {icon && <Icon name={icon} size={16} style={{ color: ink ? 'var(--ink-400)' : 'var(--text-muted)' }} />}
      </div>
      {plain ? (
        <span
          style={{
            font: '600 var(--text-xl)/1.2 var(--font-display)',
            letterSpacing: 'var(--tracking-snug)',
            color: ink ? 'var(--sand-100)' : 'var(--text-primary)',
          }}
        >
          {value}
        </span>
      ) : (
        <Amount value={value} size="lg" style={ink ? { color: 'var(--sand-100)' } : undefined} />
      )}
      {footnote && (
        <span style={{ font: 'var(--type-label)', color: ink ? 'var(--ink-300)' : 'var(--text-muted)' }}>
          {footnote}
        </span>
      )}
    </div>
  )
}
