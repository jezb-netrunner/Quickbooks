import { useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Badge, Button, Card, DataTable, Dialog, Toast, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { FormError } from '@/auth/AuthCard'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { usePeriodAction, usePeriods } from '../hooks'
import type { Period } from '@/lib/database.types'

const MONTH_FORMAT = new Intl.DateTimeFormat('en-PH', { month: 'long', year: 'numeric' })

export function PeriodsPage() {
  const client = useActiveClient()
  const { data: periods } = usePeriods(client.id)
  const action = usePeriodAction(client.id)
  const [confirmLock, setConfirmLock] = useState<Period | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  function run(periodId: string, kind: 'close' | 'reopen' | 'lock', doneMsg: string) {
    setError(null)
    action.mutate(
      { periodId, action: kind },
      {
        onSuccess: () => { setToast(doneMsg); setConfirmLock(null) },
        onError: (err) => { setError(messageOf(err, 'The period change failed.')); setConfirmLock(null) },
      },
    )
  }

  const columns: Column<Period>[] = [
    {
      key: 'month',
      header: 'Period',
      render: (p) => MONTH_FORMAT.format(new Date(`${p.period_start}T00:00:00`)),
    },
    {
      key: 'range',
      header: 'Dates',
      width: 210,
      render: (p) => (
        <span style={{ font: '400 13px/1 var(--font-mono)', color: 'var(--text-secondary)' }}>
          {p.period_start} — {p.period_end}
        </span>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      width: 110,
      render: (p) =>
        p.status === 'open' ? (
          <Badge tone="positive" dot>Open</Badge>
        ) : p.status === 'closed' ? (
          <Badge tone="warning" dot>Closed</Badge>
        ) : (
          <Badge tone="ink" dot>Locked</Badge>
        ),
    },
    {
      key: 'actions',
      header: '',
      width: 210,
      align: 'right',
      render: (p) => (
        <span style={{ display: 'inline-flex', gap: 6 }}>
          {p.status === 'open' && (
            <Button size="sm" variant="secondary" disabled={action.isPending}
              onClick={() => run(p.id, 'close', 'Period closed')}>
              Close
            </Button>
          )}
          {p.status === 'closed' && (
            <>
              <Button size="sm" variant="ghost" disabled={action.isPending}
                onClick={() => run(p.id, 'reopen', 'Period reopened')}>
                Reopen
              </Button>
              <Button size="sm" variant="danger" disabled={action.isPending}
                onClick={() => setConfirmLock(p)}>
                Lock
              </Button>
            </>
          )}
          {p.status === 'locked' && (
            <span style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>Permanent</span>
          )}
        </span>
      ),
    },
  ]

  return (
    <>
      <TopBar title="Periods" subtitle="Posting is only allowed into an open period" />
      <PageBody>
        {error && <FormError message={error} />}
        <Card padding="none">
          <DataTable
            rows={periods ?? []}
            columns={columns}
            rowKey={(p) => p.id}
            emptyMessage="Periods appear automatically the first time an entry posts into a month."
            dense
          />
        </Card>
        <Card tone="sunken">
          <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-secondary)', maxWidth: '70ch' }}>
            Close a month when its books are done — closing blocks new postings but can be undone.
            Locking is permanent and is meant for months already covered by filed returns
            (admins only). Corrections to a closed month go through reopening it, or through a
            reversing entry in the current month.
          </p>
        </Card>
        <Dialog
          open={!!confirmLock}
          onClose={() => setConfirmLock(null)}
          title={confirmLock ? `Lock ${MONTH_FORMAT.format(new Date(`${confirmLock.period_start}T00:00:00`))}?` : ''}
          description="A locked period can never be reopened, by anyone. Lock only when the filings that cover this month are done."
          footer={
            <>
              <Button variant="ghost" onClick={() => setConfirmLock(null)}>
                Cancel
              </Button>
              <Button
                variant="danger"
                disabled={action.isPending}
                onClick={() => confirmLock && run(confirmLock.id, 'lock', 'Period locked')}
              >
                Lock permanently
              </Button>
            </>
          }
        />
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </>
  )
}
