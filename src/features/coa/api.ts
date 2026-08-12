import { supabase } from '@/lib/supabase'
import type { Account, AccountType, NormalBalance } from '@/lib/database.types'

export async function fetchAccounts(clientId: string): Promise<Account[]> {
  const { data, error } = await supabase
    .from('accounts')
    .select('*')
    .eq('client_id', clientId)
    .order('code')
  if (error) throw error
  return data
}

export async function seedCoa(clientId: string): Promise<number> {
  const { data, error } = await supabase.rpc('seed_client_coa', { p_client_id: clientId })
  if (error) throw error
  return data
}

export interface AccountForm {
  code: string
  name: string
  account_type: AccountType
  normal_balance: NormalBalance
}

export async function createAccount(clientId: string, form: AccountForm): Promise<Account> {
  const { data, error } = await supabase
    .from('accounts')
    .insert({ client_id: clientId, ...form })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function updateAccount(
  accountId: string,
  form: Partial<Pick<Account, 'code' | 'name' | 'archived_at'>>,
): Promise<Account> {
  const { data, error } = await supabase
    .from('accounts')
    .update(form)
    .eq('id', accountId)
    .select()
    .single()
  if (error) throw error
  return data
}
