import { useId, type InputHTMLAttributes } from 'react'
import { Icon } from './Icon'

export interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  label?: string
  hint?: string
  error?: string
  iconLeft?: string
  fieldSize?: 'sm' | 'md'
}

export function Input({ label, hint, error, iconLeft, fieldSize = 'md', id, className, ...rest }: InputProps) {
  const autoId = useId()
  const inputId = id ?? autoId
  const controlClasses = [
    'fis-control',
    fieldSize === 'sm' ? 'fis-control--sm' : '',
    error ? 'fis-control--error' : '',
  ]
    .filter(Boolean)
    .join(' ')
  return (
    <div className={['fis-field', className ?? ''].filter(Boolean).join(' ')}>
      {label && (
        <label className="fis-field__label" htmlFor={inputId}>
          {label}
        </label>
      )}
      <div className={controlClasses}>
        {iconLeft && <Icon name={iconLeft} size={15} style={{ color: 'var(--text-muted)' }} />}
        <input
          id={inputId}
          // Scrolling over a focused number field silently changes the value —
          // an accounting app cannot afford accidental amount edits.
          onWheel={rest.type === 'number' ? (e) => e.currentTarget.blur() : undefined}
          inputMode={rest.type === 'number' ? 'decimal' : undefined}
          {...rest}
        />
      </div>
      {error ? (
        <p className="fis-field__error">{error}</p>
      ) : hint ? (
        <p className="fis-field__hint">{hint}</p>
      ) : null}
    </div>
  )
}
