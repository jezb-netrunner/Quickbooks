import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Amount, Card, DataTable, ExportMenu, Input, Tabs, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { supabase } from '@/lib/supabase'
import { keys } from '@/lib/queryKeys'
import type { AgingRow } from '@/lib/database.types'
import type { ReportExport } from '@/lib/exports'
import { localToday } from '@/lib/dates'

async function fetchAging(clientId: string, docType: string, asOf: string): Promise<AgingRow[]> {
  const { data, error } = await supabase.rpc('aging', {
    p_client_id: clientId,
    p_doc_type: docType,
    p_as_of: asOf,
  })
  if (error) throw error
  return data
}

export function AgingPage() {
  const client = useActiveClient()
  const [side, setSide] = useState('invoice')
  const [asOf, setAsOf] = useState(localToday())
  const { data: rows, isPending, isError } = useQuery({
    queryKey: keys.aging(client.id, side, asOf),
    queryFn: () => fetchAging(client.id, side, asOf),
    enabled: Boolean(asOf),
  })

  const totals = useMemo(() => {
    const sum = (pick: (r: AgingRow) => string) => (rows ?? []).reduce((s, r) => s + Number(pick(r)), 0)
    return {
      current: sum((r) => r.current_amount),
      d30: sum((r) => r.days_1_30),
      d60: sum((r) => r.days_31_60),
      d90: sum((r) => r.days_61_90),
      over: sum((r) => r.days_over_90),
      total: sum((r) => r.total),
    }
  }, [rows])

  const sideLabel = side === 'invoice' ? 'Receivables' : 'Payables'

  const columns: Column<AgingRow>[] = [
    { key: 'contact_name', header: side === 'invoice' ? 'Customer' : 'Vendor' },
    { key: 'current_amount', header: 'Current', width: 120, align: 'right', render: (r) => <Amount value={r.current_amount} dashZero /> },
    { key: 'days_1_30', header: '1–30', width: 110, align: 'right', render: (r) => <Amount value={r.days_1_30} dashZero /> },
    { key: 'days_31_60', header: '31–60', width: 110, align: 'right', render: (r) => <Amount value={r.days_31_60} dashZero /> },
    { key: 'days_61_90', header: '61–90', width: 110, align: 'right', render: (r) => <Amount value={r.days_61_90} dashZero /> },
    { key: 'days_over_90', header: 'Over 90', width: 110, align: 'right', render: (r) => <Amount value={r.days_over_90} dashZero /> },
    { key: 'total', header: 'Total', width: 130, align: 'right', render: (r) => <Amount value={r.total} /> },
  ]

  function report(): ReportExport {
    return {
      filename: `${side === 'invoice' ? 'ar' : 'ap'}-aging_${client.code ?? client.name}_${asOf}`,
      title: `${sideLabel} aging`,
      subtitle: [client.name, `As of ${asOf}`],
      header: [side === 'invoice' ? 'Customer' : 'Vendor', 'Current', '1-30', '31-60', '61-90', 'Over 90', 'Total'],
      rows: (rows ?? []).map((r) => [
        r.contact_name, r.current_amount, r.days_1_30, r.days_31_60, r.days_61_90, r.days_over_90, r.total,
      ]),
      numericColumns: [1, 2, 3, 4, 5, 6],
    }
  }

  return (
    <>
      <TopBar
        title="AR and AP aging"
        subtitle="Open balances bucketed by days overdue"
        actions={<ExportMenu report={report} disabled={(rows ?? []).length === 0} />}
      />
      <PageBody>
        <div style={{ display: 'flex', gap: 16, alignItems: 'flex-end', justifyContent: 'space-between' }}>
          <Tabs
            value={side}
            onChange={setSide}
            items={[
              { value: 'invoice', label: 'Receivables' },
              { value: 'bill', label: 'Payables' },
            ]}
          />
          <Input label="As of" type="date" fieldSize="sm" value={asOf} onChange={(e) => setAsOf(e.target.value)} />
        </div>
        <Card padding="none">
          <DataTable
            rows={rows ?? []}
            columns={columns}
            rowKey={(r) => r.contact_id}
            emptyMessage={isPending ? 'Computing…' : isError ? 'Could not load this report — check the connection and retry.' : `No open ${sideLabel.toLowerCase()} as of this date.`}
            dense
          />
          {(rows ?? []).length > 0 && (
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 24, padding: '13px 20px', borderTop: '1px solid var(--border-default)', background: 'var(--sand-100)' }}>
              <span style={{ font: 'var(--type-label)', color: 'var(--text-secondary)' }}>Total</span>
              <Amount value={totals.total} />
            </div>
          )}
        </Card>
      </PageBody>
    </>
  )
}
