import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Amount, Button, Card, DataTable, Input, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { supabase } from '@/lib/supabase'
import { keys } from '@/lib/queryKeys'
import { downloadCsv } from '@/lib/csv'
import type { TrialBalanceRow } from '@/lib/database.types'

async function fetchTrialBalance(clientId: string, from: string, to: string): Promise<TrialBalanceRow[]> {
  const { data, error } = await supabase.rpc('trial_balance', {
    p_client_id: clientId,
    p_date_from: from,
    p_date_to: to,
  })
  if (error) throw error
  return data
}

export function TrialBalancePage() {
  const client = useActiveClient()
  const year = new Date().getFullYear()
  const [from, setFrom] = useState(`${year}-01-01`)
  const [to, setTo] = useState(new Date().toISOString().slice(0, 10))

  const { data: rows, isPending } = useQuery({
    queryKey: keys.trialBalance(client.id, from, to),
    queryFn: () => fetchTrialBalance(client.id, from, to),
    enabled: Boolean(from && to),
  })

  const withActivity = useMemo(
    () => (rows ?? []).filter((r) => Number(r.total_debit) !== 0 || Number(r.total_credit) !== 0),
    [rows],
  )
  const totals = useMemo(
    () => ({
      debit: withActivity.reduce((s, r) => s + Number(r.total_debit), 0),
      credit: withActivity.reduce((s, r) => s + Number(r.total_credit), 0),
    }),
    [withActivity],
  )

  const columns: Column<TrialBalanceRow>[] = [
    {
      key: 'code',
      header: 'Code',
      width: 100,
      render: (r) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{r.code}</span>,
    },
    { key: 'name', header: 'Account' },
    { key: 'account_type', header: 'Type', width: 100 },
    { key: 'total_debit', header: 'Debit', width: 140, align: 'right', render: (r) => <Amount value={r.total_debit} dashZero /> },
    { key: 'total_credit', header: 'Credit', width: 140, align: 'right', render: (r) => <Amount value={r.total_credit} dashZero /> },
  ]

  return (
    <>
      <TopBar
        title="Trial balance"
        subtitle="Posted entries only, drillable by the journal"
        actions={
          <Button
            size="sm"
            variant="secondary"
            iconLeft="download"
            disabled={withActivity.length === 0}
            onClick={() =>
              downloadCsv(
                `trial-balance_${client.code ?? client.name}_${from}_${to}.csv`,
                ['Code', 'Account', 'Type', 'Debit', 'Credit'],
                withActivity.map((r) => [r.code, r.name, r.account_type, r.total_debit, r.total_credit]),
              )
            }
          >
            Export CSV
          </Button>
        }
      />
      <PageBody>
        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-end' }}>
          <Input label="From" type="date" fieldSize="sm" value={from} onChange={(e) => setFrom(e.target.value)} />
          <Input label="To" type="date" fieldSize="sm" value={to} onChange={(e) => setTo(e.target.value)} />
        </div>
        <Card padding="none">
          <DataTable
            rows={withActivity}
            columns={columns}
            rowKey={(r) => r.account_id}
            emptyMessage={isPending ? 'Computing…' : 'No posted activity in this range.'}
            dense
          />
          {withActivity.length > 0 && (
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
              <span style={{ font: 'var(--type-label)', color: 'var(--text-secondary)' }}>
                {Math.abs(totals.debit - totals.credit) < 0.005 ? 'Balanced' : 'OUT OF BALANCE'}
              </span>
              <Amount value={totals.debit} />
              <Amount value={totals.credit} />
            </div>
          )}
        </Card>
      </PageBody>
    </>
  )
}
