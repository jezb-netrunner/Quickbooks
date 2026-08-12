import type { ReactNode } from 'react'

// Fixed 232px ink sidebar; the page body is the only scroller — per the
// Fiscana portal shell.
export function AppShell({ sidebar, children }: { sidebar: ReactNode; children: ReactNode }) {
  return (
    <div style={{ display: 'flex', height: '100vh', background: 'var(--surface-page)', overflow: 'hidden' }}>
      {sidebar}
      <main style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, position: 'relative' }}>
        {children}
      </main>
    </div>
  )
}

export function TopBar({ title, subtitle, actions }: { title: string; subtitle?: string; actions?: ReactNode }) {
  return (
    <header
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 16,
        padding: '16px 28px',
        background: 'var(--surface-card)',
        borderBottom: '1px solid var(--border-subtle)',
      }}
    >
      <div style={{ flex: 1, minWidth: 0 }}>
        <h1 style={{ font: 'var(--type-h2)', letterSpacing: 'var(--tracking-tight)' }}>{title}</h1>
        {subtitle && <p style={{ marginTop: 3, font: 'var(--type-body-sm)', color: 'var(--text-muted)' }}>{subtitle}</p>}
      </div>
      {actions && <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>{actions}</div>}
    </header>
  )
}

export function PageBody({ children }: { children: ReactNode }) {
  return (
    <div
      style={{
        flex: 1,
        overflowY: 'auto',
        padding: '24px 28px 40px',
        display: 'flex',
        flexDirection: 'column',
        gap: 20,
      }}
    >
      {children}
    </div>
  )
}
