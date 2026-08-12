import type { ButtonHTMLAttributes, ReactNode } from 'react'
import { Icon } from './Icon'

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'ghost' | 'accent' | 'danger'
  size?: 'sm' | 'md'
  iconLeft?: string
  iconRight?: string
  fullWidth?: boolean
  children?: ReactNode
}

export function Button({
  variant = 'primary',
  size = 'md',
  iconLeft,
  iconRight,
  fullWidth,
  className,
  children,
  type = 'button',
  ...rest
}: ButtonProps) {
  const classes = [
    'fis-btn',
    `fis-btn--${variant}`,
    `fis-btn--${size}`,
    fullWidth ? 'fis-btn--full' : '',
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
  const iconSize = size === 'sm' ? 14 : 15
  return (
    <button type={type} className={classes} {...rest}>
      {iconLeft && <Icon name={iconLeft} size={iconSize} />}
      {children}
      {iconRight && <Icon name={iconRight} size={iconSize} />}
    </button>
  )
}
