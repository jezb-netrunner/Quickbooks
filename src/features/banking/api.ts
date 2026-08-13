import { supabase } from '@/lib/supabase'
import type { BankImportProfile, BankRule, BankTxn, Json } from '@/lib/database.types'

export async function fetchBankTxns(clientId: string): Promise<BankTxn[]> {
  const { data, error } = await supabase
    .from('bank_txns')
    .select('*')
    .eq('client_id', clientId)
    .order('txn_date', { ascending: false })
    .order('created_at', { ascending: false })
    .limit(500)
  if (error) throw error
  return data
}

export async function fetchProfiles(clientId: string): Promise<BankImportProfile[]> {
  const { data, error } = await supabase
    .from('bank_import_profiles')
    .select('*')
    .eq('client_id', clientId)
    .order('name')
  if (error) throw error
  return data
}

export interface ProfileForm {
  name: string
  bank_account_id: string
  date_col: number
  desc_col: number
  amount_col: number | null
  debit_col: number | null
  credit_col: number | null
  date_format: 'YMD' | 'DMY' | 'MDY'
  skip_rows: number
  negate: boolean
}

export async function saveProfile(
  clientId: string,
  profileId: string | null,
  form: ProfileForm,
): Promise<BankImportProfile> {
  if (profileId === null) {
    const { data, error } = await supabase
      .from('bank_import_profiles')
      .insert({ client_id: clientId, ...form })
      .select()
      .single()
    if (error) throw error
    return data
  }
  const { data, error } = await supabase
    .from('bank_import_profiles')
    .update(form)
    .eq('id', profileId)
    .select()
    .single()
  if (error) throw error
  return data
}

export async function deleteProfile(profileId: string): Promise<void> {
  const { error } = await supabase.from('bank_import_profiles').delete().eq('id', profileId)
  if (error) throw error
}

/** A statement line already parsed by the browser: ISO date, memo, signed amount. */
export interface ParsedBankRow {
  d: string
  m: string
  a: number
}

export interface ImportResult {
  inserted: number
  duplicates: number
  skipped: number
}

export async function importBankTxns(
  clientId: string,
  bankAccountId: string,
  rows: ParsedBankRow[],
): Promise<ImportResult> {
  const { data, error } = await supabase.rpc('import_bank_txns', {
    p_client_id: clientId,
    p_bank_account_id: bankAccountId,
    p_rows: rows as unknown as Json,
  })
  if (error) throw error
  return data[0] ?? { inserted: 0, duplicates: 0, skipped: 0 }
}

export async function categorizeBankTxn(txnId: string, accountId: string): Promise<void> {
  const { error } = await supabase.rpc('categorize_bank_txn', {
    p_txn_id: txnId,
    p_account_id: accountId,
  })
  if (error) throw error
}

export async function excludeBankTxn(txnId: string, note = ''): Promise<void> {
  const { error } = await supabase.rpc('exclude_bank_txn', { p_txn_id: txnId, p_note: note })
  if (error) throw error
}

export async function restoreBankTxn(txnId: string): Promise<void> {
  const { error } = await supabase.rpc('restore_bank_txn', { p_txn_id: txnId })
  if (error) throw error
}

export async function applyBankRules(clientId: string): Promise<number> {
  const { data, error } = await supabase.rpc('apply_bank_rules', { p_client_id: clientId })
  if (error) throw error
  return data
}

export async function fetchRules(clientId: string): Promise<BankRule[]> {
  const { data, error } = await supabase
    .from('bank_rules')
    .select('*')
    .eq('client_id', clientId)
    .order('priority')
    .order('created_at')
  if (error) throw error
  return data
}

export interface RuleForm {
  match_text: string
  account_id: string
  priority: number
}

export async function createRule(clientId: string, form: RuleForm): Promise<void> {
  const { error } = await supabase.from('bank_rules').insert({ client_id: clientId, ...form })
  if (error) throw error
}

export async function deleteRule(ruleId: string): Promise<void> {
  const { error } = await supabase.from('bank_rules').delete().eq('id', ruleId)
  if (error) throw error
}
