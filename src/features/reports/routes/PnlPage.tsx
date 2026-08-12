import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Amount, Card, DataTable, ExportMenu, Input, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { supabase } from '@/lib/supabase'
import { keys } from '@/lib/queryKeys'
import type { PnlRow } from '@/lib/database.types'
import type { ReportExport } from '@/lib/exports'

async function fetchPnl(clientId: string, from: string, to: string): Promise<PnlRow[]> {
  const { data, error } = await supabase.rpc('profit_and_loss', {
    p_client_id: clientId,
    p_date_from: from,
    p_date_to: to,
  })
  if (error) throw error
  return data
}

const rowColumns: Column<PnlRow>[] = [
  {
    key: 'code',
    header: 'Code',
    width: 100,
    render: (r) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{r.code}</span>,
  },
  { key: 'name', header: 'Account' },
  { key: 'amount', header: 'Amount', width: 150, align: 'right', render: (r) => <Amount value={r.amount} dashZero /> },
]

function SectionFoot({ label, value, strong }: { label: string; value: number; strong?: boolean }) {
  return (
    <div
      style={{
        display: 'flex',
        justifyContent: 'flex-end',
        gap: 24,
        padding: '13px 20px',
        borderTop: '1px solid var(--border-default)',
        background: strong ? 'var(--sand-200)' : 'var(--sand-100)',
      }}
    >
      <span style={{ font: 'var(--type-label)', color: 'var(--text-secondary)' }}>{label}</span>
      <Amount value={value} />
    </div>
  )
}

export function PnlPage() {
  const client = useActiveClient()
  const year = new Date().getFullYear()
  const [from, setFrom] = useState(`${year}-01-01`)
  const [to, setTo] = useState(new Date().toISOString().slice(0, 10))

  const { data: rows, isPending } = useQuery({
    queryKey: keys.pnl(client.id, from, to),
    queryFn: () => fetchPnl(client.id, from, to),
    enabled: Boolean(from && to),
  })

  const income = useMemo(() => (rows ?? []).filter((r) => r.account_type === 'income'), [rows])
  const expenses = useMemo(() => (rows ?? []).filter((r) => r.account_type === 'expense'), [rows])
  const totalIncome = income.reduce((s, r) => s + Number(r.amount), 0)
  const totalExpenses = expenses.reduce((s, r) => s + Number(r.amount), 0)
  const net = totalIncome - totalExpenses

  return (
    <>
      <TopBar
        title="Profit & loss"
        subtitle="Income and expenses over a period, posted entries only"
        actions={
          <ExportMenu
            disabled={(rows ?? []).length === 0}
            report={(): ReportExport => ({
              filename: `profit-and-loss_${client.code ?? client.name}_${from}_${to}`,
              title: 'Profit & loss',
              subtitle: [client.name, `${from} to ${to}`],
              header: ['Section', 'Code', 'Account', 'Amount'],
              rows: [
                ...income.map((r) => ['Income', r.code, r.name, r.amount] as (string | number)[]),
                ['Income', '', 'Total income', totalIncome.toFixed(2)],
                ...expenses.map((r) => ['Expenses', r.code, r.name, r.amount] as (string | number)[]),
                ['Expenses', '', 'Total expenses', totalExpenses.toFixed(2)],
                ['', '', 'Net income', net.toFixed(2)],
              ],
              numericColumns: [3],
            })}
          />
        }
      />
      <PageBody>
        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-end' }}>
          <Input label="From" type="date" fieldSize="sm" value={from} onChange={(e) => setFrom(e.target.value)} />
          <Input label="To" type="date" fieldSize="sm" value={to} onChange={(e) => setTo(e.target.value)} />
        </div>
        <Card title="Income" padding="none">
          <DataTable
            rows={income}
            columns={rowColumns}
            rowKey={(r) => r.code}
            emptyMessage={isPending ? 'Computing…' : 'No income posted in this range.'}
            dense
          />
          {income.length > 0 && <SectionFoot label="Total income" value={totalIncome} />}
        </Card>
        <Card title="Expenses" padding="none">
          <DataTable
            rows={expenses}
            columns={rowColumns}
            rowKey={(r) => r.code}
            emptyMessage={isPending ? 'Computing…' : 'No expenses posted in this range.'}
            dense
          />
          {expenses.length > 0 && <SectionFoot label="Total expenses" value={totalExpenses} />}
        </Card>
        {(rows ?? []).length > 0 && (
          <Card padding="none">
            <SectionFoot label={net >= 0 ? 'Net income' : 'Net loss'} value={net} strong />
          </Card>
        )}
      </PageBody>
    </>
  )
}
