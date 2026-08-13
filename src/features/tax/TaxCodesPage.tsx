import { useMemo, useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Badge, Button, Card, DataTable, Dialog, Input, Toast, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { FormError } from '@/auth/AuthCard'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { useAddTaxRate, useTaxCodes, useUpdateTaxCode } from './hooks'
import type { TaxCodeWithRate } from './api'

const KIND_LABEL: Record<string, string> = {
  output_vat: 'Output VAT',
  input_vat: 'Input VAT',
  withholding_sales: 'CWT (customer withholds)',
  withholding_purchases: 'EWT (we withhold)',
}

function pct(rate: number | null): string {
  if (rate === null) return '—'
  const p = rate * 100
  return `${p % 1 === 0 ? p.toFixed(0) : p.toFixed(2)}%`
}

export function TaxCodesPage() {
  const client = useActiveClient()
  const { data: codes, isPending } = useTaxCodes(client.id)
  const [editing, setEditing] = useState<TaxCodeWithRate | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  const rows = useMemo(() => codes ?? [], [codes])

  const columns: Column<TaxCodeWithRate>[] = [
    {
      key: 'code',
      header: 'Code',
      width: 110,
      render: (r) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{r.code}</span>,
    },
    { key: 'name', header: 'Name' },
    { key: 'kind', header: 'Kind', width: 180, render: (r) => KIND_LABEL[r.kind] ?? r.kind },
    { key: 'atc', header: 'ATC', width: 80 },
    { key: 'account_code', header: 'Posts to', width: 80 },
    { key: 'rate', header: 'Rate today', width: 100, align: 'right', render: (r) => pct(r.currentRate) },
    {
      key: 'active',
      header: 'Status',
      width: 90,
      render: (r) => <Badge tone={r.active ? 'positive' : 'neutral'}>{r.active ? 'Active' : 'Off'}</Badge>,
    },
  ]

  return (
    <>
      <TopBar
        title="Tax codes"
        subtitle="Effective-dated rates the posting engine reads — nothing is hardcoded. Verify the seeded values."
      />
      <PageBody>
        <Card padding="none">
          <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            onRowClick={(r) => setEditing(r)}
            emptyMessage={
              isPending
                ? 'Loading…'
                : 'No tax codes yet — run tax setup from Client settings.'
            }
            dense
          />
        </Card>
        {editing && (
          <EditTaxCodeDialog
            clientId={client.id}
            code={editing}
            onClose={() => setEditing(null)}
            onDone={(msg) => { setToast(msg); setEditing(null) }}
          />
        )}
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </>
  )
}

function EditTaxCodeDialog({
  clientId,
  code,
  onClose,
  onDone,
}: {
  clientId: string
  code: TaxCodeWithRate
  onClose: () => void
  onDone: (msg: string) => void
}) {
  const update = useUpdateTaxCode(clientId)
  const addRate = useAddTaxRate(clientId)
  const [name, setName] = useState(code.name)
  const [atc, setAtc] = useState(code.atc)
  const [active, setActive] = useState(code.active)
  const [newRate, setNewRate] = useState('')
  const [effectiveFrom, setEffectiveFrom] = useState(new Date().toISOString().slice(0, 10))
  const [error, setError] = useState<string | null>(null)
  const busy = update.isPending || addRate.isPending

  function saveDetails() {
    setError(null)
    update.mutate(
      { id: code.id, patch: { name: name.trim(), atc: atc.trim(), active } },
      {
        onSuccess: () => onDone('Tax code updated'),
        onError: (err) => setError(messageOf(err, 'Could not update the tax code.')),
      },
    )
  }

  function submitRate() {
    const rate = Number(newRate)
    if (!(rate >= 0) || rate > 100) {
      setError('Enter the rate as a percentage between 0 and 100.')
      return
    }
    setError(null)
    addRate.mutate(
      { taxCodeId: code.id, effectiveFrom, rate: rate / 100 },
      {
        onSuccess: () => onDone('New rate scheduled'),
        onError: (err) => setError(messageOf(err, 'Could not add the rate.')),
      },
    )
  }

  return (
    <Dialog
      open
      onClose={onClose}
      width={520}
      title={`${code.code} · ${KIND_LABEL[code.kind] ?? code.kind}`}
      description={`Posts to account ${code.account_code}. Rate changes are new effective-dated rows — history stays, and issued documents keep their frozen amounts.`}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Close
          </Button>
          <Button variant="accent" disabled={busy} onClick={saveDetails}>
            Save details
          </Button>
        </>
      }
    >
      <div style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        <Input label="Name" value={name} disabled={busy} onChange={(e) => setName(e.target.value)} />
        <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)', gap: 12 }}>
          <Input label="ATC" value={atc} disabled={busy} onChange={(e) => setAtc(e.target.value)} hint="BIR alphanumeric tax code" />
          <div style={{ display: 'flex', alignItems: 'end', paddingBottom: 4 }}>
            <label className="fis-check">
              <input type="checkbox" checked={active} disabled={busy} onChange={(e) => setActive(e.target.checked)} />
              <span className="fis-check__label">Active — offered on documents</span>
            </label>
          </div>
        </div>

        <div style={{ display: 'grid', gap: 8 }}>
          <span style={{ font: 'var(--type-overline)', letterSpacing: 'var(--tracking-caps)', textTransform: 'uppercase', color: 'var(--text-muted)' }}>
            Rate history
          </span>
          {code.rates.map((r) => (
            <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', font: 'var(--type-body-sm)' }}>
              <span style={{ color: 'var(--text-secondary)' }}>
                from {r.effective_from === '1900-01-01' ? 'the beginning' : r.effective_from}
              </span>
              <span style={{ font: '500 13px/1.4 var(--font-mono)' }}>{pct(Number(r.rate))}</span>
            </div>
          ))}
          <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) 150px auto', gap: 8, alignItems: 'end' }}>
            <Input
              label="New rate (%)"
              type="number"
              min="0"
              max="100"
              step="0.01"
              placeholder="12"
              value={newRate}
              disabled={busy}
              onChange={(e) => setNewRate(e.target.value)}
            />
            <Input label="Effective from" type="date" value={effectiveFrom} disabled={busy} onChange={(e) => setEffectiveFrom(e.target.value)} />
            <Button variant="secondary" disabled={busy || !newRate} onClick={submitRate}>
              Add rate
            </Button>
          </div>
        </div>
      </div>
    </Dialog>
  )
}
