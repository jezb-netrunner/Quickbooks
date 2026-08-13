import { useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Button, Card, Checkbox, Dialog, Toast } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { TaxProfileCard } from '@/features/tax/TaxProfileCard'
import { useActiveClient } from './ClientLayout'
import { ClientForm } from '../ClientForm'
import { useSetClientArchived, useSetRequireApproval, useUpdateClient } from '../hooks'

export function ClientSettingsPage() {
  const client = useActiveClient()
  const updateClient = useUpdateClient(client.id)
  const setArchived = useSetClientArchived(client.id)
  const setApproval = useSetRequireApproval(client.id)
  const [confirmArchive, setConfirmArchive] = useState(false)
  const [saved, setSaved] = useState(false)
  const [error, setError] = useState<string | null>(null)

  return (
    <>
      <TopBar title="Client settings" subtitle={client.name} />
      <PageBody>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))', gap: 16, alignItems: 'start' }}>
          <Card title="Company details" subtitle="Feeds period generation and BIR reports in later phases">
            <ClientForm
              key={client.updated_at}
              initial={client}
              submitLabel="Save changes"
              busy={updateClient.isPending}
              error={error}
              onSubmit={(values) => {
                setError(null)
                updateClient.mutate(values, {
                  onSuccess: () => setSaved(true),
                  onError: (err) => setError(messageOf(err, 'Save failed.')),
                })
              }}
            />
          </Card>
          <TaxProfileCard clientId={client.id} />
          <Card
            title="Review workflow"
            subtitle="Staff prepare, a firm admin approves — enforced by the posting engine itself"
          >
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              <Checkbox
                label="Require approval before anything posts"
                checked={client.require_approval}
                disabled={setApproval.isPending}
                onChange={(e) => {
                  setError(null)
                  setApproval.mutate(e.target.checked, {
                    onError: (err) =>
                      setError(messageOf(err, 'Only a firm admin can change the review setting.')),
                  })
                }}
              />
              <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-secondary)' }}>
                {client.require_approval
                  ? 'On: journal entries, documents, and bank lines from staff wait in Approvals until a firm admin posts them.'
                  : 'Off: anyone with write access posts directly. Turn this on once more than one person keeps these books.'}
              </p>
            </div>
          </Card>
          <Card
            title={client.archived_at ? 'Restore this client' : 'Archive this client'}
            subtitle="Archived books are kept, never deleted"
            tone="sunken"
          >
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-secondary)' }}>
                {client.archived_at
                  ? 'Restoring makes this client active again for the whole firm.'
                  : 'Archiving hides this client from the switcher and blocks all writes. Only firm admins can do this.'}
              </p>
              <div>
                {client.archived_at ? (
                  <Button
                    variant="secondary"
                    disabled={setArchived.isPending}
                    onClick={() =>
                      setArchived.mutate(false, {
                        onError: (err) => setError(messageOf(err, 'Restore failed.')),
                      })
                    }
                  >
                    Restore client
                  </Button>
                ) : (
                  <Button variant="danger" onClick={() => setConfirmArchive(true)}>
                    Archive client
                  </Button>
                )}
              </div>
            </div>
          </Card>
        </div>

        <Dialog
          open={confirmArchive}
          onClose={() => setConfirmArchive(false)}
          title={`Archive ${client.name}?`}
          description="The books are kept and can be restored at any time. Until then the client is read-only and hidden from the switcher."
          footer={
            <>
              <Button variant="ghost" onClick={() => setConfirmArchive(false)}>
                Cancel
              </Button>
              <Button
                variant="danger"
                disabled={setArchived.isPending}
                onClick={() =>
                  setArchived.mutate(true, {
                    onSuccess: () => setConfirmArchive(false),
                    onError: (err) => {
                      setConfirmArchive(false)
                      setError(messageOf(err, 'Archive failed.'))
                    },
                  })
                }
              >
                Archive
              </Button>
            </>
          }
        />
        {saved && <Toast title="Changes saved" message={`${client.name} is up to date.`} onDismiss={() => setSaved(false)} />}
      </PageBody>
    </>
  )
}
