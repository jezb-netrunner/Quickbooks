import type { InputHTMLAttributes } from 'react'

export interface CheckboxProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string
  description?: string
}

export function Checkbox({ label, description, className, ...rest }: CheckboxProps) {
  return (
    <label className={['fis-check', className ?? ''].filter(Boolean).join(' ')}>
      <input type="checkbox" {...rest} />
      <span>
        <span className="fis-check__label">{label}</span>
        {description && <span className="fis-check__desc">{description}</span>}
      </span>
    </label>
  )
}
