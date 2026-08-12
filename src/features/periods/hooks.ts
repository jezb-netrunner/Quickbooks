import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys } from '@/lib/queryKeys'
import { closePeriod, fetchPeriods, lockPeriod, reopenPeriod } from './api'

export function usePeriods(clientId: string) {
  return useQuery({ queryKey: keys.periods(clientId), queryFn: () => fetchPeriods(clientId) })
}

export function usePeriodAction(clientId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: { periodId: string; action: 'close' | 'reopen' | 'lock' }) =>
      input.action === 'close'
        ? closePeriod(input.periodId)
        : input.action === 'reopen'
          ? reopenPeriod(input.periodId)
          : lockPeriod(input.periodId),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.periods(clientId) }),
  })
}
