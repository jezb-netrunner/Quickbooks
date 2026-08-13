import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys, ledgerReportPrefixes } from '@/lib/queryKeys'
import type { DocType } from '@/lib/database.types'
import {
  deleteDocumentDraft,
  fetchDocumentDetail,
  fetchDocuments,
  fetchOpenItems,
  issueDocument,
  saveDocumentDraft,
  voidDocument,
  type DraftDocumentInput,
} from './api'

export function useDocuments(clientId: string, docType: DocType) {
  return useQuery({
    queryKey: keys.documents(clientId, docType),
    queryFn: () => fetchDocuments(clientId, docType),
  })
}

export function useDocumentDetail(clientId: string, documentId: string | null) {
  return useQuery({
    queryKey: keys.documentDetail(clientId, documentId ?? 'new'),
    queryFn: () => fetchDocumentDetail(documentId as string),
    enabled: documentId !== null,
  })
}

export function useOpenItems(clientId: string, docType: 'invoice' | 'bill', asOf: string) {
  return useQuery({
    queryKey: keys.openItems(clientId, docType, asOf),
    queryFn: () => fetchOpenItems(clientId, docType, asOf),
  })
}

function useInvalidateDocuments(clientId: string) {
  const qc = useQueryClient()
  return () => {
    void qc.invalidateQueries({ queryKey: ['documents', clientId] })
    void qc.invalidateQueries({ queryKey: ['document-detail', clientId] })
    void qc.invalidateQueries({ queryKey: ['open-items', clientId] })
    void qc.invalidateQueries({ queryKey: ['aging', clientId] })
    void qc.invalidateQueries({ queryKey: keys.entries(clientId) })
    void qc.invalidateQueries({ queryKey: keys.periods(clientId) })
    void qc.invalidateQueries({ queryKey: keys.dashboard(clientId) })
    for (const prefix of ledgerReportPrefixes) {
      void qc.invalidateQueries({ queryKey: [prefix, clientId] })
    }
  }
}

export function useSaveDocument(clientId: string, docType: DocType) {
  const invalidate = useInvalidateDocuments(clientId)
  return useMutation({
    mutationFn: (input: { documentId: string | null; draft: DraftDocumentInput }) =>
      saveDocumentDraft(clientId, docType, input.documentId, input.draft),
    onSuccess: invalidate,
  })
}

export function useDeleteDocument(clientId: string) {
  const invalidate = useInvalidateDocuments(clientId)
  return useMutation({ mutationFn: (id: string) => deleteDocumentDraft(id), onSuccess: invalidate })
}

export function useIssueDocument(clientId: string) {
  const invalidate = useInvalidateDocuments(clientId)
  return useMutation({ mutationFn: (id: string) => issueDocument(id), onSuccess: invalidate })
}

export function useVoidDocument(clientId: string) {
  const invalidate = useInvalidateDocuments(clientId)
  return useMutation({
    mutationFn: (input: { id: string; date?: string }) => voidDocument(input.id, input.date),
    onSuccess: invalidate,
  })
}
