import type { ReactNode } from 'react'

export interface CardProps {
  title?: ReactNode
  subtitle?: ReactNode
  action?: ReactNode
  tone?: 'default' | 'sunken' | 'ink'
  padding?: 'md' | 'none'
  className?: string
  children?: ReactNode
}

export function Card({ title, subtitle, action, tone = 'default', padding = 'md', className, children }: CardProps) {
  const classes = ['fis-card', tone !== 'default' ? `fis-card--${tone}` : '', className ?? '']
    .filter(Boolean)
    .join(' ')
  return (
    <section className={classes}>
      {(title || action) && (
        <header className="fis-card__header">
          <div>
            {title && <h3 className="fis-card__title">{title}</h3>}
            {subtitle && <p className="fis-card__subtitle">{subtitle}</p>}
          </div>
          {action}
        </header>
      )}
      <div className={padding === 'none' ? 'fis-card__body--none' : 'fis-card__body'}>{children}</div>
    </section>
  )
}
