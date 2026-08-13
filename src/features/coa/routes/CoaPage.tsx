import { useMemo, useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Badge, Button, Card, DataTable, Dialog, Input, Select, Toast, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { FormError } from '@/auth/AuthCard'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { useAccounts, useCreateAccount, useSeedCoa, useUpdateAccount } from '../hooks'
import type { Account, AccountType, NormalBalance } from '@/lib/database.types'

const TYPE_LABEL: Record<AccountType, string> = {
  asset: 'Asset',
  liability: 'Liability',
  equity: 'Equity',
  income: 'Income',
  expense: 'Expense',
}

export function CoaPage() {
  const client = useActiveClient()
  const { data: accounts, isPending } = useAccounts(client.id)
  const seed = useSeedCoa(client.id)
  const createAccount = useCreateAccount(client.id)
  const updateAccount = useUpdateAccount(client.id)
  const [adding, setAdding] = useState(false)
  const [editing, setEditing] = useState<Account | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  const parentNames = useMemo(() => new Map((accounts ?? []).map((a) => [a.id, a.name])), [accounts])

  const columns: Column<Account>[] = [
    {
      key: 'code',
      header: 'Code',
      width: 110,
      render: (a) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{a.code}</span>,
    },
    {
      key: 'name',
      header: 'Account',
      render: (a) => (
        <span style={{ paddingLeft: a.parent_id ? 18 : 0 }}>
          {a.name}
          {a.parent_id && (
            <span style={{ marginLeft: 8, font: 'var(--type-label)', color: 'var(--text-muted)' }}>
              under {parentNames.get(a.parent_id)}
            </span>
          )}
        </span>
      ),
    },
    { key: 'account_type', header: 'Type', width: 100, render: (a) => TYPE_LABEL[a.account_type] },
    {
      key: 'normal_balance',
      header: 'Normal',
      width: 90,
      render: (a) => <span style={{ color: 'var(--text-secondary)' }}>{a.normal_balance}</span>,
    },
    {
      key: 'status',
      header: 'Status',
      width: 100,
      render: (a) =>
        a.archived_at ? <Badge tone="neutral">Archived</Badge> : <Badge tone="positive" dot>Active</Badge>,
    },
  ]

  return (
    <>
      <TopBar
        title="Chart of accounts"
        subtitle={`${(accounts ?? []).filter((a) => !a.archived_at).length} active accounts`}
        actions={
          <Button size="sm" iconLeft="plus" onClick={() => { setError(null); setAdding(true) }}>
            Add account
          </Button>
        }
      />
      <PageBody>
        {!isPending && (accounts ?? []).length === 0 ? (
          <Card title="No chart of accounts yet" subtitle="Start from the PH SME template">
            <div style={{ display: 'grid', gap: 12, maxWidth: '60ch' }}>
              <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-secondary)' }}>
                The template covers the accounts a Philippine SME typically needs — cash, receivables,
                input and output VAT, creditable withholding tax, the BIR payable accounts, and the
                usual income and expense lines. You can rename, add, or archive accounts afterwards.
              </p>
              <FormError message={error} />
              <div>
                <Button
                  iconLeft="list-tree"
                  disabled={seed.isPending}
                  onClick={() =>
                    seed.mutate(undefined, {
                      onSuccess: (n) => setToast(`${n} accounts created from the template`),
                      onError: (err) => setError(messageOf(err, 'Could not seed the chart.')),
                    })
                  }
                >
                  {seed.isPending ? 'Seeding' : 'Seed the PH SME chart'}
                </Button>
              </div>
            </div>
          </Card>
        ) : (
          <Card padding="none">
            <DataTable
              rows={accounts ?? []}
              columns={columns}
              rowKey={(a) => a.id}
              onRowClick={(a) => { setError(null); setEditing(a) }}
              emptyMessage="Loading accounts…"
              dense
            />
          </Card>
        )}

        {/* Mounted only while open so each opening starts with blank fields. */}
        {adding && (
          <AccountDialog
            open
            title="Add an account"
            error={error}
            busy={createAccount.isPending}
            onClose={() => setAdding(false)}
            onSubmit={(form) =>
              createAccount.mutate(form, {
                onSuccess: () => { setAdding(false); setToast(`${form.code} ${form.name} added`) },
                onError: (err) => setError(messageOf(err, 'Could not add the account.')),
              })
            }
          />
        )}

        {editing && (
          <Dialog
            open
            onClose={() => setEditing(null)}
            width={440}
            title={`${editing.code} ${editing.name}`}
            description="Type and normal balance are fixed once an account exists — archive and recreate if it was set up wrong before use."
            footer={
              <>
                <Button
                  variant={editing.archived_at ? 'secondary' : 'danger'}
                  disabled={updateAccount.isPending}
                  onClick={() =>
                    updateAccount.mutate(
                      {
                        accountId: editing.id,
                        form: { archived_at: editing.archived_at ? null : new Date().toISOString() },
                      },
                      {
                        onSuccess: () => setEditing(null),
                        onError: (err) => setError(messageOf(err, 'Could not update the account.')),
                      },
                    )
                  }
                >
                  {editing.archived_at ? 'Restore' : 'Archive'}
                </Button>
                <Button variant="ghost" onClick={() => setEditing(null)}>
                  Close
                </Button>
              </>
            }
          >
            <EditAccountForm
              account={editing}
              error={error}
              busy={updateAccount.isPending}
              onSubmit={(form) =>
                updateAccount.mutate(
                  { accountId: editing.id, form },
                  {
                    onSuccess: () => { setEditing(null); setToast('Account updated') },
                    onError: (err) => setError(messageOf(err, 'Could not update the account.')),
                  },
                )
              }
            />
          </Dialog>
        )}
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </>
  )
}

function AccountDialog({
  open,
  title,
  error,
  busy,
  onClose,
  onSubmit,
}: {
  open: boolean
  title: string
  error: string | null
  busy: boolean
  onClose: () => void
  onSubmit: (form: { code: string; name: string; account_type: AccountType; normal_balance: NormalBalance }) => void
}) {
  const [code, setCode] = useState('')
  const [name, setName] = useState('')
  const [type, setType] = useState<AccountType>('expense')
  const [normal, setNormal] = useState<NormalBalance>('debit')

  return (
    <Dialog
      open={open}
      onClose={onClose}
      width={440}
      title={title}
      description="Codes follow the template pattern: 4 digits, or 4 digits, a dash, and 2 digits for sub-accounts."
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button
            disabled={busy}
            onClick={() => onSubmit({ code: code.trim(), name: name.trim(), account_type: type, normal_balance: normal })}
          >
            {busy ? 'Saving' : 'Add account'}
          </Button>
        </>
      }
    >
      <div style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        <div style={{ display: 'grid', gridTemplateColumns: '120px 1fr', gap: 12 }}>
          <Input label="Code" placeholder="6300" required value={code} onChange={(e) => setCode(e.target.value)} />
          <Input label="Name" required maxLength={120} value={name} onChange={(e) => setName(e.target.value)} />
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Select
            label="Type"
            options={Object.entries(TYPE_LABEL).map(([value, label]) => ({ value, label }))}
            value={type}
            onChange={(e) => {
              const t = e.target.value as AccountType
              setType(t)
              setNormal(t === 'asset' || t === 'expense' ? 'debit' : 'credit')
            }}
          />
          <Select
            label="Normal balance"
            options={[
              { value: 'debit', label: 'Debit' },
              { value: 'credit', label: 'Credit' },
            ]}
            value={normal}
            onChange={(e) => setNormal(e.target.value as NormalBalance)}
          />
        </div>
      </div>
    </Dialog>
  )
}

function EditAccountForm({
  account,
  error,
  busy,
  onSubmit,
}: {
  account: Account
  error: string | null
  busy: boolean
  onSubmit: (form: { code: string; name: string }) => void
}) {
  const [code, setCode] = useState(account.code)
  const [name, setName] = useState(account.name)
  return (
    <div style={{ display: 'grid', gap: 14 }}>
      <FormError message={error} />
      <div style={{ display: 'grid', gridTemplateColumns: '120px 1fr', gap: 12 }}>
        <Input label="Code" value={code} onChange={(e) => setCode(e.target.value)} />
        <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} />
      </div>
      <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
        <Button size="sm" disabled={busy} onClick={() => onSubmit({ code: code.trim(), name: name.trim() })}>
          {busy ? 'Saving' : 'Save changes'}
        </Button>
      </div>
    </div>
  )
}
