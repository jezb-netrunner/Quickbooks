import { useMemo, useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Badge, Button, Card, DataTable, Dialog, ExportMenu, Input, Select, Toast, type Column } from '@/design-system'
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

  // P2-18: the old row-click cycle ran filed → pending, which server-side
  // DELETES the filing record (filed date + reference) with no confirmation.
  // Now: pending → prepared advances directly; prepared opens a "mark filed"
  // dialog that captures the reference; a filed row opens an explicit un-file
  // confirmation instead of silently destroying the record.
  const [filing, setFiling] = useState<CalendarRow | null>(null)
  const [reference, setReference] = useState('')
  const [unfiling, setUnfiling] = useState<CalendarRow | null>(null)

  function advance(row: CalendarRow) {
    setError(null)
    if (row.status === 'pending') {
      setStatus.mutate(
        { row, status: 'prepared' },
        {
          onSuccess: () => setToast(`${row.form} · ${row.period_end} marked prepared`),
          onError: (err) => setError(messageOf(err, 'Could not update the filing status.')),
        },
      )
    } else if (row.status === 'prepared') {
      setReference(row.reference ?? '')
      setFiling(row)
    } else {
      setUnfiling(row)
    }
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
            Click a row to advance it: pending → prepared → filed. Un-filing a filed
            return asks for confirmation.
          </p>
        </div>
        {error && <p style={{ font: 'var(--type-body-sm)', color: 'var(--clay-600)' }}>{error}</p>}
        <Card padding="none">
          <DataTable
            rows={rows ?? []}
            columns={columns}
            rowKey={(r) => `${r.form}:${r.period_end}`}
            onRowClick={advance}
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
        <Dialog
          open={!!filing}
          onClose={() => setFiling(null)}
          width={420}
          title={filing ? `Mark ${filing.form} · ${filing.period_end} as filed?` : ''}
          description="Record the confirmation number from eBIRForms/EFPS. Leaving it blank keeps any stored reference."
          footer={
            <>
              <Button variant="ghost" onClick={() => setFiling(null)}>
                Cancel
              </Button>
              <Button
                disabled={setStatus.isPending}
                onClick={() => {
                  if (!filing) return
                  setStatus.mutate(
                    { row: filing, status: 'filed', reference: reference.trim() },
                    {
                      onSuccess: () => {
                        setToast(`${filing.form} · ${filing.period_end} marked filed`)
                        setFiling(null)
                      },
                      onError: (err) => {
                        setFiling(null)
                        setError(messageOf(err, 'Could not mark the return filed.'))
                      },
                    },
                  )
                }}
              >
                Mark filed
              </Button>
            </>
          }
        >
          <Input
            label="Filing reference"
            placeholder="e.g. EFPS confirmation no."
            maxLength={60}
            value={reference}
            onChange={(e) => setReference(e.target.value)}
          />
        </Dialog>
        <Dialog
          open={!!unfiling}
          onClose={() => setUnfiling(null)}
          width={420}
          title={unfiling ? `Un-file ${unfiling.form} · ${unfiling.period_end}?` : ''}
          description={`This erases the filed date${unfiling?.reference ? ` and reference “${unfiling.reference}”` : ''} and returns the deadline to pending. Only do this if it was marked filed by mistake.`}
          footer={
            <>
              <Button variant="ghost" onClick={() => setUnfiling(null)}>
                Cancel
              </Button>
              <Button
                variant="danger"
                disabled={setStatus.isPending}
                onClick={() => {
                  if (!unfiling) return
                  setStatus.mutate(
                    { row: unfiling, status: 'pending', confirm: true },
                    {
                      onSuccess: () => {
                        setToast(`${unfiling.form} · ${unfiling.period_end} back to pending`)
                        setUnfiling(null)
                      },
                      onError: (err) => {
                        setUnfiling(null)
                        setError(messageOf(err, 'Could not un-file the return.'))
                      },
                    },
                  )
                }}
              >
                Un-file
              </Button>
            </>
          }
        />
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </>
  )
}
