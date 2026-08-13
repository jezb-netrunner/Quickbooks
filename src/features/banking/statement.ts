import type { BankImportProfile } from '@/lib/database.types'
import type { ParsedBankRow } from './api'

// The browser turns raw CSV cells into {d, m, a} rows using the client's saved
// column mapping; the server re-validates everything and owns dedupe. Columns
// in a profile are 1-based (how people read a spreadsheet).

export type ProfileMapping = Pick<
  BankImportProfile,
  | 'date_col'
  | 'desc_col'
  | 'amount_col'
  | 'debit_col'
  | 'credit_col'
  | 'date_format'
  | 'skip_rows'
  | 'negate'
>

function parseDate(raw: string, format: 'YMD' | 'DMY' | 'MDY'): string | null {
  const parts = raw.trim().split(/[/\-.]/)
  if (parts.length !== 3) return null
  let y: string, m: string, d: string
  if (format === 'YMD') [y, m, d] = parts
  else if (format === 'DMY') [d, m, y] = parts
  else [m, d, y] = parts
  if (y.length === 2) y = `20${y}`
  const yi = Number(y)
  const mi = Number(m)
  const di = Number(d)
  if (!Number.isInteger(yi) || !Number.isInteger(mi) || !Number.isInteger(di)) return null
  if (yi < 1900 || yi > 2999 || mi < 1 || mi > 12 || di < 1 || di > 31) return null
  return `${yi}-${String(mi).padStart(2, '0')}-${String(di).padStart(2, '0')}`
}

// "1,234.56", "(500.00)", "PHP 250" all parse; anything non-numeric is null.
function parseAmount(raw: string): number | null {
  const t = raw.trim()
  if (!t) return null
  const negative = /^\(.*\)$/.test(t) || t.startsWith('-')
  const digits = t.replace(/[^0-9.]/g, '')
  if (!digits) return null
  const n = Number(digits)
  if (!Number.isFinite(n)) return null
  return negative ? -n : n
}

export interface ParsedStatement {
  rows: ParsedBankRow[]
  unparsed: number
}

export function parseStatement(cells: string[][], mapping: ProfileMapping): ParsedStatement {
  const rows: ParsedBankRow[] = []
  let unparsed = 0
  const cell = (row: string[], col: number | null) =>
    col !== null && col >= 1 ? (row[col - 1] ?? '') : ''

  for (const row of cells.slice(mapping.skip_rows)) {
    const d = parseDate(cell(row, mapping.date_col), mapping.date_format)
    let a: number | null
    if (mapping.amount_col !== null) {
      a = parseAmount(cell(row, mapping.amount_col))
    } else {
      // Separate columns are unsigned from the bank's view: credit = money in.
      const credit = parseAmount(cell(row, mapping.credit_col)) ?? 0
      const debit = parseAmount(cell(row, mapping.debit_col)) ?? 0
      a = credit === 0 && debit === 0 ? null : credit - debit
    }
    if (a !== null && mapping.negate) a = -a
    if (d === null || a === null || a === 0) {
      unparsed++
      continue
    }
    rows.push({ d, m: cell(row, mapping.desc_col).trim(), a: Math.round(a * 100) / 100 })
  }
  return { rows, unparsed }
}
