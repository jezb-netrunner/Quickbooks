import { useMemo, useState } from 'react'
import { Amount, Card, DataTable, ExportMenu, Input, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { localToday } from '@/lib/dates'
import type { InventoryValuationRow, StockCardRow } from '@/lib/database.types'
import type { ReportExport } from '@/lib/exports'
import { useStockCard, useValuation } from './hooks'

export function ValuationPage() {
  const client = useActiveClient()
  const { data: rows, isPending, isError } = useValuation(client.id)
  const [selected, setSelected] = useState<InventoryValuationRow | null>(null)

  const withStock = useMemo(() => (rows ?? []).filter((r) => Number(r.qty_on_hand) !== 0 || Number(r.value) !== 0), [rows])
  const totalValue = withStock.reduce((s, r) => s + Number(r.value), 0)

  const columns: Column<InventoryValuationRow>[] = [
    {
      key: 'sku',
      header: 'SKU',
      width: 130,
      render: (r) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{r.sku}</span>,
    },
    { key: 'name', header: 'Item' },
    { key: 'uom', header: 'Unit', width: 70 },
    {
      key: 'qty_on_hand',
      header: 'On hand',
      width: 100,
      align: 'right',
      render: (r) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{Number(r.qty_on_hand)}</span>,
    },
    { key: 'avg_cost', header: 'Avg cost', width: 110, align: 'right', render: (r) => <Amount value={Number(r.avg_cost)} /> },
    { key: 'value', header: 'Value', width: 130, align: 'right', render: (r) => <Amount value={r.value} /> },
  ]

  return (
    <>
      <TopBar
        title="Inventory valuation"
        subtitle="FIFO layers — the total always equals the 1200 Inventory balance on the books"
        actions={
          <ExportMenu
            disabled={withStock.length === 0}
            report={(): ReportExport => ({
              filename: `inventory-valuation_${client.code ?? client.name}`,
              title: 'Inventory valuation (FIFO)',
              subtitle: [client.name, `As of ${localToday()}`],
              header: ['SKU', 'Item', 'Unit', 'On hand', 'Avg cost', 'Value'],
              rows: withStock.map((r) => [r.sku, r.name, r.uom, r.qty_on_hand, r.avg_cost, r.value]),
              numericColumns: [3, 4, 5],
            })}
          />
        }
      />
      <PageBody>
        <Card padding="none">
          <DataTable
            rows={withStock}
            columns={columns}
            rowKey={(r) => r.item_id}
            onRowClick={(r) => setSelected(r)}
            emptyMessage={
              isPending
                ? 'Computing…'
                : isError
                  ? 'Could not load the valuation — check the connection and retry.'
                  : 'No stock on hand. Receive items with a purchase or an opening adjustment.'
            }
            dense
          />
          {withStock.length > 0 && (
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
              <span style={{ font: 'var(--type-label)', color: 'var(--text-secondary)' }}>Total inventory value</span>
              <Amount value={totalValue} />
            </div>
          )}
        </Card>
        {selected && <StockCard clientId={client.id} row={selected} />}
        {withStock.length > 0 && !selected && (
          <p style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>
            Click an item to see its stock card — every receipt, sale, and adjustment with running balances.
          </p>
        )}
      </PageBody>
    </>
  )
}

function StockCard({ clientId, row }: { clientId: string; row: InventoryValuationRow }) {
  const year = new Date().getFullYear()
  const [from, setFrom] = useState(`${year}-01-01`)
  const [to, setTo] = useState(localToday())
  const { data: moves, isPending } = useStockCard(clientId, row.item_id, from, to)

  const columns: Column<StockCardRow>[] = [
    { key: 'move_date', header: 'Date', width: 110, render: (m) => <span style={{ font: '400 13px/1 var(--font-mono)' }}>{m.move_date}</span> },
    { key: 'ref', header: 'Ref', width: 90, render: (m) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{m.ref}</span> },
    { key: 'memo', header: 'Memo' },
    { key: 'qty_in', header: 'In', width: 80, align: 'right', render: (m) => (Number(m.qty_in) !== 0 ? Number(m.qty_in) : '—') },
    { key: 'qty_out', header: 'Out', width: 80, align: 'right', render: (m) => (Number(m.qty_out) !== 0 ? Number(m.qty_out) : '—') },
    { key: 'cost', header: 'Cost', width: 110, align: 'right', render: (m) => <Amount value={m.cost} dashZero /> },
    { key: 'running_qty', header: 'Bal qty', width: 90, align: 'right', render: (m) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{Number(m.running_qty)}</span> },
    { key: 'running_value', header: 'Bal value', width: 120, align: 'right', render: (m) => <Amount value={m.running_value} /> },
  ]

  return (
    <Card title={`Stock card — ${row.sku} ${row.name}`} padding="none">
      <div style={{ display: 'flex', gap: 10, alignItems: 'flex-end', padding: '14px 20px 0' }}>
        <Input label="From" type="date" fieldSize="sm" value={from} onChange={(e) => setFrom(e.target.value)} />
        <Input label="To" type="date" fieldSize="sm" value={to} onChange={(e) => setTo(e.target.value)} />
      </div>
      <DataTable
        rows={moves ?? []}
        columns={columns}
        rowKey={(m) => `${m.move_date}:${m.ref}:${m.running_qty}:${m.running_value}`}
        emptyMessage={isPending ? 'Computing…' : 'No movements in this range.'}
        dense
      />
    </Card>
  )
}
