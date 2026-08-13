import { supabase } from '@/lib/supabase'
import type {
  DocType,
  DocumentApplication,
  DocumentLine,
  DocumentRow,
  OpenItemRow,
} from '@/lib/database.types'

export async function fetchDocuments(clientId: string, docType: DocType): Promise<DocumentRow[]> {
  const { data, error } = await supabase
    .from('documents')
    .select('*')
    .eq('client_id', clientId)
    .eq('doc_type', docType)
    .order('doc_date', { ascending: false })
    .order('created_at', { ascending: false })
    .limit(200)
  if (error) throw error
  return data
}

export interface DocumentDetail {
  lines: DocumentLine[]
  applications: DocumentApplication[]
}

export async function fetchDocumentDetail(documentId: string): Promise<DocumentDetail> {
  const [lines, applications] = await Promise.all([
    supabase.from('document_lines').select('*').eq('document_id', documentId).order('line_no'),
    supabase.from('document_applications').select('*').eq('paying_document_id', documentId),
  ])
  if (lines.error) throw lines.error
  if (applications.error) throw applications.error
  return { lines: lines.data, applications: applications.data }
}

// docType takes an exact type ('invoice', 'bill', 'purchase') or a side
// ('receivable', 'payable' = bills + purchases).
export async function fetchOpenItems(
  clientId: string,
  docType: string,
  asOf: string,
): Promise<OpenItemRow[]> {
  const { data, error } = await supabase.rpc('open_items', {
    p_client_id: clientId,
    p_doc_type: docType,
    p_as_of: asOf,
  })
  if (error) throw error
  return data
}

export interface DraftDocumentInput {
  docDate: string
  dueDate: string | null
  contactId: string
  bankAccountId: string | null
  memo: string
  amountsIncludeTax: boolean
  whtTaxCodeId: string | null
  whtBase: number | null
  lines: {
    account_id: string
    description: string
    amount: number
    tax_code_id: string | null
    item_id: string | null
    qty: number | null
  }[]
  applications: { target_document_id: string; amount: number }[]
}

// Replace-set semantics for lines and applications, mirroring the journal
// draft editor. Only drafts are writable — RLS and triggers enforce it.
export async function saveDocumentDraft(
  clientId: string,
  docType: DocType,
  documentId: string | null,
  input: DraftDocumentInput,
): Promise<string> {
  let id = documentId
  const header = {
    doc_date: input.docDate,
    due_date: input.dueDate,
    contact_id: input.contactId,
    bank_account_id: input.bankAccountId,
    memo: input.memo,
    amounts_include_tax: input.amountsIncludeTax,
    wht_tax_code_id: input.whtTaxCodeId,
    wht_base: input.whtBase,
  }
  if (id === null) {
    const { data, error } = await supabase
      .from('documents')
      .insert({ client_id: clientId, doc_type: docType, ...header })
      .select('id')
      .single()
    if (error) throw error
    id = data.id
  } else {
    const { error } = await supabase.from('documents').update(header).eq('id', id)
    if (error) throw error
    const { error: dl } = await supabase.from('document_lines').delete().eq('document_id', id)
    if (dl) throw dl
    const { error: da } = await supabase
      .from('document_applications')
      .delete()
      .eq('paying_document_id', id)
    if (da) throw da
  }
  if (input.lines.length > 0) {
    const { error } = await supabase.from('document_lines').insert(
      input.lines.map((l, i) => ({
        document_id: id as string,
        client_id: clientId,
        line_no: i + 1,
        account_id: l.account_id,
        description: l.description,
        amount: l.amount,
        tax_code_id: l.tax_code_id,
        item_id: l.item_id,
        qty: l.qty,
      })),
    )
    if (error) throw error
  }
  if (input.applications.length > 0) {
    const { error } = await supabase.from('document_applications').insert(
      input.applications.map((a) => ({
        client_id: clientId,
        paying_document_id: id as string,
        target_document_id: a.target_document_id,
        amount: a.amount,
      })),
    )
    if (error) throw error
  }
  return id as string
}

export async function deleteDocumentDraft(documentId: string): Promise<void> {
  const { error } = await supabase.from('documents').delete().eq('id', documentId)
  if (error) throw error
}

export async function issueDocument(documentId: string): Promise<number> {
  const { data, error } = await supabase.rpc('issue_document', { p_document_id: documentId })
  if (error) throw error
  return data
}

export async function voidDocument(documentId: string, date?: string): Promise<void> {
  const { error } = await supabase.rpc('void_document', {
    p_document_id: documentId,
    p_date: date ?? null,
  })
  if (error) throw error
}
