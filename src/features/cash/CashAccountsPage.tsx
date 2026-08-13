import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { messageOf } from '@/lib/errors'
import { Amount, Button, Card, DataTable, Dialog, Input, Select, Toast, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { FormError } from '@/auth/AuthCard'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { useAccounts } from '@/features/coa/hooks'
import { useSaveDraft, usePostEntry } from '@/features/journal/hooks'
import { supabase } from '@/lib/supabase'
import { keys } from '@/lib/queryKeys'
import { localToday } from '@/lib/dates'
import type { Account, TrialBalanceRow } from '@/lib/database.types'

// The actual home for cash: every 1000-series account with its live balance,
// plus transfers between them (a posted journal entry, nothing special).
export function CashAccountsPage() {
  const client = useActiveClient()
  const { data: accounts } = useAccounts(client.id)
  const [transferring, setTransferring] = useState(false)
  const [toast, setToast] = useState<string | null>(null)

  const today = localToday()
  const { data: tb, isPending } = useQuery({
    queryKey: keys.trialBalance(client.id, '1900-01-01', today),
    queryFn: async () => {
      const { data, error } = await supabase.rpc('trial_balance', {
        p_client_id: client.id,
        p_date_from: '1900-01-01',
        p_date_to: today,
      })
      if (error) throw error
      return data as TrialBalanceRow[]
    },
  })

  const cashRows = useMemo(() => {
    const balances = new Map(
      (tb ?? []).map((r) => [r.account_id, Number(r.total_debit) - Number(r.total_credit)]),
    )
    return (accounts ?? [])
      .filter((a) => a.code.startsWith('1000') && !a.archived_at)
      .map((a) => ({ ...a, balance: balances.get(a.id) ?? 0 }))
  }, [accounts, tb])
  const totalCash = cashRows.reduce((s, a) => s + a.balance, 0)

  const columns: Column<(typeof cashRows)[number]>[] = [
    {
      key: 'code',
      header: 'Code',
      width: 110,
      render: (a) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{a.code}</span>,
    },
    { key: 'name', header: 'Account' },
    { key: 'balance', header: 'Balance', width: 150, align: 'right', render: (a) => <Amount value={a.balance} /> },
  ]

  return (
    <>
      <TopBar
        title="Cash accounts"
        subtitle="Cash on hand and in bank — collections, payments, expenses, and transfers all move through here"
        actions={
          <Button size="sm" iconLeft="arrow-left-right" disabled={!!client.archived_at || cashRows.length < 2} onClick={() => setTransferring(true)}>
            New transfer
          </Button>
        }
      />
      <PageBody>
        <Card padding="none">
          <DataTable
            rows={cashRows}
            columns={columns}
            rowKey={(a) => a.id}
            emptyMessage={isPending ? 'Loading…' : 'No active 1000-series cash accounts.'}
            dense
          />
          {cashRows.length > 0 && (
            <div
              style={{
                display: 'flex',
                justifyContent: 'flex-end',
                gap: 24,
                padding: '13px 20px',
                borderTop: '1px solid var(--border-default)',
                background: 'var(--sand-100)',
              }}
            >
              <span style={{ font: 'var(--type-label)', color: 'var(--text-secondary)' }}>Total cash</span>
              <Amount value={totalCash} />
            </div>
          )}
        </Card>
        {transferring && (
          <TransferDialog
            clientId={client.id}
            cashAccounts={cashRows}
            onClose={() => setTransferring(false)}
            onDone={(msg) => { setToast(msg); setTransferring(false) }}
          />
        )}
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </>
  )
}

function TransferDialog({
  clientId,
  cashAccounts,
  onClose,
  onDone,
}: {
  clientId: string
  cashAccounts: (Account & { balance: number })[]
  onClose: () => void
  onDone: (msg: string) => void
}) {
  const saveDraft = useSaveDraft(clientId)
  const postEntry = usePostEntry(clientId)
  const [fromId, setFromId] = useState('')
  const [toId, setToId] = useState('')
  const [date, setDate] = useState(localToday())
  const [amount, setAmount] = useState('')
  const [memo, setMemo] = useState('')
  const [error, setError] = useState<string | null>(null)
  const busy = saveDraft.isPending || postEntry.isPending

  function submit() {
    setError(null)
    const amt = Number(amount)
    if (!fromId || !toId || fromId === toId) {
      setError('Pick two different cash accounts.')
      return
    }
    if (!(amt > 0)) {
      setError('Enter an amount above zero.')
      return
    }
    const fromName = cashAccounts.find((a) => a.id === fromId)?.name ?? ''
    const toName = cashAccounts.find((a) => a.id === toId)?.name ?? ''
    saveDraft.mutate(
      {
        entryId: null,
        draft: {
          entryDate: date,
          memo: memo.trim() || `Transfer: ${fromName} to ${toName}`,
          lines: [
            { account_id: toId, debit: amt, credit: 0 },
            { account_id: fromId, debit: 0, credit: amt },
          ],
        },
      },
      {
        onSuccess: (entryId) =>
          postEntry.mutate(entryId, {
            onSuccess: () => onDone('Transfer posted'),
            onError: (err) => setError(messageOf(err, 'Could not post the transfer.')),
          }),
        onError: (err) => setError(messageOf(err, 'Could not save the transfer.')),
      },
    )
  }

  return (
    <Dialog
      open
      onClose={onClose}
      width={460}
      title="Transfer between cash accounts"
      description="Posts a journal entry moving money between two 1000-series accounts. It appears in both cash books."
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="accent" disabled={busy} onClick={submit}>
            {busy ? 'Working' : 'Post transfer'}
          </Button>
        </>
      }
    >
      <div style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        <Select
          label="From"
          placeholder="Source account"
          options={cashAccounts.map((a) => ({ value: a.id, label: `${a.code} ${a.name}` }))}
          value={fromId}
          onChange={(e) => setFromId(e.target.value)}
        />
        <Select
          label="To"
          placeholder="Destination account"
          options={cashAccounts.filter((a) => a.id !== fromId).map((a) => ({ value: a.id, label: `${a.code} ${a.name}` }))}
          value={toId}
          onChange={(e) => setToId(e.target.value)}
        />
        <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) 150px', gap: 12 }}>
          <Input label="Amount" type="number" min="0" step="0.01" placeholder="0.00" value={amount} onChange={(e) => setAmount(e.target.value)} />
          <Input label="Date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
        </div>
        <Input label="Memo" placeholder="Optional" value={memo} onChange={(e) => setMemo(e.target.value)} />
      </div>
    </Dialog>
  )
}
