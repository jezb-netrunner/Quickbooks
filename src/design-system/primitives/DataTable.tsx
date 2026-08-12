import type { ReactNode } from 'react'

export interface Column<T> {
  key: string
  header: string
  width?: number
  align?: 'left' | 'right'
  render?: (row: T) => ReactNode
}

export interface DataTableProps<T> {
  rows: T[]
  columns: Column<T>[]
  rowKey: (row: T) => string
  onRowClick?: (row: T) => void
  emptyMessage?: string
  dense?: boolean
}

export function DataTable<T>({ rows, columns, rowKey, onRowClick, emptyMessage, dense }: DataTableProps<T>) {
  if (rows.length === 0) {
    return <div className="fis-table__empty">{emptyMessage ?? 'Nothing here yet.'}</div>
  }
  return (
    <div className="fis-table-wrap">
      <table className={`fis-table${dense ? ' fis-table--dense' : ''}`}>
        <thead>
          <tr>
            {columns.map((c) => (
              <th key={c.key} style={{ width: c.width, textAlign: c.align ?? 'left' }}>
                {c.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr
              key={rowKey(row)}
              className={onRowClick ? 'fis-table__row--click' : undefined}
              onClick={onRowClick ? () => onRowClick(row) : undefined}
            >
              {columns.map((c) => (
                <td key={c.key} style={{ textAlign: c.align ?? 'left' }}>
                  {c.render ? c.render(row) : String((row as Record<string, unknown>)[c.key] ?? '')}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
