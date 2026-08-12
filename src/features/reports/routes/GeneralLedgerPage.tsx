import { useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Amount, Card, DataTable, ExportMenu, Input, Select, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { useAccounts } from '@/features/coa/hooks'
import { supabase } from '@/lib/supabase'
import { keys } from '@/lib/queryKeys'
import type { GeneralLedgerRow } from '@/lib/database.types'
import type { ReportExport } from '@/lib/exports'

async function fetchGeneralLedger(
  clientId: string,
  accountId: string,
  from: string,
  to: string,
): Promise<GeneralLedgerRow[]> {
  const { data, error } = await supabase.rpc('general_ledger', {
    p_client_id: clientId,
    p_account_id: accountId,
    p_date_from: from,
    p_date_to: to,
  })
  if (error) throw error
  return data
}

const columns: Column<GeneralLedgerRow>[] = [
  { key: 'entry_date', header: 'Date', width: 110 },
  {
    key: 'entry_no',
    header: 'Entry',
    width: 90,
    render: (r) =>
      r.entry_no !== null ? <span style={{ font: '500 13px/1 var(--font-mono)' }}>JE-{r.entry_no}</span> : <span />,
  },
  { key: 'memo', header: 'Memo' },
  { key: 'source_type', header: 'Source', width: 110 },
  { key: 'debit', header: 'Debit', width: 130, align: 'right', render: (r) => <Amount value={r.debit} dashZero /> },
  { key: 'credit', header: 'Credit', width: 130, align: 'right', render: (r) => <Amount value={r.credit} dashZero /> },
  { key: 'running', header: 'Running', width: 140, align: 'right', render: (r) => <Amount value={r.running} /> },
]

export function GeneralLedgerPage() {
  const client = useActiveClient()
  const { data: accounts } = useAccounts(client.id)
  const [searchParams, setSearchParams] = useSearchParams()
  const accountId = searchParams.get('account') ?? ''
  const year = new Date().getFullYear()
  const [from, setFrom] = useState(`${year}-01-01`)
  const [to, setTo] = useState(new Date().toISOString().slice(0, 10))

  const accountOptions = useMemo(
    () =>
      (accounts ?? [])
        .filter((a) => !a.archived_at || a.id === accountId)
        .map((a) => ({ value: a.id, label: `${a.code} ${a.name}` })),
    [accounts, accountId],
  )
  const account = (accounts ?? []).find((a) => a.id === accountId)

  const { data: rows, isPending } = useQuery({
    queryKey: keys.generalLedger(client.id, accountId, from, to),
    queryFn: () => fetchGeneralLedger(client.id, accountId, from, to),
    enabled: Boolean(accountId && from && to),
  })

  const withMovements = rows ?? []
  const closing = withMovements.length > 0 ? Number(withMovements[withMovements.length - 1].running) : 0

  return (
    <>
      <TopBar
        title="General ledger"
        subtitle="Per-account activity with a running balance — the drill-down behind every statement"
        actions={
          <ExportMenu
            disabled={withMovements.length === 0 || !account}
            report={(): ReportExport => ({
              filename: `general-ledger_${client.code ?? client.name}_${account?.code ?? 'account'}_${from}_${to}`,
              title: `General ledger — ${account?.code ?? ''} ${account?.name ?? ''}`,
              subtitle: [client.name, `${from} to ${to}`],
              header: ['Date', 'Entry', 'Memo', 'Source', 'Debit', 'Credit', 'Running'],
              rows: withMovements.map((r) => [
                r.entry_date,
                r.entry_no !== null ? `JE-${r.entry_no}` : '',
                r.memo,
                r.source_type,
                r.debit,
                r.credit,
                r.running,
              ]),
              numericColumns: [4, 5, 6],
            })}
          />
        }
      />
      <PageBody>
        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-end', flexWrap: 'wrap' }}>
          <div style={{ width: 320 }}>
            <Select
              label="Account"
              fieldSize="sm"
              placeholder="Choose an account"
              options={accountOptions}
              value={accountId}
              onChange={(e) => {
                const next = new URLSearchParams(searchParams)
                if (e.target.value) next.set('account', e.target.value)
                else next.delete('account')
                setSearchParams(next, { replace: true })
              }}
            />
          </div>
          <Input label="From" type="date" fieldSize="sm" value={from} onChange={(e) => setFrom(e.target.value)} />
          <Input label="To" type="date" fieldSize="sm" value={to} onChange={(e) => setTo(e.target.value)} />
        </div>
        <Card padding="none">
          <DataTable
            rows={withMovements}
            columns={columns}
            rowKey={(r) => r.entry_id ?? 'opening'}
            emptyMessage={
              !accountId
                ? 'Choose an account to see its ledger.'
                : isPending
                  ? 'Computing…'
                  : 'No activity for this account in this range.'
            }
            dense
          />
          {withMovements.length > 0 && (
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
              <span style={{ font: 'var(--type-label)', color: 'var(--text-secondary)' }}>Closing balance</span>
              <Amount value={closing} />
            </div>
          )}
        </Card>
      </PageBody>
    </>
  )
}
