import { useMemo, useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Amount, Button, Card, DataTable, Dialog, ExportMenu, Input, Select, Tabs, Toast, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { FormError } from '@/auth/AuthCard'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { useContacts } from '@/features/contacts/hooks'
import { localToday } from '@/lib/dates'
import type { WhtByContactRow, WhtCertificate } from '@/lib/database.types'
import type { ReportExport } from '@/lib/exports'
import {
  quarterRange,
  useCertificates,
  useCreateCertificate,
  useDeleteCertificate,
  useEwtSummary,
  useWhtRegister,
} from './hooks'

export function WithholdingPage() {
  const client = useActiveClient()
  const year = new Date().getFullYear()
  const [tab, setTab] = useState('issue')
  const [q, setQ] = useState('1')
  const range = quarterRange(year, Number(q) as 1 | 2 | 3 | 4)

  const { data: toIssue } = useWhtRegister('issued', client.id, range.from, range.to)
  const { data: received } = useWhtRegister('received', client.id, range.from, range.to)
  const { data: byAtc } = useEwtSummary(client.id, range.from, range.to)
  const [toast, setToast] = useState<string | null>(null)

  const registerColumns: Column<WhtByContactRow>[] = [
    { key: 'contact_name', header: tab === 'issue' ? 'Vendor' : 'Customer' },
    { key: 'tin', header: 'TIN', width: 140, render: (r) => <span style={{ font: '400 13px/1 var(--font-mono)', color: 'var(--text-secondary)' }}>{r.tin || '—'}</span> },
    { key: 'atc', header: 'ATC', width: 90, render: (r) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{r.atc || '—'}</span> },
    { key: 'base', header: 'Income payment', width: 140, align: 'right', render: (r) => <Amount value={r.base} /> },
    { key: 'tax', header: 'Tax withheld', width: 130, align: 'right', render: (r) => <Amount value={r.tax} /> },
  ]

  const activeRows = tab === 'issue' ? (toIssue ?? []) : tab === 'received' ? (received ?? []) : []
  const exportReport = (): ReportExport => ({
    filename: `2307-${tab}_${client.code ?? client.name}_Q${q}-${year}`,
    title: tab === 'issue' ? '2307s to issue (EWT by vendor)' : '2307s received (CWT by customer)',
    subtitle: [client.name, `Q${q} ${year} (${range.from} to ${range.to})`],
    header: [tab === 'issue' ? 'Vendor' : 'Customer', 'TIN', 'ATC', 'Income payment', 'Tax withheld'],
    rows: activeRows.map((r) => [r.contact_name, r.tin, r.atc, r.base, r.tax]),
    numericColumns: [3, 4],
  })

  return (
    <>
      <TopBar
        title="Withholding (2307)"
        subtitle="Certificates to issue to vendors, certificates received from customers, and the paper-trail log"
        actions={tab !== 'log' ? <ExportMenu disabled={activeRows.length === 0} report={exportReport} /> : undefined}
      />
      <PageBody>
        <div style={{ display: 'flex', gap: 16, alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap' }}>
          <Tabs
            value={tab}
            onChange={setTab}
            items={[
              { value: 'issue', label: 'To issue (EWT)' },
              { value: 'received', label: 'Received (CWT)' },
              { value: 'log', label: 'Certificate log' },
            ]}
          />
          {tab !== 'log' && (
            <div style={{ width: 140 }}>
              <Select
                label="Quarter"
                fieldSize="sm"
                options={[1, 2, 3, 4].map((n) => ({ value: String(n), label: `Q${n} ${year}` }))}
                value={q}
                onChange={(e) => setQ(e.target.value)}
              />
            </div>
          )}
        </div>

        {tab === 'issue' && (
          <>
            <Card title="EWT withheld from vendor payments" subtitle="Issue a 2307 per vendor per quarter; the same figures feed 1601-EQ and 1604-E" padding="none">
              <DataTable
                rows={toIssue ?? []}
                columns={registerColumns}
                rowKey={(r) => `${r.contact_id}:${r.atc}`}
                emptyMessage="No EWT withheld this quarter."
                dense
              />
            </Card>
            <Card title="By ATC (0619-E / 1601-EQ figures)" padding="none">
              <DataTable
                rows={byAtc ?? []}
                columns={[
                  { key: 'atc', header: 'ATC', width: 90, render: (r) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{r.atc || '—'}</span> },
                  { key: 'label', header: 'Nature of payment' },
                  { key: 'base', header: 'Tax base', width: 140, align: 'right', render: (r) => <Amount value={r.base} /> },
                  { key: 'tax', header: 'Tax withheld', width: 130, align: 'right', render: (r) => <Amount value={r.tax} /> },
                ]}
                rowKey={(r) => r.atc + r.label}
                emptyMessage="No EWT withheld this quarter."
                dense
              />
            </Card>
          </>
        )}

        {tab === 'received' && (
          <Card title="CWT customers withheld from collections" subtitle="Chase the physical 2307s — they are the support for the income tax credit" padding="none">
            <DataTable
              rows={received ?? []}
              columns={registerColumns}
              rowKey={(r) => `${r.contact_id}:${r.atc}`}
              emptyMessage="No customer withholding this quarter."
              dense
            />
          </Card>
        )}

        {tab === 'log' && <CertificateLog clientId={client.id} onToast={setToast} />}
        {toast && <Toast title={toast} onDismiss={() => setToast(null)} />}
      </PageBody>
    </>
  )
}

function CertificateLog({ clientId, onToast }: { clientId: string; onToast: (m: string) => void }) {
  const { data: certificates, isPending } = useCertificates(clientId)
  const { data: contacts } = useContacts(clientId)
  const remove = useDeleteCertificate(clientId)
  const [adding, setAdding] = useState(false)

  const contactName = useMemo(() => new Map((contacts ?? []).map((c) => [c.id, c.name])), [contacts])

  const columns: Column<WhtCertificate>[] = [
    { key: 'cert_date', header: 'Date', width: 110, render: (c) => <span style={{ font: '400 13px/1 var(--font-mono)' }}>{c.cert_date}</span> },
    { key: 'direction', header: 'Direction', width: 90, render: (c) => (c.direction === 'received' ? 'Received' : 'Issued') },
    { key: 'contact', header: 'Counterparty', render: (c) => contactName.get(c.contact_id) ?? '—' },
    { key: 'cert_no', header: 'Cert no.', width: 110, render: (c) => <span style={{ font: '400 13px/1 var(--font-mono)' }}>{c.cert_no || '—'}</span> },
    { key: 'period', header: 'Period', width: 190, render: (c) => <span style={{ font: '400 12.5px/1 var(--font-mono)' }}>{c.period_from} – {c.period_to}</span> },
    { key: 'atc', header: 'ATC', width: 80, render: (c) => c.atc || '—' },
    { key: 'income_payment', header: 'Payment', width: 120, align: 'right', render: (c) => <Amount value={c.income_payment} /> },
    { key: 'tax_withheld', header: 'Withheld', width: 110, align: 'right', render: (c) => <Amount value={c.tax_withheld} /> },
  ]

  return (
    <Card
      title="Certificate log"
      subtitle="The physical 2307s on file — reconcile against the registers above"
      action={
        <Button size="sm" iconLeft="plus" onClick={() => setAdding(true)}>
          Log certificate
        </Button>
      }
      padding="none"
    >
      <DataTable
        rows={certificates ?? []}
        columns={columns}
        rowKey={(c) => c.id}
        onRowClick={(c) => {
          if (window.confirm('Remove this certificate from the log?')) {
            remove.mutate(c.id, { onSuccess: () => onToast('Certificate removed') })
          }
        }}
        emptyMessage={isPending ? 'Loading…' : 'No certificates logged yet.'}
        dense
      />
      {adding && (
        <CertificateDialog
          clientId={clientId}
          onClose={() => setAdding(false)}
          onDone={(m) => { onToast(m); setAdding(false) }}
        />
      )}
    </Card>
  )
}

function CertificateDialog({
  clientId,
  onClose,
  onDone,
}: {
  clientId: string
  onClose: () => void
  onDone: (msg: string) => void
}) {
  const { data: contacts } = useContacts(clientId)
  const create = useCreateCertificate(clientId)
  const [direction, setDirection] = useState<'received' | 'issued'>('received')
  const [contactId, setContactId] = useState('')
  const [certNo, setCertNo] = useState('')
  const [certDate, setCertDate] = useState(localToday())
  const [periodFrom, setPeriodFrom] = useState('')
  const [periodTo, setPeriodTo] = useState('')
  const [atc, setAtc] = useState('')
  const [payment, setPayment] = useState('')
  const [withheld, setWithheld] = useState('')
  const [error, setError] = useState<string | null>(null)

  function submit() {
    setError(null)
    if (!contactId || !periodFrom || !periodTo || !(Number(payment) >= 0) || !(Number(withheld) >= 0)) {
      setError('Counterparty, period, payment, and withheld amounts are required.')
      return
    }
    create.mutate(
      {
        direction,
        contact_id: contactId,
        cert_no: certNo.trim(),
        cert_date: certDate,
        period_from: periodFrom,
        period_to: periodTo,
        atc: atc.trim(),
        income_payment: Number(payment),
        tax_withheld: Number(withheld),
        notes: '',
      },
      {
        onSuccess: () => onDone('Certificate logged'),
        onError: (err) => setError(messageOf(err, 'Could not log the certificate.')),
      },
    )
  }

  return (
    <Dialog
      open
      onClose={onClose}
      width={520}
      title="Log a 2307 certificate"
      description="Received: a customer's certificate supporting your income tax credit. Issued: your certificate to a vendor."
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="accent" disabled={create.isPending} onClick={submit}>
            {create.isPending ? 'Working' : 'Log certificate'}
          </Button>
        </>
      }
    >
      <div style={{ display: 'grid', gap: 14 }}>
        <FormError message={error} />
        <div style={{ display: 'grid', gridTemplateColumns: '150px minmax(0, 1fr)', gap: 12 }}>
          <Select
            label="Direction"
            options={[
              { value: 'received', label: 'Received' },
              { value: 'issued', label: 'Issued' },
            ]}
            value={direction}
            onChange={(e) => setDirection(e.target.value as 'received' | 'issued')}
          />
          <Select
            label="Counterparty"
            placeholder="Choose a contact"
            options={(contacts ?? []).filter((c) => !c.archived_at).map((c) => ({ value: c.id, label: c.name }))}
            value={contactId}
            onChange={(e) => setContactId(e.target.value)}
          />
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) 150px', gap: 12 }}>
          <Input label="Certificate no." value={certNo} onChange={(e) => setCertNo(e.target.value)} />
          <Input label="Certificate date" type="date" value={certDate} onChange={(e) => setCertDate(e.target.value)} />
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr) 110px', gap: 12 }}>
          <Input label="Period from" type="date" value={periodFrom} onChange={(e) => setPeriodFrom(e.target.value)} />
          <Input label="Period to" type="date" value={periodTo} onChange={(e) => setPeriodTo(e.target.value)} />
          <Input label="ATC" placeholder="WC160" value={atc} onChange={(e) => setAtc(e.target.value)} />
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)', gap: 12 }}>
          <Input label="Income payment" type="number" min="0" step="0.01" placeholder="0.00" value={payment} onChange={(e) => setPayment(e.target.value)} />
          <Input label="Tax withheld" type="number" min="0" step="0.01" placeholder="0.00" value={withheld} onChange={(e) => setWithheld(e.target.value)} />
        </div>
      </div>
    </Dialog>
  )
}
