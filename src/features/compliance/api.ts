import { supabase } from '@/lib/supabase'
import type {
  CalendarRow,
  EwtLine,
  WhtByContactRow,
  WhtCertificate,
  WorkingPaperLine,
} from '@/lib/database.types'

export type WorkingPaperForm = 'wp_vat' | 'wp_percentage_tax' | 'wp_income_tax'

export async function fetchWorkingPaper(
  form: WorkingPaperForm,
  clientId: string,
  from: string,
  to: string,
): Promise<WorkingPaperLine[]> {
  const { data, error } = await supabase.rpc(form, {
    p_client_id: clientId,
    p_date_from: from,
    p_date_to: to,
  })
  if (error) throw error
  return data
}

export async function fetchEwtSummary(clientId: string, from: string, to: string): Promise<EwtLine[]> {
  const { data, error } = await supabase.rpc('wp_ewt', {
    p_client_id: clientId,
    p_date_from: from,
    p_date_to: to,
  })
  if (error) throw error
  return data
}

export async function fetchWhtRegister(
  direction: 'issued' | 'received',
  clientId: string,
  from: string,
  to: string,
): Promise<WhtByContactRow[]> {
  const { data, error } = await supabase.rpc(
    direction === 'issued' ? 'ewt_by_vendor' : 'cwt_by_customer',
    { p_client_id: clientId, p_date_from: from, p_date_to: to },
  )
  if (error) throw error
  return data
}

export async function fetchCertificates(clientId: string): Promise<WhtCertificate[]> {
  const { data, error } = await supabase
    .from('wht_certificates')
    .select('*')
    .eq('client_id', clientId)
    .order('cert_date', { ascending: false })
    .limit(200)
  if (error) throw error
  return data
}

export interface CertificateInput {
  direction: 'received' | 'issued'
  contact_id: string
  cert_no: string
  cert_date: string
  period_from: string
  period_to: string
  atc: string
  income_payment: number
  tax_withheld: number
  notes: string
}

export async function createCertificate(clientId: string, input: CertificateInput): Promise<void> {
  const { error } = await supabase.from('wht_certificates').insert({ client_id: clientId, ...input })
  if (error) throw error
}

export async function deleteCertificate(id: string): Promise<void> {
  const { error } = await supabase.from('wht_certificates').delete().eq('id', id)
  if (error) throw error
}

export async function fetchCalendar(clientId: string, year: number): Promise<CalendarRow[]> {
  const { data, error } = await supabase.rpc('compliance_calendar', {
    p_client_id: clientId,
    p_year: year,
  })
  if (error) throw error
  return data
}

export async function setFilingStatus(
  clientId: string,
  row: Pick<CalendarRow, 'form' | 'period_start' | 'period_end' | 'due_date'>,
  status: 'pending' | 'prepared' | 'filed',
  reference = '',
): Promise<void> {
  const { error } = await supabase.rpc('set_filing_status', {
    p_client_id: clientId,
    p_form: row.form,
    p_period_start: row.period_start,
    p_period_end: row.period_end,
    p_due_date: row.due_date,
    p_status: status,
    p_reference: reference,
  })
  if (error) throw error
}

export async function seedCompliance(clientId: string): Promise<void> {
  const { error } = await supabase.rpc('seed_client_compliance', { p_client_id: clientId })
  if (error) throw error
}
