import { useState } from 'react'
import { messageOf } from '@/lib/errors'
import { Button, Card, Select } from '@/design-system'
import { FormError } from '@/auth/AuthCard'
import type { TaxRegime } from '@/lib/database.types'
import { useSeedTaxCodes, useTaxProfile } from './hooks'

// One-time (idempotent) tax setup per client: pick the regime and seed the
// starter codes. Seeded rates are provisional — the CPA verifies them on the
// tax codes screen; the engine only reads the effective-dated rate table.
export function TaxProfileCard({ clientId }: { clientId: string }) {
  const { data: profile, isPending } = useTaxProfile(clientId)
  const seed = useSeedTaxCodes(clientId)
  const [regime, setRegime] = useState<TaxRegime>('vat')
  const [error, setError] = useState<string | null>(null)

  return (
    <Card
      title="Tax profile"
      subtitle="Drives VAT and withholding automation on documents"
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
              value={profile?.regime ?? regime}
              onChange={(e) => setRegime(e.target.value as TaxRegime)}
              disabled={seed.isPending}
            />
            <p style={{ font: 'var(--type-body-sm)', color: 'var(--text-secondary)' }}>
              {profile
                ? 'Setup is done. Re-running keeps existing codes and only adds missing ones. Verify rates on the Tax codes screen — the engine reads rates from there, never from code.'
                : 'Seeds the starter VAT and withholding codes for this client. The rates are provisional defaults for you to verify.'}
            </p>
            <div>
              <Button
                variant={profile ? 'secondary' : 'accent'}
                disabled={seed.isPending}
                onClick={() => {
                  setError(null)
                  seed.mutate((profile?.regime ?? regime) as TaxRegime, {
                    onError: (err) => setError(messageOf(err, 'Could not set up tax codes.')),
                  })
                }}
              >
                {seed.isPending ? 'Working' : profile ? 'Re-run setup' : 'Set up tax codes'}
              </Button>
            </div>
          </>
        )}
      </div>
    </Card>
  )
}
