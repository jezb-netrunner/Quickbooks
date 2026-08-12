import { supabase } from '@/lib/supabase'
import type { JournalEntry, JournalLine } from '@/lib/database.types'

export async function fetchEntries(clientId: string): Promise<JournalEntry[]> {
  const { data, error } = await supabase
    .from('journal_entries')
    .select('*')
    .eq('client_id', clientId)
    .order('entry_date', { ascending: false })
    .order('created_at', { ascending: false })
    .limit(200)
  if (error) throw error
  return data
}

export async function fetchLines(entryId: string): Promise<JournalLine[]> {
  const { data, error } = await supabase
    .from('journal_lines')
    .select('*')
    .eq('entry_id', entryId)
    .order('line_no')
  if (error) throw error
  return data
}

export interface DraftLine {
  account_id: string
  debit: number
  credit: number
}

export interface DraftEntryInput {
  entryDate: string
  memo: string
  lines: DraftLine[]
}

// Draft editing uses replace-set semantics: delete the draft's lines and
// reinsert 1..n. Only drafts are writable (RLS + trigger enforce it), so this
// can never touch posted history.
export async function saveDraft(
  clientId: string,
  entryId: string | null,
  input: DraftEntryInput,
): Promise<string> {
  let id = entryId
  if (id === null) {
    const { data, error } = await supabase
      .from('journal_entries')
      .insert({ client_id: clientId, entry_date: input.entryDate, memo: input.memo })
      .select('id')
      .single()
    if (error) throw error
    id = data.id
  } else {
    const { error } = await supabase
      .from('journal_entries')
      .update({ entry_date: input.entryDate, memo: input.memo })
      .eq('id', id)
    if (error) throw error
    const { error: delError } = await supabase.from('journal_lines').delete().eq('entry_id', id)
    if (delError) throw delError
  }
  const rows = input.lines.map((l, i) => ({
    entry_id: id as string,
    client_id: clientId,
    line_no: i + 1,
    account_id: l.account_id,
    debit: l.debit,
    credit: l.credit,
  }))
  if (rows.length > 0) {
    const { error } = await supabase.from('journal_lines').insert(rows)
    if (error) throw error
  }
  return id as string
}

export async function deleteDraft(entryId: string): Promise<void> {
  const { error } = await supabase.from('journal_entries').delete().eq('id', entryId)
  if (error) throw error
}

export async function postEntry(entryId: string): Promise<number> {
  const { data, error } = await supabase.rpc('post_entry', { p_entry_id: entryId })
  if (error) throw error
  return data
}

export async function reverseEntry(entryId: string, date?: string): Promise<string> {
  const { data, error } = await supabase.rpc('reverse_entry', {
    p_entry_id: entryId,
    p_date: date ?? null,
  })
  if (error) throw error
  return data
}
