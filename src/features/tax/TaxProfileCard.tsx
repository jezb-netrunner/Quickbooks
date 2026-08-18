import { useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Button, Card, Select } from '@/design-system'
import { FormError } from '@/auth/AuthCard'
import type { IncomeTaxOption, TaxRegime, TaxpayerKind } from '@/lib/database.types'
import { useSetupClient, useTaxProfile } from './hooks'

// Idempotent tax setup per client — the same one-call setup_client RPC the
// onboarding wizard runs: regime + taxpayer shape, starter codes, rates,
// brackets, filing rules, and reconciliation of rules/VAT codes after a
// regime or option change. All seeded values are provisional — the CPA
// verifies them; the engine only ever reads the effective-dated tables.
export function TaxProfileCard({ clientId }: { clientId: string }) {
  const { data: profile, isPending } = useTaxProfile(clientId)
  const setup = useSetupClient(clientId)
  // null = untouched; stored values (or defaults) show until the user picks.
  const [regime, setRegime] = useState<TaxRegime | null>(null)
  const [kind, setKind] = useState<TaxpayerKind | null>(null)
  const [option, setOption] = useState<IncomeTaxOption | null>(null)
  const [error, setError] = useState<string | null>(null)
  const busy = setup.isPending

  const effectiveRegime: TaxRegime = regime ?? profile?.regime ?? 'vat'
  const effectiveKind: TaxpayerKind = kind ?? profile?.taxpayer_kind ?? 'individual'
  const effectiveOption: IncomeTaxOption =
    option ?? profile?.income_tax_option ?? (effectiveKind === 'corporate' ? 'rcit' : 'graduated')

  function runSetup() {
    setError(null)
    setup.mutate(
      { regime: effectiveRegime, taxpayer_kind: effectiveKind, income_tax_option: effectiveOption },
      {
        onSuccess: () => {
          setRegime(null)
          setKind(null)
          setOption(null)
        },
        onError: (err) => setError(messageOf(err, 'Could not run tax setup.')),
      },
    )
  }

  return (
    <Card
      title="Tax profile"
      subtitle="Drives VAT/withholding automation, the working papers, and the filing calendar"
    >
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        <FormError message={error} />
        {isPending ? (
          <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-muted)' }}>Loading…</p>
        ) : (
          <>
            <Select
              label="Registration"
              options={[
                { value: 'vat', label: 'VAT-registered (12% VAT applies)' },
                { value: 'non_vat', label: 'Non-VAT (percentage tax, no VAT codes)' },
              ]}
              value={effectiveRegime}
              onChange={(e) => setRegime(e.target.value as TaxRegime)}
              disabled={busy}
            />
            <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)', gap: 12 }}>
              <Select
                label="Taxpayer"
                options={[
                  { value: 'individual', label: 'Individual (1701)' },
                  { value: 'corporate', label: 'Corporate (1702)' },
                ]}
                value={effectiveKind}
                onChange={(e) => {
                  const next = e.target.value as TaxpayerKind
                  setKind(next)
                  // Pin a valid option for the kind: a stored 8% profile must
                  // not ride along into a corporate submission (RPC rejects it).
                  setOption(next === 'corporate' ? 'rcit' : 'graduated')
                }}
                disabled={busy}
              />
              <Select
                label="Income tax option"
                options={
                  effectiveKind === 'corporate'
                    ? [{ value: 'rcit', label: 'Regular corporate (RCIT)' }]
                    : [
                        { value: 'graduated', label: 'Graduated table' },
                        { value: 'eight_percent', label: '8% of gross option' },
                      ]
                }
                value={effectiveOption}
                onChange={(e) => setOption(e.target.value as IncomeTaxOption)}
                disabled={busy}
              />
            </div>
            <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-secondary)' }}>
              {profile
                ? 'Setup is idempotent: it keeps existing codes and rates, adds missing ones, toggles VAT codes with the registration, and refreshes the filing rules. Verify every seeded rate — the app never hardcodes one.'
                : 'Seeds tax codes, provisional rates, the graduated tax table, and this client’s filing deadline rules — all editable, all effective-dated.'}
            </p>
            <div>
              <Button variant={profile ? 'secondary' : 'accent'} disabled={busy} onClick={() => void runSetup()}>
                {busy ? 'Working' : profile ? 'Re-run tax & compliance setup' : 'Set up tax & compliance'}
              </Button>
            </div>
          </>
        )}
      </div>
    </Card>
  )
}
