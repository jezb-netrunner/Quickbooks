import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys, ledgerReportPrefixes } from '@/lib/queryKeys'
import {
  applyBankRules,
  categorizeBankTxn,
  createRule,
  deleteProfile,
  deleteRule,
  excludeBankTxn,
  fetchBankTxns,
  fetchProfiles,
  fetchRules,
  importBankTxns,
  restoreBankTxn,
  saveProfile,
  type ParsedBankRow,
  type ProfileForm,
  type RuleForm,
} from './api'

export function useBankTxns(clientId: string) {
  return useQuery({ queryKey: keys.bankTxns(clientId), queryFn: () => fetchBankTxns(clientId) })
}

export function useBankProfiles(clientId: string) {
  return useQuery({ queryKey: keys.bankProfiles(clientId), queryFn: () => fetchProfiles(clientId) })
}

export function useBankRules(clientId: string) {
  return useQuery({ queryKey: keys.bankRules(clientId), queryFn: () => fetchRules(clientId) })
}

// Categorizing posts a journal entry, so everything ledger-derived refetches.
function useInvalidateBanking(clientId: string, posted: boolean) {
  const qc = useQueryClient()
  return () => {
    void qc.invalidateQueries({ queryKey: keys.bankTxns(clientId) })
    void qc.invalidateQueries({ queryKey: keys.practice })
    if (posted) {
      void qc.invalidateQueries({ queryKey: keys.entries(clientId) })
      void qc.invalidateQueries({ queryKey: keys.periods(clientId) })
      void qc.invalidateQueries({ queryKey: keys.dashboard(clientId) })
      for (const prefix of ledgerReportPrefixes) {
        void qc.invalidateQueries({ queryKey: [prefix, clientId] })
      }
    }
  }
}

export function useImportBankTxns(clientId: string) {
  const invalidate = useInvalidateBanking(clientId, false)
  return useMutation({
    mutationFn: (input: { bankAccountId: string; rows: ParsedBankRow[] }) =>
      importBankTxns(clientId, input.bankAccountId, input.rows),
    onSuccess: invalidate,
  })
}

export function useCategorizeBankTxn(clientId: string) {
  const invalidate = useInvalidateBanking(clientId, true)
  return useMutation({
    mutationFn: (input: { txnId: string; accountId: string; taxCodeId?: string | null }) =>
      categorizeBankTxn(input.txnId, input.accountId, input.taxCodeId ?? null),
    onSuccess: invalidate,
  })
}

export function useExcludeBankTxn(clientId: string) {
  const invalidate = useInvalidateBanking(clientId, false)
  return useMutation({
    mutationFn: (txnId: string) => excludeBankTxn(txnId),
    onSuccess: invalidate,
  })
}

export function useRestoreBankTxn(clientId: string) {
  const invalidate = useInvalidateBanking(clientId, false)
  return useMutation({
    mutationFn: (txnId: string) => restoreBankTxn(txnId),
    onSuccess: invalidate,
  })
}

export function useApplyBankRules(clientId: string) {
  const invalidate = useInvalidateBanking(clientId, true)
  return useMutation({ mutationFn: () => applyBankRules(clientId), onSuccess: invalidate })
}

export function useSaveBankProfile(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: { profileId: string | null; form: ProfileForm }) =>
      saveProfile(clientId, input.profileId, input.form),
    onSuccess: () => void qc.invalidateQueries({ queryKey: keys.bankProfiles(clientId) }),
  })
}

export function useDeleteBankProfile(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (profileId: string) => deleteProfile(profileId),
    onSuccess: () => void qc.invalidateQueries({ queryKey: keys.bankProfiles(clientId) }),
  })
}

export function useCreateBankRule(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (form: RuleForm) => createRule(clientId, form),
    onSuccess: () => void qc.invalidateQueries({ queryKey: keys.bankRules(clientId) }),
  })
}

export function useDeleteBankRule(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (ruleId: string) => deleteRule(ruleId),
    onSuccess: () => void qc.invalidateQueries({ queryKey: keys.bankRules(clientId) }),
  })
}
