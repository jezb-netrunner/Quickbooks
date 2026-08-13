import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys, ledgerReportPrefixes } from '@/lib/queryKeys'
import {
  deleteDraft,
  fetchEntries,
  fetchLines,
  postEntry,
  reverseEntry,
  saveDraft,
  type DraftEntryInput,
} from './api'

export function useEntries(clientId: string) {
  return useQuery({ queryKey: keys.entries(clientId), queryFn: () => fetchEntries(clientId) })
}

export function useEntryLines(clientId: string, entryId: string | null) {
  return useQuery({
    queryKey: keys.entryLines(clientId, entryId ?? 'new'),
    queryFn: () => fetchLines(entryId as string),
    enabled: entryId !== null,
  })
}

function useInvalidateJournal(clientId: string) {
  const qc = useQueryClient()
  return () => {
    void qc.invalidateQueries({ queryKey: keys.entries(clientId) })
    void qc.invalidateQueries({ queryKey: ['entry-lines', clientId] })
    void qc.invalidateQueries({ queryKey: keys.periods(clientId) })
    void qc.invalidateQueries({ queryKey: keys.dashboard(clientId) })
    // Posting rewrites every ledger-derived report.
    void qc.invalidateQueries({ queryKey: ['open-items', clientId] })
    void qc.invalidateQueries({ queryKey: ['aging', clientId] })
    for (const prefix of ledgerReportPrefixes) {
      void qc.invalidateQueries({ queryKey: [prefix, clientId] })
    }
  }
}

export function useSaveDraft(clientId: string) {
  const invalidate = useInvalidateJournal(clientId)
  return useMutation({
    mutationFn: (input: { entryId: string | null; draft: DraftEntryInput }) =>
      saveDraft(clientId, input.entryId, input.draft),
    onSuccess: invalidate,
  })
}

export function useDeleteDraft(clientId: string) {
  const invalidate = useInvalidateJournal(clientId)
  return useMutation({ mutationFn: (entryId: string) => deleteDraft(entryId), onSuccess: invalidate })
}

export function usePostEntry(clientId: string) {
  const invalidate = useInvalidateJournal(clientId)
  return useMutation({ mutationFn: (entryId: string) => postEntry(entryId), onSuccess: invalidate })
}

export function useReverseEntry(clientId: string) {
  const invalidate = useInvalidateJournal(clientId)
  return useMutation({
    mutationFn: (input: { entryId: string; date?: string }) => reverseEntry(input.entryId, input.date),
    onSuccess: invalidate,
  })
}
