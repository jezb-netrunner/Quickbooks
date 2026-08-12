import type { ReactNode } from 'react'

export interface BadgeProps {
  tone?: 'positive' | 'warning' | 'negative' | 'ink' | 'neutral'
  dot?: boolean
  children: ReactNode
}

export function Badge({ tone = 'neutral', dot, children }: BadgeProps) {
  return (
    <span className={`fis-badge fis-badge--${tone}`}>
      {dot && <span className="fis-badge__dot" aria-hidden />}
      {children}
    </span>
  )
}

export function Tag({ children }: { children: ReactNode }) {
  return <span className="fis-tag">{children}</span>
}
