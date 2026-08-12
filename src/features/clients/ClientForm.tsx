import { useState, type FormEvent } from 'react'
import { Button, Input, Select } from '@/design-system'
import { FormError } from '@/auth/AuthCard'
import type { ClientForm as ClientFormValues } from './api'
import type { ReportingBasis } from '@/lib/database.types'

const MONTH_OPTIONS = [
  { value: '1', label: 'January' },
  { value: '2', label: 'February' },
  { value: '3', label: 'March' },
  { value: '4', label: 'April' },
  { value: '5', label: 'May' },
  { value: '6', label: 'June' },
  { value: '7', label: 'July' },
  { value: '8', label: 'August' },
  { value: '9', label: 'September' },
  { value: '10', label: 'October' },
  { value: '11', label: 'November' },
  { value: '12', label: 'December' },
]

export interface ClientFormProps {
  initial?: Partial<ClientFormValues>
  submitLabel: string
  busy: boolean
  error: string | null
  onSubmit: (values: ClientFormValues) => void
  onCancel?: () => void
}

// Shared by "Add client" and client settings. reporting_basis and fiscal year
// end feed Phase 2 period generation, so they are captured at creation.
export function ClientForm({ initial, submitLabel, busy, error, onSubmit, onCancel }: ClientFormProps) {
  const [name, setName] = useState(initial?.name ?? '')
  const [code, setCode] = useState(initial?.code ?? '')
  const [tin, setTin] = useState(initial?.tin ?? '')
  const [basis, setBasis] = useState<ReportingBasis>(initial?.reporting_basis ?? 'accrual')
  const [fyEnd, setFyEnd] = useState(String(initial?.fiscal_year_end_month ?? 12))

  function handleSubmit(e: FormEvent) {
    e.preventDefault()
    onSubmit({
      name: name.trim(),
      code: code.trim() || null,
      tin: tin.trim() || null,
      reporting_basis: basis,
      fiscal_year_end_month: Number(fyEnd),
    })
  }

  return (
    <form onSubmit={handleSubmit} style={{ display: 'grid', gap: 14 }}>
      <FormError message={error} />
      <Input label="Company name" required maxLength={200} value={name} onChange={(e) => setName(e.target.value)} />
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        <Input
          label="Client code"
          hint="Short label for BIR books and working papers"
          maxLength={20}
          value={code}
          onChange={(e) => setCode(e.target.value)}
        />
        <Input label="TIN" placeholder="000-000-000-000" value={tin} onChange={(e) => setTin(e.target.value)} />
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        <Select
          label="Reporting basis"
          options={[
            { value: 'accrual', label: 'Accrual' },
            { value: 'cash', label: 'Cash' },
          ]}
          value={basis}
          onChange={(e) => setBasis(e.target.value as ReportingBasis)}
        />
        <Select
          label="Fiscal year ends"
          options={MONTH_OPTIONS}
          value={fyEnd}
          onChange={(e) => setFyEnd(e.target.value)}
        />
      </div>
      <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, paddingTop: 4 }}>
        {onCancel && (
          <Button variant="ghost" onClick={onCancel}>
            Cancel
          </Button>
        )}
        <Button type="submit" disabled={busy}>
          {busy ? 'Saving' : submitLabel}
        </Button>
      </div>
    </form>
  )
}
