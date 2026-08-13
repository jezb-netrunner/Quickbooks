import { useMemo, useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Link, useNavigate } from 'react-router-dom'
import {
  Badge,
  Button,
  Card,
  DataTable,
  Dialog,
  Input,
  Tabs,
  Toast,
  type Column,
} from '@/design-system'
import { AppShell, TopBar, PageBody } from '@/shell/AppShell'
import { Sidebar } from '@/shell/Sidebar'
import { Splash } from '@/shell/Splash'
import { FormError } from '@/auth/AuthCard'
import { useClients, useCreateClient, useMyMemberships } from '@/features/clients/hooks'
import { ClientForm } from '@/features/clients/ClientForm'
import { useAddMember, useAssignments, useMembers, useRemoveMember, useRenameFirm, useUpdateMember } from './hooks'
import { MemberDialog, type MemberDialogValues } from './MemberDialog'
import type { Client, MembershipRole } from '@/lib/database.types'
import type { MemberRow } from './api'

const ROLE_LABEL: Record<MembershipRole, string> = {
  firm_admin: 'Firm admin',
  reviewer: 'Reviewer',
  staff: 'Staff',
  client_viewer: 'Client viewer',
}

export function FirmPage() {
  const navigate = useNavigate()
  const { data: memberships, isPending } = useMyMemberships()
  const membership = memberships?.[0]

  if (isPending) return <Splash />
  if (!membership) {
    navigate('/select-client', { replace: true })
    return <Splash />
  }

  return <FirmConsole firmId={membership.firm_id} firmName={membership.firms?.name ?? 'Your firm'} isAdmin={membership.role === 'firm_admin'} />
}

function FirmConsole({ firmId, firmName, isAdmin }: { firmId: string; firmName: string; isAdmin: boolean }) {
  const [tab, setTab] = useState('clients')
  const { data: clients } = useClients()
  const { data: members } = useMembers(firmId)
  const [toast, setToast] = useState<string | null>(null)

  const nav = [
    { to: '/select-client', label: 'All clients', icon: 'arrow-left' },
    { to: '/practice', label: 'Practice dashboard', icon: 'briefcase' },
    { to: '/firm', label: 'Firm settings', icon: 'settings' },
  ]

  return (
    <AppShell sidebar={<Sidebar items={nav} />}>
      <TopBar title={firmName} subtitle={isAdmin ? 'Firm settings' : 'Firm settings — read-only for your role'} />
      <PageBody>
        <Tabs
          value={tab}
          onChange={setTab}
          items={[
            { value: 'clients', label: 'Clients', count: clients?.filter((c) => !c.archived_at).length },
            { value: 'members', label: 'Members', count: members?.length },
            { value: 'firm', label: 'Firm' },
          ]}
        />
        {tab === 'clients' && <ClientsTab firmId={firmId} clients={clients ?? []} onDone={setToast} />}
        {tab === 'members' && <MembersTab firmId={firmId} clients={clients ?? []} members={members ?? []} onDone={setToast} />}
        {tab === 'firm' && <FirmTab firmId={firmId} firmName={firmName} onDone={setToast} />}
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </AppShell>
  )
}

// ---------------------------------------------------------------- Clients

function ClientsTab({ firmId, clients, onDone }: { firmId: string; clients: Client[]; onDone: (msg: string) => void }) {
  const createClient = useCreateClient(firmId)
  const [adding, setAdding] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const columns: Column<Client>[] = [
    { key: 'name', header: 'Company', render: (c) => <Link to={`/c/${c.id}`}>{c.name}</Link> },
    { key: 'code', header: 'Code', width: 90, render: (c) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{c.code ?? '—'}</span> },
    { key: 'tin', header: 'TIN', width: 140, render: (c) => <span style={{ font: '400 13px/1 var(--font-mono)', color: 'var(--text-secondary)' }}>{c.tin ?? '—'}</span> },
    { key: 'reporting_basis', header: 'Basis', width: 90 },
    {
      key: 'status',
      header: 'Status',
      width: 110,
      render: (c) =>
        c.archived_at ? <Badge tone="neutral">Archived</Badge> : <Badge tone="positive" dot>Active</Badge>,
    },
  ]

  return (
    <Card
      title="Client companies"
      subtitle="Each client keeps fully separate books"
      padding="none"
      action={
        <Button size="sm" iconLeft="plus" onClick={() => setAdding(true)}>
          Add client
        </Button>
      }
    >
      <DataTable rows={clients} columns={columns} rowKey={(c) => c.id} emptyMessage="No clients yet. Add the first one." />
      <Dialog
        open={adding}
        onClose={() => setAdding(false)}
        width={480}
        title="Add a client company"
        description="Reporting basis and fiscal year end drive period generation in the next phase."
      >
        <ClientForm
          submitLabel="Add client"
          busy={createClient.isPending}
          error={error}
          onCancel={() => setAdding(false)}
          onSubmit={(values) => {
            setError(null)
            createClient.mutate(values, {
              onSuccess: (c) => {
                setAdding(false)
                onDone(`${c.name} added`)
              },
              onError: (err) => setError(messageOf(err, 'Could not add the client.')),
            })
          }}
        />
      </Dialog>
    </Card>
  )
}

// ---------------------------------------------------------------- Members

function MembersTab({
  firmId,
  clients,
  members,
  onDone,
}: {
  firmId: string
  clients: Client[]
  members: MemberRow[]
  onDone: (msg: string) => void
}) {
  const { data: assignments } = useAssignments(firmId)
  const addMember = useAddMember(firmId)
  const updateMember = useUpdateMember(firmId)
  const removeMember = useRemoveMember(firmId)
  const [adding, setAdding] = useState(false)
  const [editing, setEditing] = useState<MemberRow | null>(null)
  const [removing, setRemoving] = useState<MemberRow | null>(null)
  const [error, setError] = useState<string | null>(null)

  const clientNames = useMemo(() => new Map(clients.map((c) => [c.id, c.name])), [clients])
  const assignmentsByMember = useMemo(() => {
    const map = new Map<string, string[]>()
    for (const a of assignments ?? []) {
      map.set(a.membership_id, [...(map.get(a.membership_id) ?? []), a.client_id])
    }
    return map
  }, [assignments])

  function scopeLabel(m: MemberRow): string {
    if (m.role === 'firm_admin') return 'All clients'
    if (m.role === 'client_viewer') return m.client_id ? (clientNames.get(m.client_id) ?? '1 client') : '—'
    if (m.has_all_clients) return 'All clients'
    const n = assignmentsByMember.get(m.id)?.length ?? 0
    return n === 0 ? 'No clients yet' : `${n} ${n === 1 ? 'client' : 'clients'}`
  }

  const columns: Column<MemberRow>[] = [
    { key: 'name', header: 'Name', render: (m) => m.profiles?.full_name || '—' },
    {
      key: 'email',
      header: 'Email',
      render: (m) => (
        <span style={{ font: '400 13px/1 var(--font-mono)', color: 'var(--text-secondary)' }}>
          {m.profiles?.email ?? '—'}
        </span>
      ),
    },
    {
      key: 'role',
      header: 'Role',
      width: 130,
      render: (m) => <Badge tone={m.role === 'firm_admin' ? 'ink' : m.role === 'client_viewer' ? 'neutral' : 'positive'}>{ROLE_LABEL[m.role]}</Badge>,
    },
    { key: 'scope', header: 'Client scope', width: 150, render: scopeLabel },
    {
      key: 'actions',
      header: '',
      width: 150,
      align: 'right',
      render: (m) => (
        <span style={{ display: 'inline-flex', gap: 6 }}>
          <Button size="sm" variant="ghost" onClick={() => setEditing(m)}>
            Edit
          </Button>
          <Button size="sm" variant="danger" onClick={() => setRemoving(m)}>
            Remove
          </Button>
        </span>
      ),
    },
  ]

  return (
    <Card
      title="Members"
      subtitle="Access is granted here and enforced by the database, never by the app"
      padding="none"
      action={
        <Button size="sm" iconLeft="plus" onClick={() => { setError(null); setAdding(true) }}>
          Add member
        </Button>
      }
    >
      <DataTable rows={members} columns={columns} rowKey={(m) => m.id} emptyMessage="Only you so far." />

      {adding && (
        <MemberDialog
          open
          onClose={() => setAdding(false)}
          clients={clients}
          busy={addMember.isPending}
          error={error}
          onSubmit={(values: MemberDialogValues) => {
            setError(null)
            addMember.mutate(
              {
                email: values.email,
                role: values.role,
                clientId: values.clientId,
                hasAllClients: values.hasAllClients,
                assignedClientIds: values.assignedClientIds,
              },
              {
                onSuccess: () => {
                  setAdding(false)
                  onDone('Member added')
                },
                onError: (err) => setError(messageOf(err, 'Could not add the member.')),
              },
            )
          }}
        />
      )}

      {editing && (
        <MemberDialog
          open
          onClose={() => setEditing(null)}
          clients={clients}
          member={editing}
          initialAssignments={assignmentsByMember.get(editing.id) ?? []}
          busy={updateMember.isPending}
          error={error}
          onSubmit={(values: MemberDialogValues) => {
            setError(null)
            updateMember.mutate(
              {
                membershipId: editing.id,
                role: values.role,
                hasAllClients: values.hasAllClients,
                clientId: values.clientId,
                assignedClientIds: values.assignedClientIds,
              },
              {
                onSuccess: () => {
                  setEditing(null)
                  onDone('Member updated')
                },
                onError: (err) => setError(messageOf(err, 'Could not update the member.')),
              },
            )
          }}
        />
      )}

      <Dialog
        open={!!removing}
        onClose={() => setRemoving(null)}
        title={`Remove ${removing?.profiles?.full_name || removing?.profiles?.email || 'this member'}?`}
        description="Access ends immediately. The grant history stays in the audit log."
        footer={
          <>
            <Button variant="ghost" onClick={() => setRemoving(null)}>
              Cancel
            </Button>
            <Button
              variant="danger"
              disabled={removeMember.isPending}
              onClick={() => {
                if (!removing) return
                setError(null)
                removeMember.mutate(removing.id, {
                  onSuccess: () => {
                    setRemoving(null)
                    onDone('Member removed')
                  },
                  onError: (err) => {
                    setRemoving(null)
                    setError(messageOf(err, 'Could not remove the member.'))
                  },
                })
              }}
            >
              Remove
            </Button>
          </>
        }
      >
        <FormError message={error} />
      </Dialog>
    </Card>
  )
}

// ------------------------------------------------------------------- Firm

function FirmTab({ firmId, firmName, onDone }: { firmId: string; firmName: string; onDone: (msg: string) => void }) {
  const renameFirm = useRenameFirm(firmId)
  const [name, setName] = useState(firmName)
  const [error, setError] = useState<string | null>(null)

  return (
    <div style={{ maxWidth: 480 }}>
      <Card title="Firm details" subtitle="Appears across the portal">
        <form
          onSubmit={(e) => {
            e.preventDefault()
            setError(null)
            renameFirm.mutate(name.trim(), {
              onSuccess: () => onDone('Firm renamed'),
              onError: (err) => setError(messageOf(err, 'Rename failed.')),
            })
          }}
          style={{ display: 'grid', gap: 14 }}
        >
          <FormError message={error} />
          <Input label="Firm name" required maxLength={120} value={name} onChange={(e) => setName(e.target.value)} />
          <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
            <Button type="submit" disabled={renameFirm.isPending}>
              {renameFirm.isPending ? 'Saving' : 'Save changes'}
            </Button>
          </div>
        </form>
      </Card>
    </div>
  )
}
