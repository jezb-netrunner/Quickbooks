import { useMemo } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Amount, Badge, Button, Card, DataTable, Icon, StatTile, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { useActiveClient } from './ClientLayout'
import { supabase } from '@/lib/supabase'
import { keys } from '@/lib/queryKeys'

interface DashboardData {
  cash: number
  income_mtd: number
  expense_mtd: number
  net_series: { month: string; net: number }[]
  ar_open: number
  ar_overdue: number
  ar_overdue_count: number
  ap_open: number
  draft_entries: number
  draft_documents: number
  recent: { entry_no: number; entry_date: string; memo: string; source_type: string; amount: number }[]
}

async function fetchDashboard(clientId: string): Promise<DashboardData> {
  const { data, error } = await supabase.rpc('client_dashboard', { p_client_id: clientId })
  if (error) throw error
  return data as unknown as DashboardData
}

const MONTH_SHORT = ['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D']

// The mockup's Net position bars, ported: ink bars, the current month in
// amber, mono month letters. Flat color only, no chart library.
function NetBars({ series }: { series: { month: string; net: number }[] }) {
  const months = useMemo(() => {
    const map = new Map(series.map((s) => [s.month, Number(s.net)]))
    const out: { key: string; label: string; net: number }[] = []
    const d = new Date()
    d.setDate(1)
    d.setMonth(d.getMonth() - 11)
    for (let i = 0; i < 12; i++) {
      const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
      out.push({ key, label: MONTH_SHORT[d.getMonth()], net: map.get(key) ?? 0 })
      d.setMonth(d.getMonth() + 1)
    }
    return out
  }, [series])

  const peak = Math.max(1, ...months.map((m) => Math.abs(m.net)))
  return (
    <div style={{ display: 'flex', alignItems: 'flex-end', gap: 8, height: 132 }}>
      {months.map((m, i) => {
        const h = Math.round((Math.abs(m.net) / peak) * 112)
        const last = i === months.length - 1
        return (
          <div key={m.key} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 7 }} title={`${m.key}: ${m.net.toFixed(2)}`}>
            <div
              style={{
                width: '100%',
                height: Math.max(h, 2),
                background: m.net < 0 ? 'var(--clay-500)' : last ? 'var(--amber-500)' : 'var(--ink-800)',
                opacity: m.net < 0 || last ? 1 : 0.14 + i * 0.055,
                borderRadius: 'var(--radius-xs)',
              }}
            />
            <span style={{ font: '500 10px/1 var(--font-mono)', color: 'var(--text-muted)' }}>{m.label}</span>
          </div>
        )
      })}
    </div>
  )
}

const SOURCE_LABEL: Record<string, string> = {
  manual: 'Manual',
  opening_balance: 'Opening balance',
  reversal: 'Reversal',
  invoice: 'Invoice',
  bill: 'Bill',
  receipt: 'Receipt',
  disbursement: 'Disbursement',
}

export function ClientOverviewPage() {
  const client = useActiveClient()
  const { data } = useQuery({
    queryKey: keys.dashboard(client.id),
    queryFn: () => fetchDashboard(client.id),
    refetchInterval: 60_000,
  })

  const attention = useMemo(() => {
    if (!data) return []
    const items: { icon: string; tone: 'warning' | 'negative'; title: string; to: string }[] = []
    if (data.ar_overdue_count > 0) {
      items.push({
        icon: 'alert-circle',
        tone: 'negative',
        title: `${data.ar_overdue_count} ${data.ar_overdue_count === 1 ? 'invoice is' : 'invoices are'} overdue`,
        to: `/c/${client.id}/invoices`,
      })
    }
    if (data.draft_documents > 0) {
      items.push({
        icon: 'file-check',
        tone: 'warning',
        title: `${data.draft_documents} draft ${data.draft_documents === 1 ? 'document' : 'documents'} not yet issued`,
        to: `/c/${client.id}/invoices`,
      })
    }
    if (data.draft_entries > 0) {
      items.push({
        icon: 'book-open',
        tone: 'warning',
        title: `${data.draft_entries} draft journal ${data.draft_entries === 1 ? 'entry' : 'entries'} not yet posted`,
        to: `/c/${client.id}/journal`,
      })
    }
    return items
  }, [data, client.id])

  const recentColumns: Column<DashboardData['recent'][number]>[] = [
    { key: 'entry_no', header: 'No.', width: 80, render: (r) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>JE-{r.entry_no}</span> },
    { key: 'entry_date', header: 'Date', width: 110, render: (r) => <span style={{ font: '400 13px/1 var(--font-mono)' }}>{r.entry_date}</span> },
    { key: 'memo', header: 'Memo', render: (r) => r.memo || '—' },
    { key: 'source_type', header: 'Source', width: 130, render: (r) => SOURCE_LABEL[r.source_type] ?? r.source_type },
    { key: 'amount', header: 'Amount', width: 130, align: 'right', render: (r) => <Amount value={r.amount ?? 0} /> },
  ]

  return (
    <>
      <TopBar
        title={client.name}
        subtitle={client.archived_at ? 'Archived — the books are read-only' : 'Live from the posted ledger and open subledgers'}
      />
      <PageBody>
        {client.archived_at && (
          <div>
            <Badge tone="warning" dot>Archived</Badge>
          </div>
        )}
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(210px, 1fr))', gap: 16 }}>
          <StatTile label="Cash position" value={data?.cash ?? 0} icon="wallet" footnote="all 1000-series accounts" />
          <StatTile
            label="Receivables open"
            value={data?.ar_open ?? 0}
            icon="receipt"
            footnote={
              (data?.ar_overdue_count ?? 0) > 0 ? (
                <span style={{ color: 'var(--negative)' }}>
                  {data?.ar_overdue_count} overdue · <Amount value={data?.ar_overdue ?? 0} size="sm" style={{ color: 'var(--negative)' }} />
                </span>
              ) : (
                'nothing overdue'
              )
            }
          />
          <StatTile label="Payables open" value={data?.ap_open ?? 0} icon="credit-card" footnote="what this client owes" />
          <StatTile
            label="Net income MTD"
            value={(data?.income_mtd ?? 0) - (data?.expense_mtd ?? 0)}
            tone="ink"
            icon="landmark"
            footnote={
              <span>
                in <Amount value={data?.income_mtd ?? 0} size="sm" style={{ color: 'var(--ink-300)' }} /> · out{' '}
                <Amount value={data?.expense_mtd ?? 0} size="sm" style={{ color: 'var(--ink-300)' }} />
              </span>
            }
          />
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: '1.6fr 1fr', gap: 16, alignItems: 'start' }}>
          <Card title="Net position" subtitle="Income minus expenses, rolling 12 months">
            <NetBars series={data?.net_series ?? []} />
          </Card>
          <Card title="Needs your attention" subtitle={attention.length === 0 ? 'All clear' : `${attention.length} ${attention.length === 1 ? 'item' : 'items'}`}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              {attention.length === 0 ? (
                <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-secondary)' }}>
                  Nothing is waiting on you. New drafts and overdue invoices appear here.
                </p>
              ) : (
                attention.map((item, i) => (
                  <div key={i} style={{ display: 'flex', gap: 10, alignItems: 'flex-start', paddingBottom: i < attention.length - 1 ? 12 : 0, borderBottom: i < attention.length - 1 ? '1px solid var(--border-subtle)' : 'none' }}>
                    <Icon name={item.icon} size={17} style={{ marginTop: 1, color: item.tone === 'negative' ? 'var(--negative)' : 'var(--warning)' }} />
                    <div style={{ flex: 1 }}>
                      <div style={{ font: 'var(--weight-medium) var(--text-sm)/1.4 var(--font-sans)' }}>{item.title}</div>
                    </div>
                    <Link to={item.to}>
                      <Button size="sm" variant="ghost" iconRight="arrow-right">
                        Open
                      </Button>
                    </Link>
                  </div>
                ))
              )}
            </div>
          </Card>
        </div>

        <Card title="Recent activity" subtitle="Latest posted entries" padding="none">
          <DataTable
            rows={data?.recent ?? []}
            columns={recentColumns}
            rowKey={(r) => `je-${r.entry_no}`}
            emptyMessage="Nothing posted yet — the first entry is usually the opening balances."
            dense
          />
        </Card>
      </PageBody>
    </>
  )
}
