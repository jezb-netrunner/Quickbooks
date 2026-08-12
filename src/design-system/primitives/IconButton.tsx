import type { ButtonHTMLAttributes } from 'react'
import { Icon } from './Icon'

export interface IconButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  icon: string
  label: string
  variant?: 'ghost' | 'outline'
  size?: number
}

export function IconButton({ icon, label, variant = 'ghost', size = 17, className, ...rest }: IconButtonProps) {
  const classes = ['fis-iconbtn', variant === 'outline' ? 'fis-iconbtn--outline' : '', className ?? '']
    .filter(Boolean)
    .join(' ')
  return (
    <button type="button" className={classes} aria-label={label} title={label} {...rest}>
      <Icon name={icon} size={size} />
    </button>
  )
}
