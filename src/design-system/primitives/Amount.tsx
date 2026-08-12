import type { CSSProperties } from 'react'

// THE money primitive (per the Fiscana guide, ported carefully): every figure
// is IBM Plex Mono with tabular numerals so columns align, and negatives use a
// minus sign, never parentheses. Amounts are plain numbers; the currency is
// PHP everywhere (Phase 1 decision), so no symbol noise in dense tables.
const formatter = new Intl.NumberFormat('en-PH', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

export interface AmountProps {
  value: number | string
  size?: 'sm' | 'md' | 'lg'
  muted?: boolean
  /** Render 0 as an em dash — keeps dense report tables scannable. */
  dashZero?: boolean
  style?: CSSProperties
}

const SIZES = { sm: 'var(--text-xs)', md: 'var(--text-sm)', lg: 'var(--text-lg)' } as const

export function Amount({ value, size = 'md', muted, dashZero, style }: AmountProps) {
  const n = typeof value === 'string' ? Number(value) : value
  const base: CSSProperties = {
    font: `500 ${SIZES[size]}/1.3 var(--font-mono)`,
    fontVariantNumeric: 'tabular-nums',
    color: muted ? 'var(--text-muted)' : n < 0 ? 'var(--negative)' : 'var(--text-primary)',
    whiteSpace: 'nowrap',
    ...style,
  }
  if (dashZero && n === 0) {
    return <span style={{ ...base, color: 'var(--text-muted)' }}>—</span>
  }
  const text = n < 0 ? `−${formatter.format(Math.abs(n))}` : formatter.format(n)
  return <span style={base}>{text}</span>
}
