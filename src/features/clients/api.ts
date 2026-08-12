import { supabase } from '@/lib/supabase'
import type { Client, MembershipRole, ReportingBasis } from '@/lib/database.types'

export interface MembershipWithFirm {
  id: string
  firm_id: string
  role: MembershipRole
  has_all_clients: boolean
  client_id: string | null
  firms: { id: string; name: string } | null
}

export async function fetchMyMemberships(): Promise<MembershipWithFirm[]> {
  const { data, error } = await supabase
    .from('memberships')
    .select('id, firm_id, role, has_all_clients, client_id, firms(id, name)')
    .order('created_at')
  if (error) throw error
  return data as unknown as MembershipWithFirm[]
}

export async function fetchClients(): Promise<Client[]> {
  // RLS is the filter: this returns exactly the clients the caller may see.
  const { data, error } = await supabase.from('clients').select('*').order('name')
  if (error) throw error
  return data
}

export async function fetchClient(clientId: string): Promise<Client | null> {
  // Zero rows means "does not exist OR not yours" — deliberately
  // indistinguishable, so URLs are not an existence oracle.
  const { data, error } = await supabase.from('clients').select('*').eq('id', clientId).maybeSingle()
  if (error) throw error
  return data
}

export interface ClientForm {
  name: string
  code: string | null
  tin: string | null
  reporting_basis: ReportingBasis
  fiscal_year_end_month: number
}

export async function createClient(firmId: string, form: ClientForm): Promise<Client> {
  const { data, error } = await supabase
    .from('clients')
    .insert({ firm_id: firmId, ...form })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function updateClient(clientId: string, form: Partial<ClientForm>): Promise<Client> {
  const { data, error } = await supabase.from('clients').update(form).eq('id', clientId).select().single()
  if (error) throw error
  return data
}

export async function setClientArchived(clientId: string, archived: boolean): Promise<Client> {
  const { data, error } = await supabase
    .from('clients')
    .update({ archived_at: archived ? new Date().toISOString() : null })
    .eq('id', clientId)
    .select()
    .single()
  if (error) throw error
  return data
}

export async function createFirm(name: string): Promise<string> {
  const { data, error } = await supabase.rpc('create_firm', { p_name: name })
  if (error) throw error
  return data
}
