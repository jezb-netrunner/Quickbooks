import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { messageOf } from '@/lib/errors'
import { Button, Card, Select } from '@/design-system'
import { FormError } from '@/auth/AuthCard'
import { supabase } from '@/lib/supabase'
import { keys } from '@/lib/queryKeys'
import type { IncomeTaxOption, TaxRegime, TaxpayerKind } from '@/lib/database.types'
import { seedCompliance } from '@/features/compliance/api'
import { useSeedTaxCodes, useTaxProfile } from './hooks'

// One-time (idempotent) tax setup per client: regime + taxpayer shape, then
// seed the starter codes, rates, brackets, and filing deadline rules. All
// seeded values are provisional — the CPA verifies them; the engine and the
// working papers only ever read the effective-dated configuration tables.
export function TaxProfileCard({ clientId }: { clientId: string }) {
  const qc = useQueryClient()
  const { data: profile, isPending } = useTaxProfile(clientId)
  const seed = useSeedTaxCodes(clientId)
  // null = untouched; stored values (or defaults) show until the user picks.
  const [regime, setRegime] = useState<TaxRegime | null>(null)
  const [kind, setKind] = useState<TaxpayerKind | null>(null)
  const [option, setOption] = useState<IncomeTaxOption | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const effectiveRegime: TaxRegime = regime ?? profile?.regime ?? 'vat'
  const effectiveKind: TaxpayerKind = kind ?? profile?.taxpayer_kind ?? 'individual'
  const effectiveOption: IncomeTaxOption =
    option ?? profile?.income_tax_option ?? (effectiveKind === 'corporate' ? 'rcit' : 'graduated')

  async function runSetup() {
    setError(null)
    setBusy(true)
    try {
      await new Promise<void>((resolve, reject) =>
        seed.mutate(effectiveRegime, { onSuccess: () => resolve(), onError: reject }),
      )
      const { error: updateErr } = await supabase
        .from('client_tax_profiles')
        .update({ taxpayer_kind: effectiveKind, income_tax_option: effectiveOption })
        .eq('client_id', clientId)
      if (updateErr) throw updateErr
      await seedCompliance(clientId)
      void qc.invalidateQueries({ queryKey: keys.taxProfile(clientId) })
      void qc.invalidateQueries({ queryKey: ['calendar', clientId] })
      setRegime(null)
      setKind(null)
      setOption(null)
    } catch (err) {
      setError(messageOf(err, 'Could not run tax setup.'))
    } finally {
      setBusy(false)
    }
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
                  setKind(e.target.value as TaxpayerKind)
                  setOption(null)
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
