import { useMemo, useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Amount, Button, Card, DataTable, Dialog, Input, Select, Toast, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { FormError } from '@/auth/AuthCard'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { useAccounts } from '@/features/coa/hooks'
import { localToday } from '@/lib/dates'
import type { StockAdjustment } from '@/lib/database.types'
import { useAdjustments, useItems, usePostAdjustment } from './hooks'

export function AdjustmentsPage() {
  const client = useActiveClient()
  const { data: adjustments, isPending } = useAdjustments(client.id)
  const { data: items } = useItems(client.id)
  const { data: accounts } = useAccounts(client.id)
  const [adding, setAdding] = useState(false)
  const [toast, setToast] = useState<string | null>(null)

  const itemName = useMemo(() => new Map((items ?? []).map((i) => [i.id, `${i.sku} ${i.name}`])), [items])
  const accountName = useMemo(
    () => new Map((accounts ?? []).map((a) => [a.id, `${a.code} ${a.name}`])),
    [accounts],
  )

  const columns: Column<StockAdjustment>[] = [
    { key: 'adj_date', header: 'Date', width: 110, render: (a) => <span style={{ font: '400 13px/1 var(--font-mono)' }}>{a.adj_date}</span> },
    { key: 'item', header: 'Item', render: (a) => itemName.get(a.item_id) ?? '—' },
    {
      key: 'qty_delta',
      header: 'Qty +/-',
      width: 100,
      align: 'right',
      render: (a) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{Number(a.qty_delta)}</span>,
    },
    {
      key: 'unit_cost',
      header: 'Unit cost',
      width: 110,
      align: 'right',
      render: (a) => (a.unit_cost != null ? <Amount value={a.unit_cost} /> : '—'),
    },
    { key: 'account', header: 'Offset account', render: (a) => accountName.get(a.account_id) ?? '—' },
    { key: 'memo', header: 'Memo', render: (a) => a.memo || '—' },
  ]

  return (
    <>
      <TopBar
        title="Stock adjustments"
        subtitle="Opening stock, counts, and shrinkage — posted through the journal, corrected by further adjustments"
        actions={
          <Button size="sm" iconLeft="plus" disabled={!!client.archived_at} onClick={() => setAdding(true)}>
            New adjustment
          </Button>
        }
      />
      <PageBody>
        <Card padding="none">
          <DataTable
            rows={adjustments ?? []}
            columns={columns}
            rowKey={(a) => a.id}
            emptyMessage={isPending ? 'Loading…' : 'No adjustments yet.'}
            dense
          />
        </Card>
        {adding && (
          <AdjustmentDialog
            clientId={client.id}
            onClose={() => setAdding(false)}
            onDone={(msg) => { setToast(msg); setAdding(false) }}
          />
        )}
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </>
  )
}

function AdjustmentDialog({
  clientId,
  onClose,
  onDone,
}: {
  clientId: string
  onClose: () => void
  onDone: (msg: string) => void
}) {
  const { data: items } = useItems(clientId)
  const { data: accounts } = useAccounts(clientId)
  const post = usePostAdjustment(clientId)
  const [itemId, setItemId] = useState('')
  const [date, setDate] = useState(localToday())
  const [direction, setDirection] = useState<'in' | 'out'>('in')
  const [qty, setQty] = useState('')
  const [unitCost, setUnitCost] = useState('')
  const [accountId, setAccountId] = useState('')
  const [memo, setMemo] = useState('')
  const [error, setError] = useState<string | null>(null)

  const activeItems = useMemo(() => (items ?? []).filter((i) => !i.archived_at), [items])
  // The offset side: equity for opening stock, expense for shrinkage/write-offs.
  // Control, cash, and inventory accounts are rejected by the engine.
  const offsetAccounts = useMemo(
    () =>
      (accounts ?? []).filter(
        (a) =>
          !a.archived_at &&
          ['expense', 'equity', 'income'].includes(a.account_type) &&
          a.code !== '1200',
      ),
    [accounts],
  )

  function submit() {
    setError(null)
    const q = Number(qty)
    if (!itemId || !(q > 0)) {
      setError('Choose an item and a quantity above zero.')
      return
    }
    if (direction === 'in' && !(Number(unitCost) > 0)) {
      setError('Stock coming in needs its unit cost.')
      return
    }
    if (!accountId) {
      setError('Choose the offset account.')
      return
    }
    post.mutate(
      {
        itemId,
        date,
        qtyDelta: direction === 'in' ? q : -q,
        unitCost: direction === 'in' ? Number(unitCost) : null,
        accountId,
        memo: memo.trim(),
      },
      {
        onSuccess: () => onDone('Adjustment posted'),
        onError: (err) => setError(messageOf(err, 'Could not post the adjustment.')),
      },
    )
  }

  return (
    <Dialog
      open
      onClose={onClose}
      width={520}
      title="New stock adjustment"
      description="Posts immediately through the journal engine. Opening stock: in, against an equity account. Shrinkage: out, against an expense."
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="accent" disabled={post.isPending} onClick={submit}>
            {post.isPending ? 'Working' : 'Post adjustment'}
          </Button>
        </>
      }
    >
      <div style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        <Select
          label="Item"
          placeholder="Choose an item"
          options={activeItems.map((i) => ({ value: i.id, label: `${i.sku} ${i.name}` }))}
          value={itemId}
          onChange={(e) => setItemId(e.target.value)}
        />
        <div style={{ display: 'grid', gridTemplateColumns: '140px minmax(0, 1fr) minmax(0, 1fr)', gap: 12 }}>
          <Select
            label="Direction"
            options={[
              { value: 'in', label: 'Stock in (+)' },
              { value: 'out', label: 'Stock out (−)' },
            ]}
            value={direction}
            onChange={(e) => setDirection(e.target.value as 'in' | 'out')}
          />
          <Input label="Quantity" type="number" min="0" step="0.0001" placeholder="0" value={qty} onChange={(e) => setQty(e.target.value)} />
          <Input
            label="Unit cost"
            type="number"
            min="0"
            step="0.01"
            placeholder="0.00"
            value={unitCost}
            disabled={direction === 'out'}
            onChange={(e) => setUnitCost(e.target.value)}
            hint={direction === 'out' ? 'FIFO cost applies' : undefined}
          />
        </div>
        <Input label="Date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
        <Select
          label="Offset account"
          placeholder="Equity for opening stock, expense for shrinkage"
          options={offsetAccounts.map((a) => ({ value: a.id, label: `${a.code} ${a.name}` }))}
          value={accountId}
          onChange={(e) => setAccountId(e.target.value)}
        />
        <Input label="Memo" value={memo} onChange={(e) => setMemo(e.target.value)} />
      </div>
    </Dialog>
  )
}
