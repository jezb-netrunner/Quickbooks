import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Amount, Card, DataTable, ExportMenu, Input, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { supabase } from '@/lib/supabase'
import { keys } from '@/lib/queryKeys'
import type { BalanceSheetRow } from '@/lib/database.types'
import type { ReportExport } from '@/lib/exports'

async function fetchBalanceSheet(clientId: string, asOf: string): Promise<BalanceSheetRow[]> {
  const { data, error } = await supabase.rpc('balance_sheet', {
    p_client_id: clientId,
    p_as_of: asOf,
  })
  if (error) throw error
  return data
}

const rowColumns: Column<BalanceSheetRow>[] = [
  {
    key: 'code',
    header: 'Code',
    width: 100,
    render: (r) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{r.code}</span>,
  },
  { key: 'name', header: 'Account' },
  { key: 'balance', header: 'Balance', width: 150, align: 'right', render: (r) => <Amount value={r.balance} dashZero /> },
]

function Section({
  title,
  rows,
  totalLabel,
  pending,
}: {
  title: string
  rows: BalanceSheetRow[]
  totalLabel: string
  pending: boolean
}) {
  const total = rows.reduce((s, r) => s + Number(r.balance), 0)
  return (
    <Card title={title} padding="none">
      <DataTable
        rows={rows}
        columns={rowColumns}
        rowKey={(r) => r.code}
        emptyMessage={pending ? 'Computing…' : `No ${title.toLowerCase()} balances.`}
        dense
      />
      {rows.length > 0 && (
        <div
          style={{
            display: 'flex',
            justifyContent: 'flex-end',
            gap: 24,
            padding: '13px 20px',
            borderTop: '1px solid var(--border-default)',
            background: 'var(--sand-100)',
          }}
        >
          <span style={{ font: 'var(--type-label)', color: 'var(--text-secondary)' }}>{totalLabel}</span>
          <Amount value={total} />
        </div>
      )}
    </Card>
  )
}

export function BalanceSheetPage() {
  const client = useActiveClient()
  const [asOf, setAsOf] = useState(new Date().toISOString().slice(0, 10))

  const { data: rows, isPending } = useQuery({
    queryKey: keys.balanceSheet(client.id, asOf),
    queryFn: () => fetchBalanceSheet(client.id, asOf),
    enabled: Boolean(asOf),
  })

  const assets = useMemo(() => (rows ?? []).filter((r) => r.account_type === 'asset'), [rows])
  const liabilities = useMemo(() => (rows ?? []).filter((r) => r.account_type === 'liability'), [rows])
  const equity = useMemo(() => (rows ?? []).filter((r) => r.account_type === 'equity'), [rows])
  const totalAssets = assets.reduce((s, r) => s + Number(r.balance), 0)
  const totalLiabEquity =
    liabilities.reduce((s, r) => s + Number(r.balance), 0) + equity.reduce((s, r) => s + Number(r.balance), 0)
  const balanced = Math.abs(totalAssets - totalLiabEquity) < 0.005

  return (
    <>
      <TopBar
        title="Balance sheet"
        subtitle="Cumulative balances; lifetime earnings appear as one equity row"
        actions={
          <ExportMenu
            disabled={(rows ?? []).length === 0}
            report={(): ReportExport => ({
              filename: `balance-sheet_${client.code ?? client.name}_${asOf}`,
              title: 'Balance sheet',
              subtitle: [client.name, `As of ${asOf}`],
              header: ['Section', 'Code', 'Account', 'Balance'],
              rows: [
                ...assets.map((r) => ['Assets', r.code, r.name, r.balance] as (string | number)[]),
                ['Assets', '', 'Total assets', totalAssets.toFixed(2)],
                ...liabilities.map((r) => ['Liabilities', r.code, r.name, r.balance] as (string | number)[]),
                ...equity.map((r) => ['Equity', r.code, r.name, r.balance] as (string | number)[]),
                ['', '', 'Total liabilities and equity', totalLiabEquity.toFixed(2)],
              ],
              numericColumns: [3],
            })}
          />
        }
      />
      <PageBody>
        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-end' }}>
          <Input label="As of" type="date" fieldSize="sm" value={asOf} onChange={(e) => setAsOf(e.target.value)} />
        </div>
        <Section title="Assets" rows={assets} totalLabel="Total assets" pending={isPending} />
        <Section title="Liabilities" rows={liabilities} totalLabel="Total liabilities" pending={isPending} />
        <Section title="Equity" rows={equity} totalLabel="Total equity" pending={isPending} />
        {(rows ?? []).length > 0 && (
          <Card padding="none">
            <div
              style={{
                display: 'flex',
                justifyContent: 'flex-end',
                gap: 24,
                padding: '13px 20px',
                background: 'var(--sand-200)',
              }}
            >
              <span style={{ font: 'var(--type-label)', color: 'var(--text-secondary)' }}>
                {balanced ? 'Assets = liabilities + equity' : 'OUT OF BALANCE'}
              </span>
              <Amount value={totalAssets} />
              <Amount value={totalLiabEquity} />
            </div>
          </Card>
        )}
      </PageBody>
    </>
  )
}
