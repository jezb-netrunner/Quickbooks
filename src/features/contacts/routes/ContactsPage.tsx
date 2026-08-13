import { useMemo, useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Badge, Button, Card, DataTable, Dialog, Input, Select, Tabs, Toast, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { FormError } from '@/auth/AuthCard'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { useContacts, useCreateContact, useUpdateContact } from '../hooks'
import type { Contact, ContactType } from '@/lib/database.types'

const TYPE_LABEL: Record<ContactType, string> = { customer: 'Customer', vendor: 'Vendor', both: 'Customer and vendor' }

export function ContactsPage({ side = 'all' }: { side?: 'all' | 'customer' | 'vendor' }) {
  const client = useActiveClient()
  const { data: contacts } = useContacts(client.id)
  const createContact = useCreateContact(client.id)
  const updateContact = useUpdateContact(client.id)
  const [tab, setTab] = useState<string>(side)
  const [editing, setEditing] = useState<Contact | null>(null)
  const [adding, setAdding] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  const rows = useMemo(() => {
    const all = contacts ?? []
    if (tab === 'customer') return all.filter((c) => c.contact_type !== 'vendor')
    if (tab === 'vendor') return all.filter((c) => c.contact_type !== 'customer')
    return all
  }, [contacts, tab])

  const columns: Column<Contact>[] = [
    { key: 'name', header: 'Name' },
    { key: 'contact_type', header: 'Type', width: 160, render: (c) => TYPE_LABEL[c.contact_type] },
    {
      key: 'tin',
      header: 'TIN',
      width: 140,
      render: (c) => <span style={{ font: '400 13px/1 var(--font-mono)', color: 'var(--text-secondary)' }}>{c.tin ?? '—'}</span>,
    },
    {
      key: 'email',
      header: 'Email',
      render: (c) => <span style={{ font: '400 13px/1 var(--font-mono)', color: 'var(--text-secondary)' }}>{c.email ?? '—'}</span>,
    },
    {
      key: 'status',
      header: 'Status',
      width: 100,
      render: (c) => (c.archived_at ? <Badge tone="neutral">Archived</Badge> : <Badge tone="positive" dot>Active</Badge>),
    },
  ]

  return (
    <>
      <TopBar
        title={side === 'customer' ? 'Customers' : side === 'vendor' ? 'Vendors' : 'Customers and vendors'}
        subtitle={side === 'customer' ? 'Who this client bills' : side === 'vendor' ? 'Who this client buys from and pays' : 'Everyone this client bills or pays'}
        actions={
          <Button size="sm" iconLeft="plus" onClick={() => { setError(null); setAdding(true) }}>
            Add contact
          </Button>
        }
      />
      <PageBody>
        <Tabs
          value={tab}
          onChange={setTab}
          items={[
            { value: 'all', label: 'All', count: (contacts ?? []).length },
            { value: 'customer', label: 'Customers' },
            { value: 'vendor', label: 'Vendors' },
          ]}
        />
        <Card padding="none">
          <DataTable
            rows={rows}
            columns={columns}
            rowKey={(c) => c.id}
            onRowClick={(c) => { setError(null); setEditing(c) }}
            emptyMessage="No contacts yet. Invoices and bills need one."
            dense
          />
        </Card>

        {(adding || editing) && (
          <ContactDialog
            defaultType={side === 'vendor' ? 'vendor' : 'customer'}
            contact={editing}
            error={error}
            busy={createContact.isPending || updateContact.isPending}
            onClose={() => { setAdding(false); setEditing(null) }}
            onSubmit={(form) => {
              setError(null)
              if (editing) {
                updateContact.mutate(
                  { contactId: editing.id, form },
                  {
                    onSuccess: () => { setEditing(null); setToast('Contact updated') },
                    onError: (err) => setError(messageOf(err, 'Could not update the contact.')),
                  },
                )
              } else {
                createContact.mutate(form, {
                  onSuccess: (c) => { setAdding(false); setToast(`${c.name} added`) },
                  onError: (err) => setError(messageOf(err, 'Could not add the contact.')),
                })
              }
            }}
            onArchiveToggle={
              editing
                ? () =>
                    updateContact.mutate(
                      {
                        contactId: editing.id,
                        form: { archived_at: editing.archived_at ? null : new Date().toISOString() },
                      },
                      {
                        onSuccess: () => setEditing(null),
                        onError: (err) => setError(messageOf(err, 'Could not update the contact.')),
                      },
                    )
                : undefined
            }
          />
        )}
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </>
  )
}

function ContactDialog({
  defaultType,
  contact,
  error,
  busy,
  onClose,
  onSubmit,
  onArchiveToggle,
}: {
  defaultType: ContactType
  contact: Contact | null
  error: string | null
  busy: boolean
  onClose: () => void
  onSubmit: (form: { name: string; contact_type: ContactType; tin: string | null; email: string | null }) => void
  onArchiveToggle?: () => void
}) {
  const [name, setName] = useState(contact?.name ?? '')
  const [type, setType] = useState<ContactType>(contact?.contact_type ?? defaultType)
  const [tin, setTin] = useState(contact?.tin ?? '')
  const [email, setEmail] = useState(contact?.email ?? '')

  return (
    <Dialog
      open
      onClose={onClose}
      width={440}
      title={contact ? contact.name : 'Add a contact'}
      footer={
        <>
          {onArchiveToggle && (
            <Button variant={contact?.archived_at ? 'secondary' : 'danger'} disabled={busy} onClick={onArchiveToggle}>
              {contact?.archived_at ? 'Restore' : 'Archive'}
            </Button>
          )}
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button
            disabled={busy}
            onClick={() =>
              onSubmit({
                name: name.trim(),
                contact_type: type,
                tin: tin.trim() || null,
                email: email.trim() || null,
              })
            }
          >
            {busy ? 'Saving' : contact ? 'Save changes' : 'Add contact'}
          </Button>
        </>
      }
    >
      <div style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        <Input label="Name" required maxLength={160} value={name} onChange={(e) => setName(e.target.value)} />
        <Select
          label="Type"
          options={[
            { value: 'customer', label: 'Customer' },
            { value: 'vendor', label: 'Vendor' },
            { value: 'both', label: 'Customer and vendor' },
          ]}
          value={type}
          onChange={(e) => setType(e.target.value as ContactType)}
        />
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Input label="TIN" placeholder="000-000-000-000" value={tin} onChange={(e) => setTin(e.target.value)} />
          <Input label="Email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
        </div>
      </div>
    </Dialog>
  )
}
