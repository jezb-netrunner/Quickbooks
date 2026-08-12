import type { ReactNode } from 'react'
import { Card } from '@/design-system'

// Shared centered layout for the signed-out pages.
export function AuthCard({ title, subtitle, children }: { title: string; subtitle?: string; children: ReactNode }) {
  return (
    <div
      style={{
        minHeight: '100vh',
        display: 'grid',
        placeItems: 'center',
        background: 'var(--surface-page)',
        padding: 24,
      }}
    >
      <div style={{ width: '100%', maxWidth: 400, display: 'flex', flexDirection: 'column', gap: 20 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, justifyContent: 'center' }}>
          <span
            style={{
              fontFamily: 'var(--font-display)',
              fontWeight: 600,
              fontSize: 24,
              letterSpacing: '-0.03em',
              color: 'var(--text-primary)',
            }}
          >
            Larkspur
          </span>
          <span style={{ width: 8, height: 8, borderRadius: 2, background: 'var(--amber-500)' }} />
        </div>
        <Card title={title} subtitle={subtitle}>
          {children}
        </Card>
      </div>
    </div>
  )
}

export function FormError({ message }: { message: string | null }) {
  if (!message) return null
  return (
    <p
      role="alert"
      style={{
        font: 'var(--type-body-sm)',
        color: 'var(--clay-600)',
        background: 'var(--clay-100)',
        borderRadius: 'var(--radius-md)',
        padding: '10px 12px',
      }}
    >
      {message}
    </p>
  )
}
