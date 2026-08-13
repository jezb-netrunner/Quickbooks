import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys, ledgerReportPrefixes } from '@/lib/queryKeys'
import { postEntry } from '@/features/journal/api'
import { issueDocument } from '@/features/documents/api'
import { fetchApprovalsQueue, returnDocument, returnEntry, submitDocument, submitEntry } from './api'

export function useApprovalsQueue(clientId: string) {
  return useQuery({
    queryKey: keys.approvals(clientId),
    queryFn: () => fetchApprovalsQueue(clientId),
  })
}

// Submitting or returning only moves a row between draft and submitted;
// approving posts, so that path also rewrites every ledger-derived report.
function useInvalidateReview(clientId: string, posted: boolean) {
  const qc = useQueryClient()
  return () => {
    void qc.invalidateQueries({ queryKey: keys.approvals(clientId) })
    void qc.invalidateQueries({ queryKey: keys.entries(clientId) })
    void qc.invalidateQueries({ queryKey: ['entry-lines', clientId] })
    void qc.invalidateQueries({ queryKey: ['documents', clientId] })
    void qc.invalidateQueries({ queryKey: ['document-detail', clientId] })
    void qc.invalidateQueries({ queryKey: keys.practice })
    if (posted) {
      void qc.invalidateQueries({ queryKey: ['open-items', clientId] })
      void qc.invalidateQueries({ queryKey: ['aging', clientId] })
      void qc.invalidateQueries({ queryKey: keys.periods(clientId) })
      void qc.invalidateQueries({ queryKey: keys.dashboard(clientId) })
      for (const prefix of ledgerReportPrefixes) {
        void qc.invalidateQueries({ queryKey: [prefix, clientId] })
      }
    }
  }
}

export function useSubmitEntry(clientId: string) {
  const invalidate = useInvalidateReview(clientId, false)
  return useMutation({ mutationFn: (entryId: string) => submitEntry(entryId), onSuccess: invalidate })
}

export function useReturnEntry(clientId: string) {
  const invalidate = useInvalidateReview(clientId, false)
  return useMutation({
    mutationFn: (input: { entryId: string; note: string }) => returnEntry(input.entryId, input.note),
    onSuccess: invalidate,
  })
}

export function useSubmitDocument(clientId: string) {
  const invalidate = useInvalidateReview(clientId, false)
  return useMutation({
    mutationFn: (documentId: string) => submitDocument(documentId),
    onSuccess: invalidate,
  })
}

export function useReturnDocument(clientId: string) {
  const invalidate = useInvalidateReview(clientId, false)
  return useMutation({
    mutationFn: (input: { documentId: string; note: string }) =>
      returnDocument(input.documentId, input.note),
    onSuccess: invalidate,
  })
}

export function useApproveEntry(clientId: string) {
  const invalidate = useInvalidateReview(clientId, true)
  return useMutation({ mutationFn: (entryId: string) => postEntry(entryId), onSuccess: invalidate })
}

export function useApproveDocument(clientId: string) {
  const invalidate = useInvalidateReview(clientId, true)
  return useMutation({
    mutationFn: (documentId: string) => issueDocument(documentId),
    onSuccess: invalidate,
  })
}
