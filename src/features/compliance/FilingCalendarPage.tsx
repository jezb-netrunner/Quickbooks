import { useMemo, useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Badge, Card, DataTable, ExportMenu, Select, Toast, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { localToday } from '@/lib/dates'
import type { CalendarRow } from '@/lib/database.types'
import type { ReportExport } from '@/lib/exports'
import { useCalendar, useSetFilingStatus } from './hooks'

export function FilingCalendarPage() {
  const client = useActiveClient()
  const thisYear = new Date().getFullYear()
  const [year, setYear] = useState(thisYear)
  const { data: rows, isPending, isError } = useCalendar(client.id, year)
  const setStatus = useSetFilingStatus(client.id)
  const [toast, setToast] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const today = localToday()

  const upcoming = useMemo(() => {
    const list = rows ?? []
    return {
      overdue: list.filter((r) => r.status === 'pending' && r.due_date < today).length,
      dueSoon: list.filter((r) => {
        if (r.status !== 'pending') return false
        const diff = (new Date(r.due_date).getTime() - new Date(today).getTime()) / 86400000
        return diff >= 0 && diff <= 14
      }).length,
    }
  }, [rows, today])

  function cycle(row: CalendarRow) {
    const next = row.status === 'pending' ? 'prepared' : row.status === 'prepared' ? 'filed' : 'pending'
    setStatus.mutate(
      { row, status: next },
      {
        onSuccess: () => setToast(`${row.form} · ${row.period_end} marked ${next}`),
        onError: (err) => setError(messageOf(err, 'Could not update the filing status.')),
      },
    )
  }

  const columns: Column<CalendarRow>[] = [
    {
      key: 'due_date',
      header: 'Due',
      width: 110,
      render: (r) => (
        <span style={{ font: '500 13px/1 var(--font-mono)', color: r.status === 'pending' && r.due_date < today ? 'var(--clay-600)' : undefined }}>
          {r.due_date}
        </span>
      ),
    },
    { key: 'form', header: 'Form', width: 90, render: (r) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{r.form}</span> },
    { key: 'label', header: 'Return' },
    {
      key: 'period',
      header: 'Period',
      width: 190,
      render: (r) => <span style={{ font: '400 12.5px/1 var(--font-mono)', color: 'var(--text-secondary)' }}>{r.period_start} – {r.period_end}</span>,
    },
    {
      key: 'status',
      header: 'Status',
      width: 110,
      render: (r) =>
        r.status === 'filed' ? (
          <Badge tone="positive" dot>Filed</Badge>
        ) : r.status === 'prepared' ? (
          <Badge tone="warning" dot>Prepared</Badge>
        ) : r.due_date < today ? (
          <Badge tone="negative" dot>Overdue</Badge>
        ) : (
          <Badge tone="neutral" dot>Pending</Badge>
        ),
    },
    { key: 'reference', header: 'Reference', width: 130, render: (r) => r.reference || '—' },
  ]

  return (
    <>
      <TopBar
        title="Filing calendar"
        subtitle={
          upcoming.overdue > 0
            ? `${upcoming.overdue} overdue · ${upcoming.dueSoon} due within two weeks`
            : `${upcoming.dueSoon} due within two weeks — deadlines derive from this client's rules, not hardcoded dates`
        }
        actions={
          <ExportMenu
            disabled={(rows ?? []).length === 0}
            report={(): ReportExport => ({
              filename: `filing-calendar_${client.code ?? client.name}_${year}`,
              title: `Filing calendar ${year}`,
              subtitle: [client.name],
              header: ['Due', 'Form', 'Return', 'Period start', 'Period end', 'Status', 'Reference'],
              rows: (rows ?? []).map((r) => [r.due_date, r.form, r.label, r.period_start, r.period_end, r.status, r.reference]),
            })}
          />
        }
      />
      <PageBody>
        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-end', justifyContent: 'space-between', flexWrap: 'wrap' }}>
          <div style={{ width: 130 }}>
            <Select
              label="Year"
              fieldSize="sm"
              options={[thisYear - 1, thisYear, thisYear + 1].map((y) => ({ value: String(y), label: String(y) }))}
              value={String(year)}
              onChange={(e) => setYear(Number(e.target.value))}
            />
          </div>
          <p style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>
            Click a row to advance its status: pending → prepared → filed → pending.
          </p>
        </div>
        {error && <p style={{ font: 'var(--type-body-sm)', color: 'var(--clay-600)' }}>{error}</p>}
        <Card padding="none">
          <DataTable
            rows={rows ?? []}
            columns={columns}
            rowKey={(r) => `${r.form}:${r.period_end}`}
            onRowClick={cycle}
            emptyMessage={
              isPending
                ? 'Computing…'
                : isError
                  ? 'Could not load the calendar — check the connection and retry.'
                  : 'No deadline rules yet — run compliance setup from Client settings.'
            }
            dense
          />
        </Card>
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </>
  )
}
