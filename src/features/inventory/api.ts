import { supabase } from '@/lib/supabase'
import type {
  InventoryValuationRow,
  Item,
  StockAdjustment,
  StockCardRow,
} from '@/lib/database.types'

export async function fetchItems(clientId: string): Promise<Item[]> {
  const { data, error } = await supabase
    .from('items')
    .select('*')
    .eq('client_id', clientId)
    .order('sku')
  if (error) throw error
  return data
}

export interface ItemInput {
  sku: string
  name: string
  uom: string
  income_account_id: string | null
  sales_price: number | null
  purchase_cost: number | null
}

export async function createItem(clientId: string, input: ItemInput): Promise<void> {
  const { error } = await supabase.from('items').insert({ client_id: clientId, ...input })
  if (error) throw error
}

export async function updateItem(
  id: string,
  patch: Partial<ItemInput> & { archived_at?: string | null },
): Promise<void> {
  const { error } = await supabase.from('items').update(patch).eq('id', id)
  if (error) throw error
}

export async function fetchValuation(clientId: string): Promise<InventoryValuationRow[]> {
  const { data, error } = await supabase.rpc('inventory_valuation', { p_client_id: clientId })
  if (error) throw error
  return data
}

export async function fetchStockCard(
  clientId: string,
  itemId: string,
  from: string,
  to: string,
): Promise<StockCardRow[]> {
  const { data, error } = await supabase.rpc('stock_card', {
    p_client_id: clientId,
    p_item_id: itemId,
    p_date_from: from,
    p_date_to: to,
  })
  if (error) throw error
  return data
}

export async function fetchAdjustments(clientId: string): Promise<StockAdjustment[]> {
  const { data, error } = await supabase
    .from('stock_adjustments')
    .select('*')
    .eq('client_id', clientId)
    .order('created_at', { ascending: false })
    .limit(200)
  if (error) throw error
  return data
}

export async function postAdjustment(
  clientId: string,
  input: {
    itemId: string
    date: string
    qtyDelta: number
    unitCost: number | null
    accountId: string
    memo: string
  },
): Promise<void> {
  const { error } = await supabase.rpc('post_stock_adjustment', {
    p_client_id: clientId,
    p_item_id: input.itemId,
    p_date: input.date,
    p_qty_delta: input.qtyDelta,
    p_unit_cost: input.unitCost,
    p_account_id: input.accountId,
    p_memo: input.memo,
  })
  if (error) throw error
}
