import { useState } from 'react'
import { Badge, Button, Card, DataTable, Toast, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { useAccounts } from '@/features/coa/hooks'
import { useEntries } from '../hooks'
import { EntryDialog } from '../EntryDialog'
import type { JournalEntry } from '@/lib/database.types'

const SOURCE_LABEL: Record<string, string> = {
  manual: 'Manual',
  opening_balance: 'Opening balance',
  reversal: 'Reversal',
  invoice: 'Invoice',
  bill: 'Bill',
  receipt: 'Collection',
  disbursement: 'Payment',
  purchase: 'Purchase',
  expense: 'Expense',
  bank_import: 'Bank import',
}

export function JournalPage() {
  const client = useActiveClient()
  const { data: entries } = useEntries(client.id)
  const { data: accounts } = useAccounts(client.id)
  const [editorOpen, setEditorOpen] = useState(false)
  const [selected, setSelected] = useState<JournalEntry | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  const hasAccounts = (accounts ?? []).some((a) => !a.archived_at)

  const columns: Column<JournalEntry>[] = [
    {
      key: 'entry_no',
      header: 'No.',
      width: 90,
      render: (e) => (
        <span style={{ font: '500 13px/1 var(--font-mono)' }}>
          {e.entry_no !== null ? `JE-${e.entry_no}` : '—'}
        </span>
      ),
    },
    {
      key: 'entry_date',
      header: 'Date',
      width: 110,
      render: (e) => <span style={{ font: '400 13px/1 var(--font-mono)' }}>{e.entry_date}</span>,
    },
    { key: 'memo', header: 'Memo', render: (e) => e.memo || '—' },
    { key: 'source_type', header: 'Source', width: 130, render: (e) => SOURCE_LABEL[e.source_type] ?? e.source_type },
    {
      key: 'status',
      header: 'Status',
      width: 110,
      render: (e) =>
        e.status === 'posted' ? (
          e.reversed_by ? (
            <Badge tone="neutral" dot>Reversed</Badge>
          ) : (
            <Badge tone="positive" dot>Posted</Badge>
          )
        ) : e.status === 'submitted' ? (
          <Badge tone="ink" dot>For review</Badge>
        ) : (
          <Badge tone="warning" dot>Draft</Badge>
        ),
    },
  ]

  return (
    <>
      <TopBar
        title="Journal"
        subtitle={
          client.archived_at
            ? 'Archived — the books are read-only'
            : `${(entries ?? []).filter((e) => e.status === 'draft').length} drafts`
        }
        actions={
          <Button
            size="sm"
            iconLeft="plus"
            disabled={!hasAccounts || !!client.archived_at}
            onClick={() => { setSelected(null); setEditorOpen(true) }}
          >
            New entry
          </Button>
        }
      />
      <PageBody>
        {!hasAccounts && (
          <Card tone="sunken">
            <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-secondary)' }}>
              Set up the chart of accounts first — entries need accounts to post against.
            </p>
          </Card>
        )}
        <Card padding="none">
          <DataTable
            rows={entries ?? []}
            columns={columns}
            rowKey={(e) => e.id}
            onRowClick={(e) => { setSelected(e); setEditorOpen(true) }}
            emptyMessage="No entries yet. The first one is usually the opening balances."
            dense
          />
        </Card>
        {editorOpen && (
          <EntryDialog
            clientId={client.id}
            accounts={accounts ?? []}
            entry={selected}
            requireApproval={client.require_approval}
            onClose={() => setEditorOpen(false)}
            onDone={setToast}
          />
        )}
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </>
  )
}
