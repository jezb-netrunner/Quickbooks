import { useMemo, useRef, useState } from 'react'
import { messageOf } from '@/lib/errors'
import {
  Amount,
  Badge,
  Button,
  Card,
  Checkbox,
  DataTable,
  Dialog,
  IconButton,
  Input,
  Select,
  Tabs,
  Toast,
  type Column,
} from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { FormError } from '@/auth/AuthCard'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { useAccounts } from '@/features/coa/hooks'
import { useTaxCodes } from '@/features/tax/hooks'
import { parseCsv } from '@/lib/csv'
import type { Account, BankImportProfile, BankRule, BankTxn } from '@/lib/database.types'
import type { ParsedBankRow, ProfileForm } from './api'
import { parseStatement } from './statement'
import {
  useApplyBankRules,
  useBankProfiles,
  useBankRules,
  useBankTxns,
  useCategorizeBankTxn,
  useCreateBankRule,
  useDeleteBankProfile,
  useDeleteBankRule,
  useExcludeBankTxn,
  useImportBankTxns,
  useRestoreBankTxn,
  useSaveBankProfile,
} from './hooks'

const CONTROL_CODES = new Set(['1100', '2000', '1200'])

export function BankImportPage() {
  const client = useActiveClient()
  const { data: accounts } = useAccounts(client.id)
  const { data: txns } = useBankTxns(client.id)
  const [tab, setTab] = useState('queue')
  const [toast, setToast] = useState<string | null>(null)

  const pending = useMemo(() => (txns ?? []).filter((t) => t.status === 'pending'), [txns])
  const excluded = useMemo(() => (txns ?? []).filter((t) => t.status === 'excluded'), [txns])

  return (
    <>
      <TopBar
        title="Bank import"
        subtitle={
          client.archived_at
            ? 'Archived — the books are read-only'
            : `${pending.length} statement ${pending.length === 1 ? 'line' : 'lines'} waiting to be categorized`
        }
      />
      <PageBody>
        <Tabs
          value={tab}
          onChange={setTab}
          items={[
            { value: 'queue', label: 'Queue', count: pending.length },
            { value: 'import', label: 'Import statement' },
            { value: 'rules', label: 'Rules' },
          ]}
        />
        {tab === 'queue' && (
          <QueueTab
            clientId={client.id}
            readOnly={!!client.archived_at}
            accounts={accounts ?? []}
            pending={pending}
            excluded={excluded}
            onDone={setToast}
          />
        )}
        {tab === 'import' && (
          <ImportTab clientId={client.id} readOnly={!!client.archived_at} accounts={accounts ?? []} onDone={setToast} />
        )}
        {tab === 'rules' && (
          <RulesTab clientId={client.id} readOnly={!!client.archived_at} accounts={accounts ?? []} onDone={setToast} />
        )}
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </>
  )
}

// ------------------------------------------------------------------- Queue

function QueueTab({
  clientId,
  readOnly,
  accounts,
  pending,
  excluded,
  onDone,
}: {
  clientId: string
  readOnly: boolean
  accounts: Account[]
  pending: BankTxn[]
  excluded: BankTxn[]
  onDone: (msg: string) => void
}) {
  const categorize = useCategorizeBankTxn(clientId)
  const exclude = useExcludeBankTxn(clientId)
  const restore = useRestoreBankTxn(clientId)
  const applyRules = useApplyBankRules(clientId)
  const [chosen, setChosen] = useState<Record<string, string>>({})
  // P2-22: optional input-VAT split per outflow line.
  const [chosenTax, setChosenTax] = useState<Record<string, string>>({})
  const { data: taxCodes } = useTaxCodes(clientId)
  const vatOptions = useMemo(
    () =>
      (taxCodes ?? [])
        .filter((t) => t.active && t.kind === 'input_vat')
        .map((t) => ({
          value: t.id,
          label: `${t.code}${t.currentRate != null ? ` (${(t.currentRate * 100).toFixed(0)}%)` : ''}`,
        })),
    [taxCodes],
  )
  const [showExcluded, setShowExcluded] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // The engine's own guards, mirrored so the picker never offers an account
  // the server would reject: no control accounts, never the line's own bank
  // account. Everything else is fair game — transfers land on other 1000s.
  const accountOptions = useMemo(
    () =>
      accounts
        .filter((a) => !a.archived_at && !CONTROL_CODES.has(a.code))
        .map((a) => ({ value: a.id, label: `${a.code} ${a.name}` })),
    [accounts],
  )
  const accountName = useMemo(() => new Map(accounts.map((a) => [a.id, `${a.code} ${a.name}`])), [accounts])
  const busy = categorize.isPending || exclude.isPending || restore.isPending || applyRules.isPending

  const columns: Column<BankTxn>[] = [
    {
      key: 'txn_date',
      header: 'Date',
      width: 105,
      render: (t) => <span style={{ font: '400 13px/1 var(--font-mono)' }}>{t.txn_date}</span>,
    },
    { key: 'description', header: 'Description', render: (t) => t.description || '—' },
    {
      key: 'bank',
      header: 'Bank account',
      width: 160,
      render: (t) => (
        <span style={{ font: 'var(--type-label)', color: 'var(--text-secondary)' }}>
          {accountName.get(t.bank_account_id) ?? '—'}
        </span>
      ),
    },
    {
      key: 'amount',
      header: 'Amount',
      width: 120,
      align: 'right',
      render: (t) => <Amount value={t.amount} />,
    },
    {
      key: 'account',
      header: 'Post to',
      width: 230,
      render: (t) => (
        <Select
          aria-label={`Account for ${t.description || t.txn_date}`}
          fieldSize="sm"
          placeholder="Choose an account"
          options={accountOptions.filter((o) => o.value !== t.bank_account_id)}
          value={chosen[t.id] ?? ''}
          disabled={readOnly || busy}
          onChange={(e) => setChosen((prev) => ({ ...prev, [t.id]: e.target.value }))}
        />
      ),
    },
    {
      key: 'vat',
      header: 'Input VAT',
      width: 130,
      render: (t) =>
        Number(t.amount) < 0 && vatOptions.length > 0 ? (
          <Select
            aria-label={`Input VAT for ${t.description || t.txn_date}`}
            fieldSize="sm"
            placeholder="No VAT"
            options={vatOptions}
            value={chosenTax[t.id] ?? ''}
            disabled={readOnly || busy}
            onChange={(e) => setChosenTax((prev) => ({ ...prev, [t.id]: e.target.value }))}
          />
        ) : (
          <span style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>—</span>
        ),
    },
    {
      key: 'actions',
      header: '',
      width: 150,
      align: 'right',
      render: (t) => (
        <span style={{ display: 'inline-flex', gap: 6, alignItems: 'center' }}>
          <Button
            size="sm"
            disabled={readOnly || busy || !chosen[t.id]}
            onClick={() => {
              setError(null)
              categorize.mutate(
                { txnId: t.id, accountId: chosen[t.id], taxCodeId: chosenTax[t.id] || null },
                {
                  onSuccess: () => onDone('Posted through the journal'),
                  onError: (err) => setError(messageOf(err, 'Could not categorize the line.')),
                },
              )
            }}
          >
            Post
          </Button>
          <IconButton
            icon="x"
            label="Exclude — not a book transaction"
            size={14}
            disabled={readOnly || busy}
            onClick={() => {
              setError(null)
              exclude.mutate(t.id, {
                onSuccess: () => onDone('Line excluded'),
                onError: (err) => setError(messageOf(err, 'Could not exclude the line.')),
              })
            }}
          />
        </span>
      ),
    },
  ]

  return (
    <>
      {error && <FormError message={error} />}
      <Card
        title="Waiting for categorization"
        subtitle="Each line posts DR/CR against the bank account through the journal engine"
        padding="none"
        action={
          <Button
            size="sm"
            variant="secondary"
            iconLeft="sliders-horizontal"
            disabled={readOnly || busy || pending.length === 0}
            onClick={() => {
              setError(null)
              applyRules.mutate(undefined, {
                onSuccess: (n) => onDone(n === 0 ? 'No lines matched a rule' : `${n} ${n === 1 ? 'line' : 'lines'} categorized by rules`),
                onError: (err) => setError(messageOf(err, 'Could not apply the rules.')),
              })
            }}
          >
            Apply rules
          </Button>
        }
      >
        <DataTable
          rows={pending}
          columns={columns}
          rowKey={(t) => t.id}
          emptyMessage="Nothing waiting — import a statement to fill the queue."
          dense
        />
      </Card>
      <div>
        <Button size="sm" variant="ghost" onClick={() => setShowExcluded((v) => !v)}>
          {showExcluded ? 'Hide excluded lines' : `Excluded lines (${excluded.length})`}
        </Button>
      </div>
      {showExcluded && (
        <Card padding="none">
          <DataTable
            rows={excluded}
            rowKey={(t) => t.id}
            dense
            emptyMessage="Nothing excluded."
            columns={[
              { key: 'txn_date', header: 'Date', width: 105, render: (t) => <span style={{ font: '400 13px/1 var(--font-mono)' }}>{t.txn_date}</span> },
              { key: 'description', header: 'Description', render: (t) => t.description || '—' },
              { key: 'amount', header: 'Amount', width: 120, align: 'right', render: (t) => <Amount value={t.amount} muted /> },
              {
                key: 'actions',
                header: '',
                width: 110,
                align: 'right',
                render: (t) => (
                  <Button
                    size="sm"
                    variant="ghost"
                    disabled={readOnly || busy}
                    onClick={() =>
                      restore.mutate(t.id, {
                        onSuccess: () => onDone('Line restored to the queue'),
                        onError: (err) => setError(messageOf(err, 'Could not restore the line.')),
                      })
                    }
                  >
                    Restore
                  </Button>
                ),
              },
            ]}
          />
        </Card>
      )}
    </>
  )
}

// ------------------------------------------------------------------ Import

function ImportTab({
  clientId,
  readOnly,
  accounts,
  onDone,
}: {
  clientId: string
  readOnly: boolean
  accounts: Account[]
  onDone: (msg: string) => void
}) {
  const { data: profiles } = useBankProfiles(clientId)
  const importTxns = useImportBankTxns(clientId)
  const removeProfile = useDeleteBankProfile(clientId)
  const [profileId, setProfileId] = useState('')
  const [editing, setEditing] = useState<{ profile: BankImportProfile | null } | null>(null)
  const [parsed, setParsed] = useState<{ rows: ParsedBankRow[]; unparsed: number; filename: string } | null>(null)
  const [error, setError] = useState<string | null>(null)
  const fileRef = useRef<HTMLInputElement>(null)

  const profile = (profiles ?? []).find((p) => p.id === profileId) ?? null
  const accountName = useMemo(() => new Map(accounts.map((a) => [a.id, `${a.code} ${a.name}`])), [accounts])

  function handleFile(file: File) {
    if (!profile) return
    setError(null)
    file
      .text()
      .then((text) => {
        const cells = parseCsv(text)
        const result = parseStatement(cells, profile)
        if (result.rows.length === 0) {
          setParsed(null)
          setError(
            'No usable lines — check the profile\'s column numbers, date format, and rows to skip against the file.',
          )
          return
        }
        setParsed({ ...result, filename: file.name })
      })
      .catch(() => setError('Could not read that file.'))
  }

  const previewColumns: Column<ParsedBankRow>[] = [
    { key: 'd', header: 'Date', width: 110, render: (r) => <span style={{ font: '400 13px/1 var(--font-mono)' }}>{r.d}</span> },
    { key: 'm', header: 'Description', render: (r) => r.m || '—' },
    { key: 'a', header: 'Amount', width: 130, align: 'right', render: (r) => <Amount value={r.a} /> },
  ]

  return (
    <>
      {error && <FormError message={error} />}
      <Card
        title="Statement file"
        subtitle="Pick the saved mapping for this bank, then choose the CSV export from its portal"
      >
        <div style={{ display: 'grid', gap: 14 }}>
          <div style={{ display: 'flex', gap: 10, alignItems: 'flex-end', flexWrap: 'wrap' }}>
            <div style={{ width: 260 }}>
              <Select
                label="Bank profile"
                placeholder="Choose a mapping"
                options={(profiles ?? []).map((p) => ({
                  value: p.id,
                  label: `${p.name} → ${accountName.get(p.bank_account_id) ?? '?'}`,
                }))}
                value={profileId}
                onChange={(e) => { setProfileId(e.target.value); setParsed(null) }}
              />
            </div>
            <Button size="sm" variant="secondary" iconLeft="plus" disabled={readOnly} onClick={() => setEditing({ profile: null })}>
              New profile
            </Button>
            {profile && (
              <>
                <Button size="sm" variant="ghost" disabled={readOnly} onClick={() => setEditing({ profile })}>
                  Edit
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  disabled={readOnly || removeProfile.isPending}
                  onClick={() =>
                    removeProfile.mutate(profile.id, {
                      onSuccess: () => { setProfileId(''); setParsed(null); onDone('Profile deleted') },
                      onError: (err) => setError(messageOf(err, 'Could not delete the profile.')),
                    })
                  }
                >
                  Delete
                </Button>
              </>
            )}
          </div>
          <div>
            <input
              ref={fileRef}
              type="file"
              accept=".csv,text/csv,text/plain"
              style={{ display: 'none' }}
              onChange={(e) => {
                const f = e.target.files?.[0]
                if (f) handleFile(f)
                e.target.value = ''
              }}
            />
            <Button iconLeft="upload" disabled={readOnly || !profile} onClick={() => fileRef.current?.click()}>
              Choose CSV file
            </Button>
          </div>
        </div>
      </Card>

      {parsed && (
        <Card
          title={`Preview — ${parsed.filename}`}
          subtitle={`${parsed.rows.length} ${parsed.rows.length === 1 ? 'line' : 'lines'} parsed${parsed.unparsed > 0 ? ` · ${parsed.unparsed} skipped (no date or amount)` : ''} — duplicates are detected on import, so re-running a file is safe`}
          padding="none"
          action={
            <Button
              size="sm"
              disabled={readOnly || importTxns.isPending}
              onClick={() => {
                if (!profile) return
                setError(null)
                importTxns.mutate(
                  { bankAccountId: profile.bank_account_id, rows: parsed.rows },
                  {
                    onSuccess: (r) => {
                      setParsed(null)
                      onDone(
                        `${r.inserted} imported · ${r.duplicates} duplicate${r.duplicates === 1 ? '' : 's'} skipped${r.skipped > 0 ? ` · ${r.skipped} rejected` : ''}`,
                      )
                    },
                    onError: (err) => setError(messageOf(err, 'Import failed.')),
                  },
                )
              }}
            >
              {importTxns.isPending ? 'Importing' : `Import ${parsed.rows.length} lines`}
            </Button>
          }
        >
          <DataTable rows={parsed.rows.slice(0, 12)} columns={previewColumns} rowKey={(r) => `${r.d}|${r.m}|${r.a}`} dense />
        </Card>
      )}

      {editing && (
        <ProfileDialog
          clientId={clientId}
          accounts={accounts}
          profile={editing.profile}
          onClose={() => setEditing(null)}
          onSaved={(p) => { setEditing(null); setProfileId(p.id); onDone('Profile saved') }}
        />
      )}
    </>
  )
}

function ProfileDialog({
  clientId,
  accounts,
  profile,
  onClose,
  onSaved,
}: {
  clientId: string
  accounts: Account[]
  profile: BankImportProfile | null
  onClose: () => void
  onSaved: (p: BankImportProfile) => void
}) {
  const save = useSaveBankProfile(clientId)
  const [name, setName] = useState(profile?.name ?? '')
  const [bankAccountId, setBankAccountId] = useState(profile?.bank_account_id ?? '')
  const [mode, setMode] = useState<'amount' | 'split'>(profile?.amount_col === null ? 'split' : 'amount')
  const [dateCol, setDateCol] = useState(String(profile?.date_col ?? 1))
  const [descCol, setDescCol] = useState(String(profile?.desc_col ?? 2))
  const [amountCol, setAmountCol] = useState(String(profile?.amount_col ?? 3))
  const [debitCol, setDebitCol] = useState(String(profile?.debit_col ?? 3))
  const [creditCol, setCreditCol] = useState(String(profile?.credit_col ?? 4))
  const [dateFormat, setDateFormat] = useState<'YMD' | 'DMY' | 'MDY'>(profile?.date_format ?? 'MDY')
  const [skipRows, setSkipRows] = useState(String(profile?.skip_rows ?? 1))
  const [negate, setNegate] = useState(profile?.negate ?? false)
  const [error, setError] = useState<string | null>(null)

  const bankAccounts = accounts.filter((a) => !a.archived_at && a.code.startsWith('1000'))
  const col = (s: string) => Math.max(1, Math.trunc(Number(s) || 1))
  const valid = name.trim().length > 0 && bankAccountId !== ''

  function toForm(): ProfileForm {
    return {
      name: name.trim(),
      bank_account_id: bankAccountId,
      date_col: col(dateCol),
      desc_col: col(descCol),
      amount_col: mode === 'amount' ? col(amountCol) : null,
      debit_col: mode === 'split' ? col(debitCol) : null,
      credit_col: mode === 'split' ? col(creditCol) : null,
      date_format: dateFormat,
      skip_rows: Math.max(0, Math.trunc(Number(skipRows) || 0)),
      negate,
    }
  }

  return (
    <Dialog
      open
      onClose={onClose}
      width={520}
      title={profile ? `Edit ${profile.name}` : 'New bank profile'}
      description="How this bank's CSV lays out its columns — saved once per bank, reused every month. Columns count from 1."
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button
            disabled={!valid || save.isPending}
            onClick={() =>
              save.mutate(
                { profileId: profile?.id ?? null, form: toForm() },
                {
                  onSuccess: onSaved,
                  onError: (err) => setError(messageOf(err, 'Could not save the profile.')),
                },
              )
            }
          >
            {save.isPending ? 'Saving' : 'Save profile'}
          </Button>
        </>
      }
    >
      <div style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)', gap: 12 }}>
          <Input label="Profile name" placeholder="BPI checking" value={name} onChange={(e) => setName(e.target.value)} />
          <Select
            label="Deposits land in"
            placeholder="Cash or bank account"
            options={bankAccounts.map((a) => ({ value: a.id, label: `${a.code} ${a.name}` }))}
            value={bankAccountId}
            onChange={(e) => setBankAccountId(e.target.value)}
          />
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, minmax(0, 1fr))', gap: 12 }}>
          <Input label="Date column" type="number" min="1" step="1" value={dateCol} onChange={(e) => setDateCol(e.target.value)} />
          <Input label="Description column" type="number" min="1" step="1" value={descCol} onChange={(e) => setDescCol(e.target.value)} />
          <Input label="Header rows to skip" type="number" min="0" step="1" value={skipRows} onChange={(e) => setSkipRows(e.target.value)} />
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)', gap: 12 }}>
          <Select
            label="Date format"
            options={[
              { value: 'MDY', label: 'MM/DD/YYYY' },
              { value: 'DMY', label: 'DD/MM/YYYY' },
              { value: 'YMD', label: 'YYYY-MM-DD' },
            ]}
            value={dateFormat}
            onChange={(e) => setDateFormat(e.target.value as 'YMD' | 'DMY' | 'MDY')}
          />
          <Select
            label="Amounts appear as"
            options={[
              { value: 'amount', label: 'One signed column' },
              { value: 'split', label: 'Separate debit / credit columns' },
            ]}
            value={mode}
            onChange={(e) => setMode(e.target.value as 'amount' | 'split')}
          />
        </div>
        {mode === 'amount' ? (
          <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)', gap: 12, alignItems: 'end' }}>
            <Input label="Amount column" type="number" min="1" step="1" value={amountCol} onChange={(e) => setAmountCol(e.target.value)} />
            <Checkbox
              label="Flip the sign (bank shows money in as negative)"
              checked={negate}
              onChange={(e) => setNegate(e.target.checked)}
            />
          </div>
        ) : (
          <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)', gap: 12 }}>
            <Input label="Debit (money out) column" type="number" min="1" step="1" value={debitCol} onChange={(e) => setDebitCol(e.target.value)} />
            <Input label="Credit (money in) column" type="number" min="1" step="1" value={creditCol} onChange={(e) => setCreditCol(e.target.value)} />
          </div>
        )}
      </div>
    </Dialog>
  )
}

// ------------------------------------------------------------------- Rules

function RulesTab({
  clientId,
  readOnly,
  accounts,
  onDone,
}: {
  clientId: string
  readOnly: boolean
  accounts: Account[]
  onDone: (msg: string) => void
}) {
  const { data: rules } = useBankRules(clientId)
  const create = useCreateBankRule(clientId)
  const remove = useDeleteBankRule(clientId)
  const [matchText, setMatchText] = useState('')
  const [accountId, setAccountId] = useState('')
  const [priority, setPriority] = useState('100')
  const [error, setError] = useState<string | null>(null)

  const accountOptions = useMemo(
    () =>
      accounts
        .filter((a) => !a.archived_at && !CONTROL_CODES.has(a.code))
        .map((a) => ({ value: a.id, label: `${a.code} ${a.name}` })),
    [accounts],
  )
  const accountName = useMemo(() => new Map(accounts.map((a) => [a.id, `${a.code} ${a.name}`])), [accounts])

  const columns: Column<BankRule>[] = [
    { key: 'priority', header: '#', width: 60, render: (r) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{r.priority}</span> },
    { key: 'match_text', header: 'Description contains', render: (r) => <span style={{ font: '400 13px/1 var(--font-mono)' }}>{r.match_text}</span> },
    { key: 'account', header: 'Posts to', render: (r) => accountName.get(r.account_id) ?? '—' },
    {
      key: 'active',
      header: 'Status',
      width: 100,
      render: (r) => (r.active ? <Badge tone="positive" dot>Active</Badge> : <Badge tone="neutral">Off</Badge>),
    },
    {
      key: 'actions',
      header: '',
      width: 60,
      align: 'right',
      render: (r) => (
        <IconButton
          icon="trash-2"
          label={`Delete rule ${r.match_text}`}
          size={14}
          disabled={readOnly || remove.isPending}
          onClick={() =>
            remove.mutate(r.id, {
              onSuccess: () => onDone('Rule deleted'),
              onError: (err) => setError(messageOf(err, 'Could not delete the rule.')),
            })
          }
        />
      ),
    },
  ]

  return (
    <>
      {error && <FormError message={error} />}
      <Card
        title="Categorization rules"
        subtitle="Lowest number runs first; the first rule whose text appears in a line's description wins"
      >
        <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1.2fr) minmax(0, 1.4fr) 90px auto', gap: 10, alignItems: 'end' }}>
          <Input
            label="Description contains"
            placeholder="meralco"
            value={matchText}
            disabled={readOnly}
            onChange={(e) => setMatchText(e.target.value)}
          />
          <Select
            label="Posts to"
            placeholder="Choose an account"
            options={accountOptions}
            value={accountId}
            disabled={readOnly}
            onChange={(e) => setAccountId(e.target.value)}
          />
          <Input label="Priority" type="number" min="1" step="1" value={priority} disabled={readOnly} onChange={(e) => setPriority(e.target.value)} />
          <Button
            iconLeft="plus"
            disabled={readOnly || create.isPending || matchText.trim().length < 2 || !accountId}
            onClick={() => {
              setError(null)
              create.mutate(
                { match_text: matchText.trim(), account_id: accountId, priority: Math.max(1, Math.trunc(Number(priority) || 100)) },
                {
                  onSuccess: () => { setMatchText(''); setAccountId(''); onDone('Rule added') },
                  onError: (err) => setError(messageOf(err, 'Could not add the rule.')),
                },
              )
            }}
          >
            Add rule
          </Button>
        </div>
      </Card>
      <Card padding="none">
        <DataTable
          rows={rules ?? []}
          columns={columns}
          rowKey={(r) => r.id}
          emptyMessage="No rules yet — add one, then run Apply rules from the queue."
          dense
        />
      </Card>
    </>
  )
}
