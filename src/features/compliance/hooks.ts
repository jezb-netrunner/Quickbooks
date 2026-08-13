import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys } from '@/lib/queryKeys'
import type { CalendarRow } from '@/lib/database.types'
import {
  createCertificate,
  deleteCertificate,
  fetchCalendar,
  fetchCertificates,
  fetchEwtSummary,
  fetchWhtRegister,
  fetchWorkingPaper,
  seedCompliance,
  setFilingStatus,
  type CertificateInput,
  type WorkingPaperForm,
} from './api'

export function useWorkingPaper(form: WorkingPaperForm, clientId: string, from: string, to: string) {
  return useQuery({
    queryKey: keys.workingPaper(clientId, form, from, to),
    queryFn: () => fetchWorkingPaper(form, clientId, from, to),
    enabled: Boolean(from && to),
  })
}

export function useEwtSummary(clientId: string, from: string, to: string) {
  return useQuery({
    queryKey: keys.workingPaper(clientId, 'wp_ewt', from, to),
    queryFn: () => fetchEwtSummary(clientId, from, to),
    enabled: Boolean(from && to),
  })
}

export function useWhtRegister(
  direction: 'issued' | 'received',
  clientId: string,
  from: string,
  to: string,
) {
  return useQuery({
    queryKey: keys.whtRegister(clientId, direction, from, to),
    queryFn: () => fetchWhtRegister(direction, clientId, from, to),
    enabled: Boolean(from && to),
  })
}

export function useCertificates(clientId: string) {
  return useQuery({
    queryKey: keys.certificates(clientId),
    queryFn: () => fetchCertificates(clientId),
  })
}

export function useCreateCertificate(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: CertificateInput) => createCertificate(clientId, input),
    onSuccess: () => void qc.invalidateQueries({ queryKey: keys.certificates(clientId) }),
  })
}

export function useDeleteCertificate(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => deleteCertificate(id),
    onSuccess: () => void qc.invalidateQueries({ queryKey: keys.certificates(clientId) }),
  })
}

export function useCalendar(clientId: string, year: number) {
  return useQuery({
    queryKey: keys.calendar(clientId, year),
    queryFn: () => fetchCalendar(clientId, year),
  })
}

export function useSetFilingStatus(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (args: {
      row: Pick<CalendarRow, 'form' | 'period_start' | 'period_end' | 'due_date'>
      status: 'pending' | 'prepared' | 'filed'
      reference?: string
    }) => setFilingStatus(clientId, args.row, args.status, args.reference ?? ''),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['calendar', clientId] }),
  })
}

export function useSeedCompliance(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: () => seedCompliance(clientId),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['calendar', clientId] })
      void qc.invalidateQueries({ queryKey: keys.taxProfile(clientId) })
    },
  })
}

/** Calendar-quarter presets for working-paper period pickers. */
export function quarterRange(year: number, q: 1 | 2 | 3 | 4): { from: string; to: string } {
  const lastDay = [31, 30, 30, 31][q - 1]
  const startMonth = String((q - 1) * 3 + 1).padStart(2, '0')
  const endMonth = String(q * 3).padStart(2, '0')
  return { from: `${year}-${startMonth}-01`, to: `${year}-${endMonth}-${lastDay}` }
}
