import { useId, type SelectHTMLAttributes } from 'react'

export type SelectOption = string | { value: string; label: string }

export interface SelectProps extends SelectHTMLAttributes<HTMLSelectElement> {
  label?: string
  options: SelectOption[]
  placeholder?: string
  fieldSize?: 'sm' | 'md'
  error?: string
}

export function Select({ label, options, placeholder, fieldSize = 'md', error, id, className, ...rest }: SelectProps) {
  const autoId = useId()
  const selectId = id ?? autoId
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
        <label className="fis-field__label" htmlFor={selectId}>
          {label}
        </label>
      )}
      <div className={controlClasses}>
        <select id={selectId} {...rest}>
          {placeholder && <option value="">{placeholder}</option>}
          {options.map((o) => {
            const value = typeof o === 'string' ? o : o.value
            const text = typeof o === 'string' ? o : o.label
            return (
              <option key={value} value={value}>
                {text}
              </option>
            )
          })}
        </select>
      </div>
      {error && <p className="fis-field__error">{error}</p>}
    </div>
  )
}
