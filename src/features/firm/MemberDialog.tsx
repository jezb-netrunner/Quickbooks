import { useMemo, useState } from 'react'
import { Button, Checkbox, Dialog, Input, Select } from '@/design-system'
import { FormError } from '@/auth/AuthCard'
import type { Client, MembershipRole } from '@/lib/database.types'
import type { MemberRow } from './api'

const ROLE_OPTIONS: { value: MembershipRole; label: string }[] = [
  { value: 'firm_admin', label: 'Firm admin — everything, all clients' },
  { value: 'reviewer', label: 'Reviewer — assigned clients (approves in a later phase)' },
  { value: 'staff', label: 'Staff — assigned clients' },
  { value: 'client_viewer', label: 'Client viewer — read-only, one client' },
]

export interface MemberDialogValues {
  email: string
  role: MembershipRole
  hasAllClients: boolean
  clientId: string | null
  assignedClientIds: string[]
}

export interface MemberDialogProps {
  open: boolean
  onClose: () => void
  clients: Client[]
  member?: MemberRow // present = edit, absent = add
  initialAssignments?: string[]
  busy: boolean
  error: string | null
  onSubmit: (values: MemberDialogValues) => void
}

export function MemberDialog({
  open,
  onClose,
  clients,
  member,
  initialAssignments,
  busy,
  error,
  onSubmit,
}: MemberDialogProps) {
  const [email, setEmail] = useState('')
  const [role, setRole] = useState<MembershipRole>(member?.role ?? 'staff')
  const [hasAllClients, setHasAllClients] = useState(member?.has_all_clients ?? false)
  const [clientId, setClientId] = useState<string>(member?.client_id ?? '')
  const [assigned, setAssigned] = useState<Set<string>>(new Set(initialAssignments ?? []))

  const activeClients = useMemo(() => clients.filter((c) => !c.archived_at), [clients])
  const isEdit = !!member
  const staffLike = role === 'staff' || role === 'reviewer'

  function toggleAssigned(id: string) {
    setAssigned((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      width={480}
      title={isEdit ? `Edit ${member.profiles?.full_name || member.profiles?.email || 'member'}` : 'Add a member'}
      description={
        isEdit
          ? 'Role and client scope take effect immediately.'
          : 'The person signs up first with a confirmed email; you connect the account here.'
      }
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button
            disabled={busy}
            onClick={() =>
              onSubmit({
                email: email.trim(),
                role,
                hasAllClients: staffLike ? hasAllClients : false,
                clientId: role === 'client_viewer' ? clientId || null : null,
                assignedClientIds: staffLike && !hasAllClients ? [...assigned] : [],
              })
            }
          >
            {busy ? 'Saving' : isEdit ? 'Save changes' : 'Add member'}
          </Button>
        </>
      }
    >
      <div style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        {!isEdit && (
          <Input
            label="Email"
            type="email"
            placeholder="colleague@firm.ph"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        )}
        <Select
          label="Role"
          options={ROLE_OPTIONS}
          value={role}
          onChange={(e) => setRole(e.target.value as MembershipRole)}
        />
        {role === 'client_viewer' && (
          <Select
            label="Client company"
            placeholder="Choose the one client this viewer sees"
            options={activeClients.map((c) => ({ value: c.id, label: c.name }))}
            value={clientId}
            onChange={(e) => setClientId(e.target.value)}
          />
        )}
        {staffLike && (
          <div style={{ display: 'grid', gap: 10 }}>
            <Checkbox
              label="All clients"
              description="Explicit whole-firm access. Unchecked means only the clients ticked below."
              checked={hasAllClients}
              onChange={(e) => setHasAllClients(e.target.checked)}
            />
            {!hasAllClients && (
              <div
                style={{
                  display: 'grid',
                  gap: 8,
                  maxHeight: 180,
                  overflowY: 'auto',
                  padding: '10px 12px',
                  background: 'var(--sand-100)',
                  borderRadius: 'var(--radius-md)',
                }}
              >
                {activeClients.length === 0 ? (
                  <span style={{ font: 'var(--type-body-sm)', color: 'var(--text-muted)' }}>
                    No clients yet — this member sees nothing until you add clients and assign them.
                  </span>
                ) : (
                  activeClients.map((c) => (
                    <Checkbox
                      key={c.id}
                      label={c.name}
                      checked={assigned.has(c.id)}
                      onChange={() => toggleAssigned(c.id)}
                    />
                  ))
                )}
              </div>
            )}
          </div>
        )}
      </div>
    </Dialog>
  )
}
