import { supabase } from '@/lib/supabase'
import type { Period } from '@/lib/database.types'

export async function fetchPeriods(clientId: string): Promise<Period[]> {
  const { data, error } = await supabase
    .from('periods')
    .select('*')
    .eq('client_id', clientId)
    .order('period_start', { ascending: false })
  if (error) throw error
  return data
}

export async function closePeriod(periodId: string): Promise<void> {
  const { error } = await supabase.rpc('close_period', { p_period_id: periodId })
  if (error) throw error
}

export async function reopenPeriod(periodId: string): Promise<void> {
  const { error } = await supabase.rpc('reopen_period', { p_period_id: periodId })
  if (error) throw error
}

export async function lockPeriod(periodId: string): Promise<void> {
  const { error } = await supabase.rpc('lock_period', { p_period_id: periodId })
  if (error) throw error
}
