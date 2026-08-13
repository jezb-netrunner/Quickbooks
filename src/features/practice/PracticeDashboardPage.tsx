import { useQuery } from '@tanstack/react-query'
import { Link, useNavigate } from 'react-router-dom'
import { Amount, Badge, Card, DataTable, type Column } from '@/design-system'
import { AppShell, TopBar, PageBody } from '@/shell/AppShell'
import { Sidebar } from '@/shell/Sidebar'
import { keys } from '@/lib/queryKeys'
import { supabase } from '@/lib/supabase'
import { rememberLastClient } from '@/features/clients/lastClient'
import type { PracticeDashboardRow } from '@/lib/database.types'

async function fetchPracticeDashboard(): Promise<PracticeDashboardRow[]> {
  const { data, error } = await supabase.rpc('practice_dashboard')
  if (error) throw error
  return data
}

// The whole practice on one screen: every accessible client's current period,
// preparation backlog, bank queue, overdue AR, and next BIR deadline. Rows are
// scoped inside the RPC itself — firm B's clients can never appear here.
export function PracticeDashboardPage() {
  const navigate = useNavigate()
  const { data: rows, isPending, isError } = useQuery({
    queryKey: keys.practice,
    queryFn: fetchPracticeDashboard,
  })

  const nav = [
    { to: '/select-client', label: 'All clients', icon: 'arrow-left' },
    { to: '/practice', label: 'Practice dashboard', icon: 'briefcase' },
    { to: '/firm', label: 'Firm settings', icon: 'settings' },
  ]

  const totals = (rows ?? []).reduce(
    (s, r) => ({
      drafts: s.drafts + r.drafts,
      submitted: s.submitted + r.submitted,
      bank: s.bank + r.pending_bank,
      overdue: s.overdue + r.overdue_filings,
    }),
    { drafts: 0, submitted: 0, bank: 0, overdue: 0 },
  )

  const columns: Column<PracticeDashboardRow>[] = [
    {
      key: 'name',
      header: 'Client',
      render: (r) => (
        <Link to={`/c/${r.client_id}`} onClick={() => rememberLastClient(r.client_id)} style={{ font: 'var(--weight-medium) var(--text-sm)/1.3 var(--font-sans)' }}>
          {r.name}
        </Link>
      ),
    },
    {
      key: 'period_status',
      header: 'This period',
      width: 110,
      render: (r) =>
        r.period_status === 'open' ? (
          <Badge tone="positive" dot>Open</Badge>
        ) : r.period_status === 'closed' ? (
          <Badge tone="neutral" dot>Closed</Badge>
        ) : r.period_status === 'locked' ? (
          <Badge tone="ink" dot>Locked</Badge>
        ) : (
          <Badge tone="warning">No period</Badge>
        ),
    },
    {
      key: 'drafts',
      header: 'Drafts',
      width: 80,
      align: 'right',
      render: (r) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{r.drafts || '—'}</span>,
    },
    {
      key: 'submitted',
      header: 'For review',
      width: 95,
      align: 'right',
      render: (r) =>
        r.submitted > 0 ? <Badge tone="warning">{r.submitted}</Badge> : <span style={{ color: 'var(--text-muted)' }}>—</span>,
    },
    {
      key: 'pending_bank',
      header: 'Bank queue',
      width: 95,
      align: 'right',
      render: (r) =>
        r.pending_bank > 0 ? <Badge tone="neutral">{r.pending_bank}</Badge> : <span style={{ color: 'var(--text-muted)' }}>—</span>,
    },
    {
      key: 'ar_overdue',
      header: 'AR overdue',
      width: 120,
      align: 'right',
      render: (r) => <Amount value={r.ar_overdue} dashZero />,
    },
    {
      key: 'filings',
      header: 'Filings',
      width: 90,
      align: 'right',
      render: (r) =>
        r.overdue_filings > 0 ? (
          <Badge tone="negative" dot>{r.overdue_filings} late</Badge>
        ) : (
          <span style={{ color: 'var(--text-muted)' }}>—</span>
        ),
    },
    {
      key: 'next_due',
      header: 'Next deadline',
      width: 160,
      render: (r) =>
        r.next_due_form ? (
          <span style={{ font: '400 12.5px/1.3 var(--font-mono)' }}>
            {r.next_due_form} · {r.next_due_date}
          </span>
        ) : (
          <span style={{ color: 'var(--text-muted)' }}>—</span>
        ),
    },
  ]

  return (
    <AppShell sidebar={<Sidebar items={nav} />}>
      <TopBar
        title="Practice dashboard"
        subtitle={`${(rows ?? []).length} active clients · ${totals.drafts} drafts · ${totals.submitted} for review · ${totals.bank} bank lines · ${totals.overdue} overdue filings`}
      />
      <PageBody>
        <Card padding="none">
          <DataTable
            rows={rows ?? []}
            columns={columns}
            rowKey={(r) => r.client_id}
            onRowClick={(r) => { rememberLastClient(r.client_id); navigate(`/c/${r.client_id}`) }}
            emptyMessage={
              isPending
                ? 'Loading…'
                : isError
                  ? 'Could not load the practice dashboard — check the connection and retry.'
                  : 'No active clients yet.'
            }
          />
        </Card>
        <p style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>
          Deadlines come from each client's own compliance rules; the review and bank queues update as
          staff work. Click a client to open its books.
        </p>
      </PageBody>
    </AppShell>
  )
}
