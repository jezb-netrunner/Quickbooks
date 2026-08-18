import { useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Button, Dialog, Select } from '@/design-system'
import { FormError } from '@/auth/AuthCard'
import type { Client, IncomeTaxOption, TaxRegime, TaxpayerKind } from '@/lib/database.types'
import { ClientForm } from './ClientForm'
import { useCreateClientWithSetup } from './hooks'
import type { ClientForm as ClientFormValues } from './api'

// Guided onboarding (T-01): a client cannot exist half-configured. Step 1 is
// the company record; step 2 is the tax questionnaire; "Create client" runs
// both the insert and the one-call setup_client seed (COA + tax codes +
// compliance). The database refuses to issue documents for a client with no
// tax profile, so this wizard is the paved road, not a suggestion.
export function ClientSetupWizard({
  firmId,
  onClose,
  onDone,
}: {
  firmId: string
  onClose: () => void
  onDone: (client: Client) => void
}) {
  const create = useCreateClientWithSetup(firmId)
  const [step, setStep] = useState<1 | 2>(1)
  const [draft, setDraft] = useState<ClientFormValues | null>(null)
  const [regime, setRegime] = useState<TaxRegime>('vat')
  const [kind, setKind] = useState<TaxpayerKind>('individual')
  const [option, setOption] = useState<IncomeTaxOption>('graduated')
  const [error, setError] = useState<string | null>(null)

  // Escape / scrim-click must not dismiss the dialog while create+setup runs:
  // the mutation would finish unobserved (TanStack drops mutate-level
  // callbacks after unmount), the failure rescue message would never show,
  // and a retry would create a second client row.
  function guardedClose() {
    if (!create.isPending) onClose()
  }

  return (
    <Dialog
      open
      onClose={guardedClose}
      width={520}
      title={step === 1 ? 'Add a client company' : `Tax profile — ${draft?.name ?? ''}`}
      description={
        step === 1
          ? 'Step 1 of 2 — the company record. Reporting basis and fiscal year end drive period generation.'
          : 'Step 2 of 2 — drives VAT and withholding automation, the working papers, and the filing calendar. Every seeded rate stays editable.'
      }
    >
      {step === 1 ? (
        <ClientForm
          initial={draft ?? undefined}
          submitLabel="Continue to tax profile"
          busy={false}
          error={null}
          onCancel={guardedClose}
          onSubmit={(values) => {
            setDraft(values)
            setStep(2)
          }}
        />
      ) : (
        <div style={{ display: 'grid', gap: 14 }}>
          <FormError message={error} />
          <Select
            label="Registration"
            options={[
              { value: 'vat', label: 'VAT-registered (12% VAT applies)' },
              { value: 'non_vat', label: 'Non-VAT (percentage tax, no VAT codes)' },
            ]}
            value={regime}
            onChange={(e) => {
              const next = e.target.value as TaxRegime
              setRegime(next)
              // The 8% option is only for non-VAT individuals (TRAIN): flipping
              // to VAT while 8% is selected falls back to the graduated table.
              if (next === 'vat' && option === 'eight_percent') setOption('graduated')
            }}
            disabled={create.isPending}
          />
          <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)', gap: 12 }}>
            <Select
              label="Taxpayer"
              options={[
                { value: 'individual', label: 'Individual (1701)' },
                { value: 'corporate', label: 'Corporate (1702)' },
              ]}
              value={kind}
              onChange={(e) => {
                const next = e.target.value as TaxpayerKind
                setKind(next)
                setOption(next === 'corporate' ? 'rcit' : 'graduated')
              }}
              disabled={create.isPending}
            />
            <Select
              label="Income tax option"
              options={
                kind === 'corporate'
                  ? [{ value: 'rcit', label: 'Regular corporate (RCIT)' }]
                  : [
                      { value: 'graduated', label: 'Graduated table' },
                      // Only non-VAT individuals may elect the 8% (TRAIN).
                      ...(regime === 'non_vat'
                        ? [{ value: 'eight_percent', label: '8% of gross option' }]
                        : []),
                    ]
              }
              value={option}
              onChange={(e) => setOption(e.target.value as IncomeTaxOption)}
              disabled={create.isPending}
            />
          </div>
          <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-secondary)' }}>
            Creating the client seeds its chart of accounts, tax codes with provisional
            rates, the graduated tax table, and its filing deadline rules — all editable,
            all effective-dated. Documents cannot be issued until this setup exists.
          </p>
          <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, paddingTop: 4 }}>
            <Button variant="ghost" disabled={create.isPending} onClick={() => setStep(1)}>
              Back
            </Button>
            <Button
              disabled={create.isPending}
              onClick={() => {
                if (!draft) return
                setError(null)
                create.mutate(
                  { form: draft, setup: { regime, taxpayer_kind: kind, income_tax_option: option } },
                  {
                    onSuccess: (client) => onDone(client),
                    onError: (err) => setError(messageOf(err, 'Could not create the client.')),
                  },
                )
              }}
            >
              {create.isPending ? 'Setting up' : 'Create client'}
            </Button>
          </div>
        </div>
      )}
    </Dialog>
  )
}
