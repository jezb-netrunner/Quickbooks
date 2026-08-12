import { useState } from 'react'
import { Button } from './Button'
import { exportCsv, exportPdf, exportXlsx, type ReportExport } from '@/lib/exports'

// The export affordance every report shares: CSV, Excel, PDF.
export function ExportMenu({ report, disabled }: { report: () => ReportExport; disabled?: boolean }) {
  const [busy, setBusy] = useState<'xlsx' | 'pdf' | null>(null)

  async function run(kind: 'csv' | 'xlsx' | 'pdf') {
    const data = report()
    if (kind === 'csv') {
      exportCsv(data)
      return
    }
    setBusy(kind)
    try {
      if (kind === 'xlsx') await exportXlsx(data)
      else await exportPdf(data)
    } finally {
      setBusy(null)
    }
  }

  return (
    <span style={{ display: 'inline-flex', gap: 6 }}>
      <Button size="sm" variant="secondary" iconLeft="download" disabled={disabled || busy !== null}
        onClick={() => { void run('pdf') }}>
        {busy === 'pdf' ? 'Preparing' : 'PDF'}
      </Button>
      <Button size="sm" variant="secondary" iconLeft="download" disabled={disabled || busy !== null}
        onClick={() => { void run('xlsx') }}>
        {busy === 'xlsx' ? 'Preparing' : 'Excel'}
      </Button>
      <Button size="sm" variant="ghost" iconLeft="download" disabled={disabled || busy !== null}
        onClick={() => { void run('csv') }}>
        CSV
      </Button>
    </span>
  )
}
