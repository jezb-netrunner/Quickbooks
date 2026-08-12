import { supabase } from '@/lib/supabase'
import type { Contact, ContactType } from '@/lib/database.types'

export async function fetchContacts(clientId: string): Promise<Contact[]> {
  const { data, error } = await supabase
    .from('contacts')
    .select('*')
    .eq('client_id', clientId)
    .order('name')
  if (error) throw error
  return data
}

export interface ContactForm {
  name: string
  contact_type: ContactType
  tin: string | null
  email: string | null
}

export async function createContact(clientId: string, form: ContactForm): Promise<Contact> {
  const { data, error } = await supabase
    .from('contacts')
    .insert({ client_id: clientId, ...form })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function updateContact(
  contactId: string,
  form: Partial<ContactForm & { archived_at: string | null }>,
): Promise<Contact> {
  const { data, error } = await supabase
    .from('contacts')
    .update(form)
    .eq('id', contactId)
    .select()
    .single()
  if (error) throw error
  return data
}
