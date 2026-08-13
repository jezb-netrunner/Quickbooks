import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys, ledgerReportPrefixes } from '@/lib/queryKeys'
import {
  createItem,
  fetchAdjustments,
  fetchItems,
  fetchStockCard,
  fetchValuation,
  postAdjustment,
  updateItem,
  type ItemInput,
} from './api'

export function useItems(clientId: string) {
  return useQuery({ queryKey: keys.items(clientId), queryFn: () => fetchItems(clientId) })
}

export function useValuation(clientId: string) {
  return useQuery({ queryKey: keys.valuation(clientId), queryFn: () => fetchValuation(clientId) })
}

export function useStockCard(clientId: string, itemId: string, from: string, to: string) {
  return useQuery({
    queryKey: keys.stockCard(clientId, itemId, from, to),
    queryFn: () => fetchStockCard(clientId, itemId, from, to),
    enabled: Boolean(itemId && from && to),
  })
}

export function useAdjustments(clientId: string) {
  return useQuery({
    queryKey: keys.adjustments(clientId),
    queryFn: () => fetchAdjustments(clientId),
  })
}

function useInvalidateInventory(clientId: string) {
  const qc = useQueryClient()
  return () => {
    void qc.invalidateQueries({ queryKey: keys.items(clientId) })
    void qc.invalidateQueries({ queryKey: keys.valuation(clientId) })
    void qc.invalidateQueries({ queryKey: ['stock-card', clientId] })
    void qc.invalidateQueries({ queryKey: keys.adjustments(clientId) })
    void qc.invalidateQueries({ queryKey: keys.entries(clientId) })
    void qc.invalidateQueries({ queryKey: keys.dashboard(clientId) })
    for (const prefix of ledgerReportPrefixes) {
      void qc.invalidateQueries({ queryKey: [prefix, clientId] })
    }
  }
}

export function useCreateItem(clientId: string) {
  const invalidate = useInvalidateInventory(clientId)
  return useMutation({
    mutationFn: (input: ItemInput) => createItem(clientId, input),
    onSuccess: invalidate,
  })
}

export function useUpdateItem(clientId: string) {
  const invalidate = useInvalidateInventory(clientId)
  return useMutation({
    mutationFn: (args: { id: string; patch: Partial<ItemInput> & { archived_at?: string | null } }) =>
      updateItem(args.id, args.patch),
    onSuccess: invalidate,
  })
}

export function usePostAdjustment(clientId: string) {
  const invalidate = useInvalidateInventory(clientId)
  return useMutation({
    mutationFn: (input: {
      itemId: string
      date: string
      qtyDelta: number
      unitCost: number | null
      accountId: string
      memo: string
    }) => postAdjustment(clientId, input),
    onSuccess: invalidate,
  })
}
