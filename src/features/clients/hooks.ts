import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys } from '@/lib/queryKeys'
import {
  createClient,
  createFirm,
  fetchClient,
  fetchClients,
  fetchMyMemberships,
  setClientArchived,
  updateClient,
  type ClientForm,
} from './api'

export function useMyMemberships() {
  return useQuery({ queryKey: keys.memberships, queryFn: fetchMyMemberships })
}

export function useClients() {
  return useQuery({ queryKey: keys.clients, queryFn: fetchClients })
}

export function useClient(clientId: string) {
  return useQuery({ queryKey: keys.client(clientId), queryFn: () => fetchClient(clientId) })
}

export function useCreateFirm() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (name: string) => createFirm(name),
    onSuccess: () => qc.invalidateQueries(),
  })
}

export function useCreateClient(firmId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (form: ClientForm) => createClient(firmId, form),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.clients }),
  })
}

export function useUpdateClient(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (form: Partial<ClientForm>) => updateClient(clientId, form),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: keys.clients })
      qc.invalidateQueries({ queryKey: keys.client(clientId) })
    },
  })
}

export function useSetClientArchived(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (archived: boolean) => setClientArchived(clientId, archived),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: keys.clients })
      qc.invalidateQueries({ queryKey: keys.client(clientId) })
    },
  })
}
