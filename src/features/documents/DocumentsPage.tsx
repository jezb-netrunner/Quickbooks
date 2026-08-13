import { useMemo, useState } from 'react'
import { Amount, Badge, Button, Card, DataTable, StatTile, Toast, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { useAccounts } from '@/features/coa/hooks'
import { useContacts } from '@/features/contacts/hooks'
import type { DocType, DocumentRow } from '@/lib/database.types'
import { DOC_TYPES, docLabel, openItemRef } from './docTypes'
import { DocumentDialog } from './DocumentDialog'
import { useDocuments, useOpenItems } from './hooks'
import { localToday } from '@/lib/dates'

export function DocumentsPage({ docType }: { docType: DocType }) {
  const config = DOC_TYPES[docType]
  const client = useActiveClient()
  const { data: documents } = useDocuments(client.id, docType)
  const { data: contacts } = useContacts(client.id)
  const { data: accounts } = useAccounts(client.id)
  const today = localToday()
  const showsOpenItems = docType === 'invoice' || docType === 'bill' || docType === 'purchase'
  // Payment pages warm the open-items cache their dialog will need
  // (payables for Payments, receivables for Collections).
  const { data: openItems } = useOpenItems(
    client.id,
    showsOpenItems ? docType : (config.appliesTo ?? 'receivable'),
    today,
  )

  const [dialogOpen, setDialogOpen] = useState(false)
  const [selected, setSelected] = useState<DocumentRow | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  const contactNames = useMemo(() => new Map((contacts ?? []).map((c) => [c.id, c.name])), [contacts])
  const stats = useMemo(() => {
    if (!showsOpenItems) return null
    const items = openItems ?? []
    const open = items.reduce((s, o) => s + Number(o.balance), 0)
    const overdue = items.filter((o) => o.days_overdue > 0)
    return {
      open,
      overdueTotal: overdue.reduce((s, o) => s + Number(o.balance), 0),
      overdueCount: overdue.length,
      drafts: (documents ?? []).filter((d) => d.status === 'draft').length,
    }
  }, [showsOpenItems, openItems, documents])

  const columns: Column<DocumentRow>[] = [
    {
      key: 'no',
      header: 'No.',
      width: 100,
      render: (d) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{docLabel(config, d.doc_no)}</span>,
    },
    {
      key: 'doc_date',
      header: 'Date',
      width: 110,
      render: (d) => <span style={{ font: '400 13px/1 var(--font-mono)' }}>{d.doc_date}</span>,
    },
    { key: 'contact', header: config.contactSide === 'customer' ? 'Customer' : 'Vendor', render: (d) => contactNames.get(d.contact_id) ?? '—' },
    { key: 'memo', header: 'Memo', render: (d) => d.memo || '—' },
    {
      key: 'status',
      header: 'Status',
      width: 100,
      render: (d) =>
        d.status === 'issued' ? (
          <Badge tone="positive" dot>Issued</Badge>
        ) : d.status === 'voided' ? (
          <Badge tone="neutral" dot>Voided</Badge>
        ) : d.status === 'submitted' ? (
          <Badge tone="ink" dot>For review</Badge>
        ) : (
          <Badge tone="warning" dot>Draft</Badge>
        ),
    },
  ]

  return (
    <>
      <TopBar
        title={config.title}
        subtitle={client.archived_at ? 'Archived — the books are read-only' : config.subtitle}
        actions={
          <Button
            size="sm"
            iconLeft="plus"
            disabled={!!client.archived_at}
            onClick={() => { setSelected(null); setDialogOpen(true) }}
          >
            New {config.noun}
          </Button>
        }
      />
      <PageBody>
        {stats && (
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: 16 }}>
            <StatTile label="Outstanding" value={stats.open} icon="clock" footnote={`as of ${today}`} />
            <StatTile
              label="Overdue"
              value={stats.overdueTotal}
              icon="alert-circle"
              footnote={stats.overdueCount === 0 ? 'Nothing overdue' : `${stats.overdueCount} ${stats.overdueCount === 1 ? 'document' : 'documents'}`}
            />
            <StatTile label="Drafts" value={String(stats.drafts)} plain icon="file-check" footnote="not yet issued" />
          </div>
        )}
        <Card padding="none">
          <DataTable
            rows={documents ?? []}
            columns={columns}
            rowKey={(d) => d.id}
            onRowClick={(d) => { setSelected(d); setDialogOpen(true) }}
            emptyMessage={`No ${config.noun}s yet.`}
            dense
          />
        </Card>
        {showsOpenItems && (openItems ?? []).length > 0 && (
          <Card title="Open items" subtitle="What remains uncollected or unpaid" padding="none">
            <DataTable
              rows={openItems ?? []}
              rowKey={(o) => o.document_id}
              dense
              columns={[
                { key: 'doc', header: 'No.', width: 100, render: (o) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{openItemRef(o.doc_type, o.doc_no)}</span> },
                { key: 'contact_name', header: config.contactSide === 'customer' ? 'Customer' : 'Vendor' },
                { key: 'due_date', header: 'Due', width: 110, render: (o) => <span style={{ font: '400 13px/1 var(--font-mono)' }}>{o.due_date ?? '—'}</span> },
                { key: 'overdue', header: 'Overdue', width: 90, render: (o) => (o.days_overdue > 0 ? <Badge tone="negative">{o.days_overdue}d</Badge> : <Badge tone="positive">Current</Badge>) },
                { key: 'total', header: 'Total', width: 130, align: 'right', render: (o) => <Amount value={o.total} /> },
                { key: 'balance', header: 'Open', width: 130, align: 'right', render: (o) => <Amount value={o.balance} /> },
              ]}
            />
          </Card>
        )}
        {dialogOpen && (
          <DocumentDialog
            clientId={client.id}
            config={config}
            contacts={contacts ?? []}
            accounts={accounts ?? []}
            document={selected}
            requireApproval={client.require_approval}
            onClose={() => setDialogOpen(false)}
            onDone={setToast}
          />
        )}
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </>
  )
}
