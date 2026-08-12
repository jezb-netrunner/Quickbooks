import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys } from '@/lib/queryKeys'
import { createAccount, fetchAccounts, seedCoa, updateAccount, type AccountForm } from './api'
import type { Account } from '@/lib/database.types'

export function useAccounts(clientId: string) {
  return useQuery({ queryKey: keys.accounts(clientId), queryFn: () => fetchAccounts(clientId) })
}

export function useSeedCoa(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: () => seedCoa(clientId),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.accounts(clientId) }),
  })
}

export function useCreateAccount(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (form: AccountForm) => createAccount(clientId, form),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.accounts(clientId) }),
  })
}

export function useUpdateAccount(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: { accountId: string; form: Partial<Pick<Account, 'code' | 'name' | 'archived_at'>> }) =>
      updateAccount(input.accountId, input.form),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.accounts(clientId) }),
  })
}
