import { useEffect, type ReactNode } from 'react'

export interface DialogProps {
  open: boolean
  onClose: () => void
  title: string
  description?: string
  width?: number
  footer?: ReactNode
  children?: ReactNode
}

export function Dialog({ open, onClose, title, description, width = 440, footer, children }: DialogProps) {
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  if (!open) return null
  return (
    <div
      className="fis-dialog__scrim"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div className="fis-dialog" role="dialog" aria-modal="true" aria-label={title} style={{ maxWidth: width }}>
        <div className="fis-dialog__head">
          <h3 className="fis-dialog__title">{title}</h3>
          {description && <p className="fis-dialog__desc">{description}</p>}
        </div>
        <div className="fis-dialog__body">{children}</div>
        {footer && <div className="fis-dialog__foot">{footer}</div>}
      </div>
    </div>
  )
}
