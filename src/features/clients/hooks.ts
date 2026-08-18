import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys } from '@/lib/queryKeys'
import {
  createClient,
  createFirm,
  fetchClient,
  fetchClients,
  fetchMyMemberships,
  setClientArchived,
  setRequireApproval,
  setupClient,
  updateClient,
  type ClientForm,
  type ClientTaxSetup,
} from './api'

export function useMyMemberships() {
  return useQuery({ queryKey: keys.memberships, queryFn: fetchMyMemberships })
}

// Approval rights mirror the database's app.can_approve (firm admin of the
// client's firm) — a UI convenience only; the RPCs are the enforcement.
export function useIsFirmAdmin(): boolean {
  const { data } = useMyMemberships()
  return (data ?? []).some((m) => m.role === 'firm_admin')
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

// The wizard's mutation: create the client, then run the one-call tax setup.
// If setup fails after the create, the client exists but is unconfigured —
// the documents pages show a "tax setup required" banner and the database
// refuses to issue documents until setup completes, so nothing silent leaks.
export function useCreateClientWithSetup(firmId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ form, setup }: { form: ClientForm; setup: ClientTaxSetup }) => {
      const client = await createClient(firmId, form)
      try {
        await setupClient(client.id, setup)
      } catch (err) {
        throw new Error(
          `${form.name} was created, but tax setup did not finish — open the client's settings and run “Set up tax & compliance”. (${err instanceof Error ? err.message : String(err)})`,
          { cause: err },
        )
      }
      return client
    },
    // Settled, not success: a half-created client must appear in the list too.
    onSettled: () => qc.invalidateQueries({ queryKey: keys.clients }),
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

export function useSetRequireApproval(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (on: boolean) => setRequireApproval(clientId, on),
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
