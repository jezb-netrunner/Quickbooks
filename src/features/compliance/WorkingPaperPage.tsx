import { useState } from 'react'
import { Amount, Card, DataTable, ExportMenu, Input, Select, type Column } from '@/design-system'
import { TopBar, PageBody } from '@/shell/AppShell'
import { useActiveClient } from '@/features/clients/routes/ClientLayout'
import { useTaxProfile } from '@/features/tax/hooks'
import { localToday } from '@/lib/dates'
import type { WorkingPaperLine } from '@/lib/database.types'
import type { ReportExport } from '@/lib/exports'
import type { WorkingPaperForm } from './api'
import { quarterRange, useWorkingPaper } from './hooks'

const FORM_META: Record<WorkingPaperForm, { title: string; formNo: string; subtitle: string }> = {
  wp_vat: {
    title: 'VAT working paper',
    formNo: '2550Q',
    subtitle: 'Quarterly VAT figures assembled from the frozen tax snapshots — review, then transcribe to the return',
  },
  wp_percentage_tax: {
    title: 'Percentage tax working paper',
    formNo: '2551Q',
    subtitle: 'Gross receipts times the configured rate — for non-VAT registrants',
  },
  wp_income_tax: {
    title: 'Income tax working paper',
    formNo: '1701Q / 1701A / 1702Q / 1702-RT',
    subtitle: 'From the posted P&L under the profile’s tax option, net of 2307 credits',
  },
}

export function WorkingPaperPage({ form }: { form: WorkingPaperForm }) {
  const client = useActiveClient()
  const meta = FORM_META[form]
  const { data: profile } = useTaxProfile(client.id)
  const year = new Date().getFullYear()
  const [preset, setPreset] = useState('q1')
  const [from, setFrom] = useState(quarterRange(year, 1).from)
  const [to, setTo] = useState(quarterRange(year, 1).to)

  const { data: lines, isPending, isError } = useWorkingPaper(form, client.id, from, to)

  function applyPreset(value: string) {
    setPreset(value)
    if (value === 'year') {
      setFrom(`${year}-01-01`)
      setTo(localToday())
    } else if (value.startsWith('q')) {
      const r = quarterRange(year, Number(value.slice(1)) as 1 | 2 | 3 | 4)
      setFrom(r.from)
      setTo(r.to)
    }
  }

  const columns: Column<WorkingPaperLine>[] = [
    { key: 'line_no', header: '#', width: 40, render: (l) => <span style={{ font: '500 13px/1 var(--font-mono)' }}>{l.line_no}</span> },
    { key: 'label', header: 'Line' },
    { key: 'amount', header: 'Amount', width: 150, align: 'right', render: (l) => <Amount value={l.amount} /> },
    { key: 'note', header: 'Source / note', render: (l) => <span style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>{l.note}</span> },
  ]

  const regimeWarning =
    form === 'wp_vat' && profile && profile.regime !== 'vat'
      ? 'This client is non-VAT — the 2551Q percentage tax working paper is the one to file.'
      : form === 'wp_percentage_tax' && profile && profile.regime === 'vat'
        ? 'This client is VAT-registered — the 2550Q VAT working paper is the one to file.'
        : null

  return (
    <>
      <TopBar
        title={`${meta.title} · ${meta.formNo}`}
        subtitle={meta.subtitle}
        actions={
          <ExportMenu
            disabled={(lines ?? []).length === 0}
            report={(): ReportExport => ({
              filename: `${meta.formNo.split(' ')[0]}_${client.code ?? client.name}_${from}_${to}`,
              title: `${meta.title} (${meta.formNo})`,
              subtitle: [client.name, `${from} to ${to}`, 'Working paper — figures for review, not a filed return'],
              header: ['#', 'Line', 'Amount', 'Source / note'],
              rows: (lines ?? []).map((l) => [l.line_no, l.label, l.amount, l.note]),
              numericColumns: [2],
            })}
          />
        }
      />
      <PageBody>
        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-end', flexWrap: 'wrap' }}>
          <div style={{ width: 170 }}>
            <Select
              label="Period"
              fieldSize="sm"
              options={[
                { value: 'q1', label: `Q1 ${year}` },
                { value: 'q2', label: `Q2 ${year}` },
                { value: 'q3', label: `Q3 ${year}` },
                { value: 'q4', label: `Q4 ${year}` },
                { value: 'year', label: `${year} to date` },
                { value: 'custom', label: 'Custom range' },
              ]}
              value={preset}
              onChange={(e) => applyPreset(e.target.value)}
            />
          </div>
          <Input label="From" type="date" fieldSize="sm" value={from} onChange={(e) => { setPreset('custom'); setFrom(e.target.value) }} />
          <Input label="To" type="date" fieldSize="sm" value={to} onChange={(e) => { setPreset('custom'); setTo(e.target.value) }} />
        </div>
        {regimeWarning && (
          <p style={{ font: 'var(--type-body-sm)', color: 'var(--clay-600)' }}>{regimeWarning}</p>
        )}
        <Card padding="none">
          <DataTable
            rows={lines ?? []}
            columns={columns}
            rowKey={(l) => String(l.line_no)}
            emptyMessage={
              isPending
                ? 'Computing…'
                : isError
                  ? 'Could not assemble this working paper — run tax and compliance setup, then retry.'
                  : 'Nothing in this period.'
            }
            dense
          />
        </Card>
        <p style={{ font: 'var(--type-label)', color: 'var(--text-muted)' }}>
          Rates, brackets, and thresholds come from this client's compliance settings — provisional
          seeds you verify, never values baked into the app. This paper is for review and
          transcription; nothing is filed electronically.
        </p>
      </PageBody>
    </>
  )
}
