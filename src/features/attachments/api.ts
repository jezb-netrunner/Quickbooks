import { supabase } from '@/lib/supabase'
import type { Attachment } from '@/lib/database.types'

const BUCKET = 'attachments'
export const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024

/** An attachment hangs off exactly one of a document or a journal entry. */
export interface AttachmentRef {
  documentId?: string
  entryId?: string
}

export async function fetchAttachments(clientId: string, ref: AttachmentRef): Promise<Attachment[]> {
  let q = supabase.from('attachments').select('*').eq('client_id', clientId)
  q = ref.documentId ? q.eq('document_id', ref.documentId) : q.eq('entry_id', ref.entryId as string)
  const { data, error } = await q.order('created_at')
  if (error) throw error
  return data
}

// Upload the bytes first, then the row; if the row insert fails (RLS, bad
// ref), remove the orphaned object so storage never drifts from the table.
// The path prefix IS the tenancy wall — storage policies key on it.
export async function uploadAttachment(
  clientId: string,
  ref: AttachmentRef,
  file: File,
): Promise<void> {
  if (file.size > MAX_ATTACHMENT_BYTES) {
    throw new Error('Files up to 10 MB only — attach a smaller scan.')
  }
  const safeName = file.name.replace(/[^\w.\- ()]/g, '_').slice(-140) || 'file'
  const path = `${clientId}/${crypto.randomUUID()}-${safeName}`
  const { error: storageError } = await supabase.storage.from(BUCKET).upload(path, file, {
    contentType: file.type || 'application/octet-stream',
    upsert: false,
  })
  if (storageError) throw storageError
  const { error } = await supabase.from('attachments').insert({
    client_id: clientId,
    document_id: ref.documentId ?? null,
    entry_id: ref.entryId ?? null,
    storage_path: path,
    filename: file.name.slice(-200) || 'file',
    mime: file.type ?? '',
    size_bytes: file.size,
  })
  if (error) {
    await supabase.storage.from(BUCKET).remove([path])
    throw error
  }
}

export async function openAttachment(attachment: Attachment): Promise<void> {
  const { data, error } = await supabase.storage
    .from(BUCKET)
    .createSignedUrl(attachment.storage_path, 300)
  if (error) throw error
  window.open(data.signedUrl, '_blank', 'noopener')
}

export async function deleteAttachment(attachment: Attachment): Promise<void> {
  const { error } = await supabase.from('attachments').delete().eq('id', attachment.id)
  if (error) throw error
  // Best-effort: the row is authoritative; a stray object is invisible to the
  // app and unreachable outside the client prefix anyway.
  await supabase.storage.from(BUCKET).remove([attachment.storage_path])
}
