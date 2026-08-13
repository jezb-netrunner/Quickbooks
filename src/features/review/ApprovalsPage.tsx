import { useMemo, useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Button, Card, DataTable, Dialog, Input, Toast, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { FormError } from '@/auth/AuthCard'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { useIsFirmAdmin } from '@/features/clients/hooks'
import { useContacts } from '@/features/contacts/hooks'
import { DOC_TYPES } from '@/features/documents/docTypes'
import type { DocumentRow, JournalEntry } from '@/lib/database.types'
import {
  useApprovalsQueue,
  useApproveDocument,
  useApproveEntry,
  useReturnDocument,
  useReturnEntry,
} from './hooks'

type Returning = { kind: 'entry'; row: JournalEntry } | { kind: 'document'; row: DocumentRow }

export function ApprovalsPage() {
  const client = useActiveClient()
  const isAdmin = useIsFirmAdmin()
  const { data: queue, isPending } = useApprovalsQueue(client.id)
  const { data: contacts } = useContacts(client.id)
  const approveEntry = useApproveEntry(client.id)
  const approveDocument = useApproveDocument(client.id)
  const returnEntry = useReturnEntry(client.id)
  const returnDocument = useReturnDocument(client.id)

  const [returning, setReturning] = useState<Returning | null>(null)
  const [note, setNote] = useState('')
  const [toast, setToast] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const contactNames = useMemo(() => new Map((contacts ?? []).map((c) => [c.id, c.name])), [contacts])
  const busy =
    approveEntry.isPending || approveDocument.isPending || returnEntry.isPending || returnDocument.isPending
  const total = (queue?.entries.length ?? 0) + (queue?.documents.length ?? 0)

  const entryColumns: Column<JournalEntry>[] = [
    {
      key: 'entry_date',
      header: 'Date',
      width: 110,
      render: (e) => <span style={{ font: '400 13px/1 var(--font-mono)' }}>{e.entry_date}</span>,
    },
    { key: 'memo', header: 'Memo', render: (e) => e.memo || '—' },
    ...(isAdmin
      ? [
          {
            key: 'actions',
            header: '',
            width: 170,
            align: 'right' as const,
            render: (e: JournalEntry) => (
              <span style={{ display: 'inline-flex', gap: 6 }}>
                <Button
                  size="sm"
                  iconLeft="check"
                  disabled={busy}
                  onClick={() => {
                    setError(null)
                    approveEntry.mutate(e.id, {
                      onSuccess: (no) => setToast(`Approved and posted as JE-${no}`),
                      onError: (err) => setError(messageOf(err, 'Could not post the entry.')),
                    })
                  }}
                >
                  Approve
                </Button>
                <Button size="sm" variant="ghost" disabled={busy} onClick={() => { setNote(''); setReturning({ kind: 'entry', row: e }) }}>
                  Return
                </Button>
              </span>
            ),
          },
        ]
      : []),
  ]

  const docColumns: Column<DocumentRow>[] = [
    { key: 'doc_type', header: 'Type', width: 130, render: (d) => DOC_TYPES[d.doc_type].title },
    {
      key: 'doc_date',
      header: 'Date',
      width: 110,
      render: (d) => <span style={{ font: '400 13px/1 var(--font-mono)' }}>{d.doc_date}</span>,
    },
    { key: 'contact', header: 'Contact', render: (d) => contactNames.get(d.contact_id) ?? '—' },
    { key: 'memo', header: 'Memo', render: (d) => d.memo || '—' },
    ...(isAdmin
      ? [
          {
            key: 'actions',
            header: '',
            width: 170,
            align: 'right' as const,
            render: (d: DocumentRow) => (
              <span style={{ display: 'inline-flex', gap: 6 }}>
                <Button
                  size="sm"
                  iconLeft="check"
                  disabled={busy}
                  onClick={() => {
                    setError(null)
                    approveDocument.mutate(d.id, {
                      onSuccess: (no) => setToast(`Approved and issued as ${DOC_TYPES[d.doc_type].prefix}-${no}`),
                      onError: (err) => setError(messageOf(err, 'Could not issue the document.')),
                    })
                  }}
                >
                  Approve
                </Button>
                <Button size="sm" variant="ghost" disabled={busy} onClick={() => { setNote(''); setReturning({ kind: 'document', row: d }) }}>
                  Return
                </Button>
              </span>
            ),
          },
        ]
      : []),
  ]

  return (
    <>
      <TopBar
        title="Approvals"
        subtitle={
          isAdmin
            ? `${total} waiting — approving posts to the ledger; returning reopens the draft with your note`
            : `${total} waiting for a firm admin — submitted work is locked until approved or returned`
        }
      />
      <PageBody>
        {error && <FormError message={error} />}
        <Card title="Journal entries" padding="none">
          <DataTable
            rows={queue?.entries ?? []}
            columns={entryColumns}
            rowKey={(e) => e.id}
            emptyMessage={isPending ? 'Loading…' : 'No journal entries waiting for review.'}
            dense
          />
        </Card>
        <Card title="Documents" padding="none">
          <DataTable
            rows={queue?.documents ?? []}
            columns={docColumns}
            rowKey={(d) => d.id}
            emptyMessage={isPending ? 'Loading…' : 'No documents waiting for review.'}
            dense
          />
        </Card>

        {returning && (
          <Dialog
            open
            onClose={() => setReturning(null)}
            width={440}
            title="Return for changes"
            description="The row reopens as a draft; your note tells the preparer what to fix."
            footer={
              <>
                <Button variant="ghost" onClick={() => setReturning(null)}>
                  Cancel
                </Button>
                <Button
                  variant="danger"
                  disabled={busy}
                  onClick={() => {
                    setError(null)
                    const done = {
                      onSuccess: () => { setReturning(null); setToast('Returned to the preparer') },
                      onError: (err: unknown) => {
                        setReturning(null)
                        setError(messageOf(err, 'Could not return the submission.'))
                      },
                    }
                    if (returning.kind === 'entry') {
                      returnEntry.mutate({ entryId: returning.row.id, note: note.trim() }, done)
                    } else {
                      returnDocument.mutate({ documentId: returning.row.id, note: note.trim() }, done)
                    }
                  }}
                >
                  Return
                </Button>
              </>
            }
          >
            <Input
              label="Note to the preparer"
              placeholder="Wrong account — use utilities"
              value={note}
              onChange={(e) => setNote(e.target.value)}
            />
          </Dialog>
        )}
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </>
  )
}
