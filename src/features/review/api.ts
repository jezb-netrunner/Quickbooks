import { supabase } from '@/lib/supabase'
import type { DocumentRow, JournalEntry } from '@/lib/database.types'

export async function submitEntry(entryId: string): Promise<void> {
  const { error } = await supabase.rpc('submit_entry', { p_entry_id: entryId })
  if (error) throw error
}

export async function returnEntry(entryId: string, note: string): Promise<void> {
  const { error } = await supabase.rpc('return_entry', { p_entry_id: entryId, p_note: note })
  if (error) throw error
}

export async function submitDocument(documentId: string): Promise<void> {
  const { error } = await supabase.rpc('submit_document', { p_document_id: documentId })
  if (error) throw error
}

export async function returnDocument(documentId: string, note: string): Promise<void> {
  const { error } = await supabase.rpc('return_document', { p_document_id: documentId, p_note: note })
  if (error) throw error
}

export interface ApprovalsQueue {
  entries: JournalEntry[]
  documents: DocumentRow[]
}

export async function fetchApprovalsQueue(clientId: string): Promise<ApprovalsQueue> {
  const [entries, documents] = await Promise.all([
    supabase
      .from('journal_entries')
      .select('*')
      .eq('client_id', clientId)
      .eq('status', 'submitted')
      .order('entry_date'),
    supabase
      .from('documents')
      .select('*')
      .eq('client_id', clientId)
      .eq('status', 'submitted')
      .order('doc_date'),
  ])
  if (entries.error) throw entries.error
  if (documents.error) throw documents.error
  return { entries: entries.data, documents: documents.data }
}
