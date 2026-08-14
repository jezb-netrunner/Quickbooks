// RFC 4180 parse for bank statement imports: quoted fields, embedded commas,
// escaped quotes, CRLF or LF. Returns rows of raw cell strings; blank lines
// are dropped. No streaming — statements are small files.
export function parseCsv(text: string): string[][] {
  const rows: string[][] = []
  let row: string[] = []
  let field = ''
  let inQuotes = false
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          field += '"'
          i++
        } else {
          inQuotes = false
        }
      } else {
        field += ch
      }
    } else if (ch === '"') {
      inQuotes = true
    } else if (ch === ',') {
      row.push(field)
      field = ''
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && text[i + 1] === '\n') i++
      row.push(field)
      rows.push(row)
      row = []
      field = ''
    } else {
      field += ch
    }
  }
  if (field !== '' || row.length > 0) {
    row.push(field)
    rows.push(row)
  }
  return rows.filter((r) => r.some((c) => c.trim() !== ''))
}

// Escape one CSV cell. Two jobs:
//  1. Formula/DDE injection: a cell whose first character is = + - @ TAB or CR
//     is executed by Excel/Sheets when the file is opened. Prefix such a cell
//     with a single quote so it is shown literally. Genuine numbers (typed
//     numbers, or numeric strings like "-1234.50") are never formulas and are
//     left untouched so negative amounts still read as numbers.
//  2. RFC 4180 quoting for cells containing quotes, commas, or newlines.
export function csvCell(v: string | number): string {
  let s = String(v)
  const isNumeric = typeof v === 'number' || /^-?\d+(\.\d+)?$/.test(s)
  if (!isNumeric && /^[=+\-@\t\r]/.test(s)) s = "'" + s
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
}

// Minimal CSV download for report exports (README: every report exportable).
export function downloadCsv(filename: string, header: string[], rows: (string | number)[][]) {
  const body = [header, ...rows].map((r) => r.map(csvCell).join(',')).join('\n')
  const blob = new Blob(['﻿' + body], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}
