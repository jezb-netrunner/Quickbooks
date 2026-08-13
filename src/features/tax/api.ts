import { supabase } from '@/lib/supabase'
import type { ClientTaxProfile, TaxCode, TaxCodeRate, TaxRegime } from '@/lib/database.types'
import { localToday } from '@/lib/dates'

export interface TaxCodeWithRate extends TaxCode {
  /** The rate in force today, as a number (0.12 = 12%). Null when none set. */
  currentRate: number | null
  rates: TaxCodeRate[]
}

export async function fetchTaxProfile(clientId: string): Promise<ClientTaxProfile | null> {
  const { data, error } = await supabase
    .from('client_tax_profiles')
    .select('*')
    .eq('client_id', clientId)
    .maybeSingle()
  if (error) throw error
  return data
}

export async function fetchTaxCodes(clientId: string): Promise<TaxCodeWithRate[]> {
  const [codes, rates] = await Promise.all([
    supabase.from('tax_codes').select('*').eq('client_id', clientId).order('code'),
    supabase
      .from('tax_code_rates')
      .select('*')
      .eq('client_id', clientId)
      .order('effective_from', { ascending: false }),
  ])
  if (codes.error) throw codes.error
  if (rates.error) throw rates.error
  const today = localToday()
  return codes.data.map((c) => {
    const codeRates = rates.data.filter((r) => r.tax_code_id === c.id)
    const current = codeRates.find((r) => r.effective_from <= today)
    return { ...c, currentRate: current ? Number(current.rate) : null, rates: codeRates }
  })
}

export async function seedTaxCodes(clientId: string, regime: TaxRegime): Promise<void> {
  const { error } = await supabase.rpc('seed_client_tax_codes', {
    p_client_id: clientId,
    p_regime: regime,
  })
  if (error) throw error
}

export async function updateTaxCode(
  id: string,
  patch: { name?: string; atc?: string; active?: boolean },
): Promise<void> {
  const { error } = await supabase.from('tax_codes').update(patch).eq('id', id)
  if (error) throw error
}

export async function addTaxRate(
  clientId: string,
  taxCodeId: string,
  effectiveFrom: string,
  rate: number,
): Promise<void> {
  const { error } = await supabase.from('tax_code_rates').insert({
    client_id: clientId,
    tax_code_id: taxCodeId,
    effective_from: effectiveFrom,
    rate,
  })
  if (error) throw error
}
