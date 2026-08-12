import { supabase } from '@/lib/supabase'
import type { ClientAssignment, MembershipRole } from '@/lib/database.types'

export interface MemberRow {
  id: string
  firm_id: string
  user_id: string
  role: MembershipRole
  has_all_clients: boolean
  client_id: string | null
  created_at: string
  profiles: { full_name: string; email: string } | null
}

export async function fetchMembers(firmId: string): Promise<MemberRow[]> {
  const { data, error } = await supabase
    .from('memberships')
    .select('id, firm_id, user_id, role, has_all_clients, client_id, created_at, profiles(full_name, email)')
    .eq('firm_id', firmId)
    .order('created_at')
  if (error) throw error
  return data as unknown as MemberRow[]
}

export async function fetchAssignments(firmId: string): Promise<ClientAssignment[]> {
  const { data, error } = await supabase.from('client_assignments').select('*').eq('firm_id', firmId)
  if (error) throw error
  return data
}

export interface AddMemberInput {
  firmId: string
  email: string
  role: MembershipRole
  clientId?: string | null
  hasAllClients?: boolean
  assignedClientIds?: string[]
}

export async function addMember(input: AddMemberInput): Promise<string> {
  const { data, error } = await supabase.rpc('add_member', {
    p_firm_id: input.firmId,
    p_email: input.email,
    p_role: input.role,
    p_client_id: input.clientId ?? null,
    p_has_all_clients: input.hasAllClients ?? false,
  })
  if (error) throw error
  const membershipId = data
  if (input.role !== 'client_viewer' && input.assignedClientIds && input.assignedClientIds.length > 0) {
    const { error: assignError } = await supabase.rpc('set_client_assignments', {
      p_membership_id: membershipId,
      p_client_ids: input.assignedClientIds,
    })
    if (assignError) throw assignError
  }
  return membershipId
}

export interface UpdateMemberInput {
  membershipId: string
  role: MembershipRole
  hasAllClients: boolean
  clientId?: string | null
  assignedClientIds?: string[]
}

export async function updateMember(input: UpdateMemberInput): Promise<void> {
  const { error } = await supabase.rpc('update_member', {
    p_membership_id: input.membershipId,
    p_role: input.role,
    p_has_all_clients: input.hasAllClients,
    p_client_id: input.clientId ?? null,
  })
  if (error) throw error
  if (input.role === 'staff' || input.role === 'reviewer') {
    const { error: assignError } = await supabase.rpc('set_client_assignments', {
      p_membership_id: input.membershipId,
      p_client_ids: input.assignedClientIds ?? [],
    })
    if (assignError) throw assignError
  }
}

export async function removeMember(membershipId: string): Promise<void> {
  const { error } = await supabase.rpc('remove_member', { p_membership_id: membershipId })
  if (error) throw error
}

export async function renameFirm(firmId: string, name: string): Promise<void> {
  const { error } = await supabase.from('firms').update({ name }).eq('id', firmId)
  if (error) throw error
}
