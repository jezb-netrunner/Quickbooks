import { useEffect } from 'react'
import { Icon } from './Icon'
import { IconButton } from './IconButton'

export interface ToastProps {
  tone?: 'positive' | 'negative' | 'neutral'
  title: string
  message?: string
  onDismiss: () => void
  autoHideMs?: number
}

const toneIcon = { positive: 'check-circle-2', negative: 'alert-circle', neutral: 'info' } as const
const toneColor = { positive: 'var(--positive)', negative: 'var(--negative)', neutral: 'var(--text-muted)' } as const

export function Toast({ tone = 'positive', title, message, onDismiss, autoHideMs = 5000 }: ToastProps) {
  useEffect(() => {
    if (!autoHideMs) return
    const t = window.setTimeout(onDismiss, autoHideMs)
    return () => window.clearTimeout(t)
  }, [autoHideMs, onDismiss])

  return (
    <div className="fis-toast" role="status">
      <Icon name={toneIcon[tone]} size={17} style={{ color: toneColor[tone], marginTop: 1 }} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div className="fis-toast__title">{title}</div>
        {message && <div className="fis-toast__msg">{message}</div>}
      </div>
      <IconButton icon="x" label="Dismiss" size={14} onClick={onDismiss} />
    </div>
  )
}
