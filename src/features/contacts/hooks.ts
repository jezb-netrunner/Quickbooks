import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys } from '@/lib/queryKeys'
import { createContact, fetchContacts, updateContact, type ContactForm } from './api'

export function useContacts(clientId: string) {
  return useQuery({ queryKey: keys.contacts(clientId), queryFn: () => fetchContacts(clientId) })
}

export function useCreateContact(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (form: ContactForm) => createContact(clientId, form),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.contacts(clientId) }),
  })
}

export function useUpdateContact(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: { contactId: string; form: Partial<ContactForm & { archived_at: string | null }> }) =>
      updateContact(input.contactId, input.form),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.contacts(clientId) }),
  })
}
