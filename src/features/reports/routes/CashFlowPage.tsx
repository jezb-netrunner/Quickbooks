import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Amount, Card, DataTable, ExportMenu, Input, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { supabase } from '@/lib/supabase'
import { keys } from '@/lib/queryKeys'
import type { CashFlowRow } from '@/lib/database.types'
import type { ReportExport } from '@/lib/exports'
import { localToday } from '@/lib/dates'

async function fetchCashFlow(clientId: string, from: string, to: string): Promise<CashFlowRow[]> {
  const { data, error } = await supabase.rpc('cash_flow_indirect', {
    p_client_id: clientId,
    p_date_from: from,
    p_date_to: to,
  })
  if (error) throw error
  return data
}

const rowColumns: Column<CashFlowRow>[] = [
  { key: 'label', header: 'Item' },
  { key: 'amount', header: 'Amount', width: 150, align: 'right', render: (r) => <Amount value={r.amount} dashZero /> },
]

const SECTIONS = [
  { key: 'operating', title: 'Operating activities', totalLabel: 'Net cash from operating' },
  { key: 'investing', title: 'Investing activities', totalLabel: 'Net cash from investing' },
  { key: 'financing', title: 'Financing activities', totalLabel: 'Net cash from financing' },
] as const

export function CashFlowPage() {
  const client = useActiveClient()
  const year = new Date().getFullYear()
  const [from, setFrom] = useState(`${year}-01-01`)
  const [to, setTo] = useState(localToday())

  const { data: rows, isPending, isError } = useQuery({
    queryKey: keys.cashFlow(client.id, from, to),
    queryFn: () => fetchCashFlow(client.id, from, to),
    enabled: Boolean(from && to),
  })

  const bySection = useMemo(() => {
    const map = new Map<string, CashFlowRow[]>()
    for (const r of rows ?? []) {
      const list = map.get(r.section) ?? []
      list.push(r)
      map.set(r.section, list)
    }
    return map
  }, [rows])

  const netChange = Number(bySection.get('cash')?.[0]?.amount ?? 0)
  const hasData = (rows ?? []).some((r) => r.section !== 'cash' && Number(r.amount) !== 0)

  return (
    <>
      <TopBar
        title="Cash flow"
        subtitle="Indirect method — net income adjusted by balance movements"
        actions={
          <ExportMenu
            disabled={!hasData}
            report={(): ReportExport => ({
              filename: `cash-flow_${client.code ?? client.name}_${from}_${to}`,
              title: 'Statement of cash flows (indirect)',
              subtitle: [client.name, `${from} to ${to}`],
              header: ['Section', 'Item', 'Amount'],
              rows: [
                ...SECTIONS.flatMap((s) => {
                  const items = bySection.get(s.key) ?? []
                  const total = items.reduce((sum, r) => sum + Number(r.amount), 0)
                  return [
                    ...items.map((r) => [s.title, r.label, r.amount] as (string | number)[]),
                    [s.title, s.totalLabel, total.toFixed(2)] as (string | number)[],
                  ]
                }),
                ['', 'Net change in cash', netChange.toFixed(2)],
              ],
              numericColumns: [2],
            })}
          />
        }
      />
      <PageBody>
        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-end' }}>
          <Input label="From" type="date" fieldSize="sm" value={from} onChange={(e) => setFrom(e.target.value)} />
          <Input label="To" type="date" fieldSize="sm" value={to} onChange={(e) => setTo(e.target.value)} />
        </div>
        {SECTIONS.map((s) => {
          const items = bySection.get(s.key) ?? []
          const total = items.reduce((sum, r) => sum + Number(r.amount), 0)
          return (
            <Card key={s.key} title={s.title} padding="none">
              <DataTable
                rows={items}
                columns={rowColumns}
                rowKey={(r) => `${r.section}:${r.label}`}
                emptyMessage={isPending ? 'Computing…' : isError ? 'Could not load this report — check the connection and retry.' : 'No movements in this range.'}
                dense
              />
              {items.length > 0 && (
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
                  <span style={{ font: 'var(--type-label)', color: 'var(--text-secondary)' }}>{s.totalLabel}</span>
                  <Amount value={total} />
                </div>
              )}
            </Card>
          )
        })}
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
              <span style={{ font: 'var(--type-label)', color: 'var(--text-secondary)' }}>Net change in cash</span>
              <Amount value={netChange} />
            </div>
          </Card>
        )}
      </PageBody>
    </>
  )
}
