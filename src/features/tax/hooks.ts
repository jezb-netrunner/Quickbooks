import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys } from '@/lib/queryKeys'
import type { TaxRegime } from '@/lib/database.types'
import { setupClient, type ClientTaxSetup } from '@/features/clients/api'
import { addTaxRate, fetchTaxCodes, fetchTaxProfile, seedTaxCodes, updateTaxCode } from './api'

export function useTaxProfile(clientId: string) {
  return useQuery({
    queryKey: keys.taxProfile(clientId),
    queryFn: () => fetchTaxProfile(clientId),
  })
}

export function useTaxCodes(clientId: string) {
  return useQuery({
    queryKey: keys.taxCodes(clientId),
    queryFn: () => fetchTaxCodes(clientId),
  })
}

function useInvalidateTax(clientId: string) {
  const qc = useQueryClient()
  return () => {
    void qc.invalidateQueries({ queryKey: keys.taxProfile(clientId) })
    void qc.invalidateQueries({ queryKey: keys.taxCodes(clientId) })
  }
}

export function useSeedTaxCodes(clientId: string) {
  const invalidate = useInvalidateTax(clientId)
  return useMutation({
    mutationFn: (regime: TaxRegime) => seedTaxCodes(clientId, regime),
    onSuccess: invalidate,
  })
}

// The one-call setup (same RPC the onboarding wizard uses): seeds everything,
// stamps the taxpayer shape, and reconciles rules/codes after a regime or
// option change. Invalidates everything the setup touches.
export function useSetupClient(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (setup: ClientTaxSetup) => setupClient(clientId, setup),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: keys.taxProfile(clientId) })
      void qc.invalidateQueries({ queryKey: keys.taxCodes(clientId) })
      void qc.invalidateQueries({ queryKey: ['calendar', clientId] })
    },
  })
}

export function useUpdateTaxCode(clientId: string) {
  const invalidate = useInvalidateTax(clientId)
  return useMutation({
    mutationFn: (args: { id: string; patch: { name?: string; atc?: string; active?: boolean } }) =>
      updateTaxCode(args.id, args.patch),
    onSuccess: invalidate,
  })
}

export function useAddTaxRate(clientId: string) {
  const invalidate = useInvalidateTax(clientId)
  return useMutation({
    mutationFn: (args: { taxCodeId: string; effectiveFrom: string; rate: number }) =>
      addTaxRate(clientId, args.taxCodeId, args.effectiveFrom, args.rate),
    onSuccess: invalidate,
  })
}
