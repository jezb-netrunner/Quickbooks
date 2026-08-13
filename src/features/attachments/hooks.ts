import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys } from '@/lib/queryKeys'
import type { Attachment } from '@/lib/database.types'
import { deleteAttachment, fetchAttachments, uploadAttachment, type AttachmentRef } from './api'

function refId(ref: AttachmentRef): string {
  return ref.documentId ?? ref.entryId ?? 'none'
}

export function useAttachments(clientId: string, ref: AttachmentRef) {
  return useQuery({
    queryKey: keys.attachments(clientId, refId(ref)),
    queryFn: () => fetchAttachments(clientId, ref),
    enabled: !!(ref.documentId || ref.entryId),
  })
}

export function useUploadAttachment(clientId: string, ref: AttachmentRef) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (file: File) => uploadAttachment(clientId, ref, file),
    onSuccess: () => void qc.invalidateQueries({ queryKey: keys.attachments(clientId, refId(ref)) }),
  })
}

export function useDeleteAttachment(clientId: string, ref: AttachmentRef) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (attachment: Attachment) => deleteAttachment(attachment),
    onSuccess: () => void qc.invalidateQueries({ queryKey: keys.attachments(clientId, refId(ref)) }),
  })
}
