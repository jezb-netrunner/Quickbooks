import { useMemo, useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Amount, Badge, Button, Card, DataTable, Dialog, Input, Select, Toast, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { FormError } from '@/auth/AuthCard'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { useAccounts } from '@/features/coa/hooks'
import type { Account, Item } from '@/lib/database.types'
import { useCreateItem, useItems, useUpdateItem } from './hooks'

export function ItemsPage() {
  const client = useActiveClient()
  const { data: items, isPending } = useItems(client.id)
  const { data: accounts } = useAccounts(client.id)
  const [adding, setAdding] = useState(false)
  const [editing, setEditing] = useState<Item | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  const columns: Column<Item>[] = [
    {
      key: 'sku',
      header: 'SKU',
      width: 130,
      render: (i) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{i.sku}</span>,
    },
    { key: 'name', header: 'Item' },
    { key: 'uom', header: 'Unit', width: 70 },
    {
      key: 'sales_price',
      header: 'Sales price',
      width: 110,
      align: 'right',
      render: (i) => (i.sales_price != null ? <Amount value={i.sales_price} /> : '—'),
    },
    {
      key: 'purchase_cost',
      header: 'Last cost',
      width: 110,
      align: 'right',
      render: (i) => (i.purchase_cost != null ? <Amount value={i.purchase_cost} /> : '—'),
    },
    {
      key: 'status',
      header: 'Status',
      width: 90,
      render: (i) => <Badge tone={i.archived_at ? 'neutral' : 'positive'}>{i.archived_at ? 'Archived' : 'Active'}</Badge>,
    },
  ]

  return (
    <>
      <TopBar
        title="Items"
        subtitle="Inventory items are FIFO-costed; selling one books its cost of sales automatically"
        actions={
          <Button size="sm" iconLeft="plus" disabled={!!client.archived_at} onClick={() => setAdding(true)}>
            New item
          </Button>
        }
      />
      <PageBody>
        <Card padding="none">
          <DataTable
            rows={items ?? []}
            columns={columns}
            rowKey={(i) => i.id}
            onRowClick={(i) => setEditing(i)}
            emptyMessage={isPending ? 'Loading…' : 'No items yet — add what this client buys and sells.'}
            dense
          />
        </Card>
        {(adding || editing) && (
          <ItemDialog
            clientId={client.id}
            accounts={accounts ?? []}
            item={editing}
            onClose={() => { setAdding(false); setEditing(null) }}
            onDone={(msg) => { setToast(msg); setAdding(false); setEditing(null) }}
          />
        )}
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </>
  )
}

function ItemDialog({
  clientId,
  accounts,
  item,
  onClose,
  onDone,
}: {
  clientId: string
  accounts: Account[]
  item: Item | null
  onClose: () => void
  onDone: (msg: string) => void
}) {
  const create = useCreateItem(clientId)
  const update = useUpdateItem(clientId)
  const [sku, setSku] = useState(item?.sku ?? '')
  const [name, setName] = useState(item?.name ?? '')
  const [uom, setUom] = useState(item?.uom ?? 'pc')
  const [incomeAccountId, setIncomeAccountId] = useState(item?.income_account_id ?? '')
  const [salesPrice, setSalesPrice] = useState(item?.sales_price != null ? String(item.sales_price) : '')
  const [purchaseCost, setPurchaseCost] = useState(item?.purchase_cost != null ? String(item.purchase_cost) : '')
  const [error, setError] = useState<string | null>(null)
  const busy = create.isPending || update.isPending

  const incomeAccounts = useMemo(
    () => accounts.filter((a) => !a.archived_at && a.account_type === 'income'),
    [accounts],
  )

  function submit() {
    setError(null)
    const input = {
      sku: sku.trim(),
      name: name.trim(),
      uom: uom.trim() || 'pc',
      income_account_id: incomeAccountId || null,
      sales_price: salesPrice ? Number(salesPrice) : null,
      purchase_cost: purchaseCost ? Number(purchaseCost) : null,
    }
    if (!input.sku || !input.name) {
      setError('SKU and name are required.')
      return
    }
    if (item) {
      update.mutate(
        { id: item.id, patch: input },
        {
          onSuccess: () => onDone('Item updated'),
          onError: (err) => setError(messageOf(err, 'Could not update the item.')),
        },
      )
    } else {
      create.mutate(input, {
        onSuccess: () => onDone(`${input.sku} added`),
        onError: (err) => setError(messageOf(err, 'Could not add the item.')),
      })
    }
  }

  return (
    <Dialog
      open
      onClose={onClose}
      width={520}
      title={item ? `${item.sku} · edit` : 'New item'}
      description="Item lines on purchases receive stock at cost; item lines on invoices relieve it FIFO."
      footer={
        <>
          {item && (
            <Button
              variant={item.archived_at ? 'secondary' : 'danger'}
              disabled={busy}
              onClick={() =>
                update.mutate(
                  { id: item.id, patch: { archived_at: item.archived_at ? null : new Date().toISOString() } },
                  {
                    onSuccess: () => onDone(item.archived_at ? 'Item restored' : 'Item archived'),
                    onError: (err) => setError(messageOf(err, 'Could not change the item.')),
                  },
                )
              }
            >
              {item.archived_at ? 'Restore' : 'Archive'}
            </Button>
          )}
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="accent" disabled={busy} onClick={submit}>
            {busy ? 'Working' : item ? 'Save changes' : 'Add item'}
          </Button>
        </>
      }
    >
      <div style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 2fr)', gap: 12 }}>
          <Input label="SKU" value={sku} disabled={busy} onChange={(e) => setSku(e.target.value)} />
          <Input label="Name" value={name} disabled={busy} onChange={(e) => setName(e.target.value)} />
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '100px minmax(0, 1fr)', gap: 12 }}>
          <Input label="Unit" value={uom} disabled={busy} onChange={(e) => setUom(e.target.value)} />
          <Select
            label="Income account for sales"
            placeholder="Pick on each invoice"
            options={incomeAccounts.map((a) => ({ value: a.id, label: `${a.code} ${a.name}` }))}
            value={incomeAccountId}
            disabled={busy}
            onChange={(e) => setIncomeAccountId(e.target.value)}
          />
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)', gap: 12 }}>
          <Input
            label="Default sales price"
            type="number"
            min="0"
            step="0.01"
            placeholder="0.00"
            value={salesPrice}
            disabled={busy}
            onChange={(e) => setSalesPrice(e.target.value)}
          />
          <Input
            label="Default purchase cost"
            type="number"
            min="0"
            step="0.01"
            placeholder="0.00"
            value={purchaseCost}
            disabled={busy}
            onChange={(e) => setPurchaseCost(e.target.value)}
          />
        </div>
      </div>
    </Dialog>
  )
}
