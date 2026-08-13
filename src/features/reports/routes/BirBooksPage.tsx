import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Amount, Card, DataTable, ExportMenu, Input, Select, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { supabase } from '@/lib/supabase'
import { keys } from '@/lib/queryKeys'
import type { ReportExport } from '@/lib/exports'
import { localToday } from '@/lib/dates'

// One page, five books. Each book definition maps an RPC to its columnar
// layout, the same layout the export produces — the loose-leaf format.
type BookKey = 'sales' | 'purchases' | 'cash_receipts' | 'cash_disbursements' | 'general_journal'

interface BookDef {
  key: BookKey
  label: string
  rpc: 'sales_book' | 'purchases_book' | 'cash_receipts_book' | 'cash_disbursements_book' | 'general_journal_book'
  header: string[]
  numericFrom: number
  toRow: (r: Record<string, unknown>) => (string | number)[]
  rowKey: (r: Record<string, unknown>) => string
}

const asS = (v: unknown) => (v == null ? '' : String(v))

const BOOKS: BookDef[] = [
  {
    key: 'sales',
    label: 'Sales journal',
    rpc: 'sales_book',
    header: ['Date', 'Invoice', 'Customer', 'TIN', 'Status', 'Gross', 'Exempt', 'Zero-rated', 'Taxable', 'Output VAT'],
    numericFrom: 5,
    toRow: (r) => [asS(r.doc_date), `INV-${asS(r.doc_no)}`, asS(r.customer), asS(r.tin), asS(r.status), asS(r.gross), asS(r.exempt), asS(r.zero_rated), asS(r.taxable), asS(r.output_vat)],
    rowKey: (r) => `s${asS(r.doc_no)}`,
  },
  {
    key: 'purchases',
    label: 'Purchases journal',
    rpc: 'purchases_book',
    header: ['Date', 'Bill', 'Supplier', 'TIN', 'Status', 'Gross', 'Exempt', 'Taxable', 'Input VAT'],
    numericFrom: 5,
    toRow: (r) => [asS(r.doc_date), `BILL-${asS(r.doc_no)}`, asS(r.supplier), asS(r.tin), asS(r.status), asS(r.gross), asS(r.exempt), asS(r.taxable), asS(r.input_vat)],
    rowKey: (r) => `p${asS(r.doc_no)}`,
  },
  {
    key: 'cash_receipts',
    label: 'Cash receipts book',
    rpc: 'cash_receipts_book',
    header: ['Date', 'Entry', 'Source', 'Memo', 'Cash (Dr)', 'CWT (Dr)', 'Sundry (Dr)', 'AR (Cr)', 'Sales (Cr)', 'Output VAT (Cr)', 'Sundry (Cr)'],
    numericFrom: 4,
    toRow: (r) => [asS(r.entry_date), `JE-${asS(r.entry_no)}`, asS(r.source_type), asS(r.memo), asS(r.cash), asS(r.cwt), asS(r.sundry_debit), asS(r.ar_credit), asS(r.sales), asS(r.output_vat), asS(r.sundry_credit)],
    rowKey: (r) => `cr${asS(r.entry_no)}`,
  },
  {
    key: 'cash_disbursements',
    label: 'Cash disbursements book',
    rpc: 'cash_disbursements_book',
    header: ['Date', 'Entry', 'Source', 'Memo', 'AP (Dr)', 'Purchases (Dr)', 'Input VAT (Dr)', 'Sundry (Dr)', 'Cash (Cr)', 'EWT (Cr)', 'Sundry (Cr)'],
    numericFrom: 4,
    toRow: (r) => [asS(r.entry_date), `JE-${asS(r.entry_no)}`, asS(r.source_type), asS(r.memo), asS(r.ap_debit), asS(r.purchases), asS(r.input_vat), asS(r.sundry_debit), asS(r.cash), asS(r.ewt), asS(r.sundry_credit)],
    rowKey: (r) => `cd${asS(r.entry_no)}`,
  },
  {
    key: 'general_journal',
    label: 'General journal',
    rpc: 'general_journal_book',
    header: ['Date', 'Entry', 'Source', 'Memo', 'Code', 'Account', 'Debit', 'Credit'],
    numericFrom: 6,
    toRow: (r) => [asS(r.entry_date), `JE-${asS(r.entry_no)}`, asS(r.source_type), asS(r.memo), asS(r.code), asS(r.account), asS(r.debit), asS(r.credit)],
    rowKey: (r) => `gj${asS(r.entry_no)}-${asS(r.line_no)}`,
  },
]

export function BirBooksPage() {
  const client = useActiveClient()
  const year = new Date().getFullYear()
  const [bookKey, setBookKey] = useState<BookKey>('sales')
  const [from, setFrom] = useState(`${year}-01-01`)
  const [to, setTo] = useState(localToday())
  const book = BOOKS.find((b) => b.key === bookKey) as BookDef

  const { data: rows, isPending, isError } = useQuery({
    queryKey: keys.birBook(client.id, book.key, from, to),
    queryFn: async () => {
      const { data, error } = await supabase.rpc(book.rpc, {
        p_client_id: client.id,
        p_date_from: from,
        p_date_to: to,
      })
      if (error) throw error
      return data as unknown as Record<string, unknown>[]
    },
    enabled: Boolean(from && to),
  })

  const columns: Column<Record<string, unknown>>[] = useMemo(
    () =>
      book.header.map((h, i) => ({
        key: `${book.key}:${h}`,
        header: h,
        align: i >= book.numericFrom ? ('right' as const) : ('left' as const),
        render: (r: Record<string, unknown>) => {
          const v = book.toRow(r)[i]
          if (i >= book.numericFrom) return <Amount value={Number(v) || 0} dashZero />
          return <span style={i <= 1 ? { font: '400 12.5px/1.3 var(--font-mono)' } : undefined}>{String(v)}</span>
        },
      })),
    [book],
  )

  return (
    <>
      <TopBar
        title="BIR books"
        subtitle="The books of accounts in columnar form, straight from the ledger"
        actions={
          <ExportMenu
            disabled={(rows ?? []).length === 0}
            report={(): ReportExport => ({
              filename: `${book.key}_${client.code ?? client.name}_${from}_${to}`,
              title: book.label,
              subtitle: [client.name, `${from} to ${to}`],
              header: book.header,
              rows: (rows ?? []).map(book.toRow),
              numericColumns: book.header.map((_, i) => i).filter((i) => i >= book.numericFrom),
            })}
          />
        }
      />
      <PageBody>
        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-end', flexWrap: 'wrap' }}>
          <div style={{ width: 240 }}>
            <Select
              label="Book"
              fieldSize="sm"
              options={BOOKS.map((b) => ({ value: b.key, label: b.label }))}
              value={bookKey}
              onChange={(e) => setBookKey(e.target.value as BookKey)}
            />
          </div>
          <Input label="From" type="date" fieldSize="sm" value={from} onChange={(e) => setFrom(e.target.value)} />
          <Input label="To" type="date" fieldSize="sm" value={to} onChange={(e) => setTo(e.target.value)} />
        </div>
        <Card padding="none">
          <DataTable
            rows={rows ?? []}
            columns={columns}
            rowKey={book.rowKey}
            emptyMessage={isPending ? 'Computing…' : isError ? 'Could not load this report — check the connection and retry.' : 'Nothing in this book for the range.'}
            dense
          />
        </Card>
        <p style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>
          The general ledger book is the General ledger screen; the trial balance backs the ledger summary.
          Cash sales appear in the cash receipts book; the sales journal lists every issued invoice.
        </p>
      </PageBody>
    </>
  )
}
