import type { DocType, TaxKind } from '@/lib/database.types'

// One config drives all six document screens, grouped by transaction cycle:
// Sales carries invoices and collections; Purchases carries purchases (goods
// arriving, the FIFO entry point), bills, expenses (directly-paid costs), and
// payments (settling payables). "Collections" and "Payments" only ever touch
// AR/AP — general cash movements live in Cash & banking.
export interface DocTypeConfig {
  type: DocType
  title: string
  subtitle: string
  noun: string
  prefix: string
  /** Which side of the contact list this document draws from. */
  contactSide: 'customer' | 'vendor'
  hasLines: boolean
  hasDueDate: boolean
  hasBank: boolean
  /** Payments settle open items of this side. */
  appliesTo: 'receivable' | 'payable' | null
  lineHint: string
  /**
   * Account types offered for document lines. The AR/AP control accounts are
   * always excluded — the engine posts those sides itself (and rejects them
   * server-side since 20260812001500).
   */
  lineAccountTypes: string[]
  /** Which tax-code kind may tag this document's lines (null: no tax column). */
  lineTaxKind: TaxKind | null
  /** Which withholding kind this payment document accepts (null: none). */
  whtKind: TaxKind | null
  /**
   * Invoices and purchases may settle straight to cash at issue (EOPT: the
   * invoice covers cash and credit sales alike) — shows the settlement
   * selector with these labels.
   */
  hasSettlement: boolean
  settleOnAccountLabel: string
  settleCashLabel: string
  /** Item + qty columns on lines (inventory flows: invoice out, purchase in). */
  hasItems: boolean
}

export const DOC_TYPES: Record<DocType, DocTypeConfig> = {
  invoice: {
    type: 'invoice',
    title: 'Sales invoices',
    subtitle: 'Cash or credit sales — item lines relieve stock FIFO and book cost of sales',
    noun: 'invoice',
    prefix: 'INV',
    contactSide: 'customer',
    hasLines: true,
    hasDueDate: true,
    hasBank: false,
    appliesTo: null,
    lineHint: 'What was sold — pick an item for goods, an income account for services',
    lineAccountTypes: ['income'],
    lineTaxKind: 'output_vat',
    whtKind: null,
    hasSettlement: true,
    settleOnAccountLabel: 'On account — receivable',
    settleCashLabel: 'Paid now — cash or bank',
    hasItems: true,
  },
  purchase: {
    type: 'purchase',
    title: 'Purchases / receipts',
    subtitle: 'Goods arriving — item lines create FIFO cost layers and post to inventory',
    noun: 'purchase',
    prefix: 'PR',
    contactSide: 'vendor',
    hasLines: true,
    hasDueDate: true,
    hasBank: false,
    appliesTo: null,
    lineHint: 'Pick an item for stock; non-item lines post to their account (freight, fees)',
    lineAccountTypes: ['expense', 'asset'],
    lineTaxKind: 'input_vat',
    whtKind: null,
    hasSettlement: true,
    settleOnAccountLabel: 'On account — payable',
    settleCashLabel: 'Paid now — cash or bank',
    hasItems: true,
  },
  bill: {
    type: 'bill',
    title: 'Bills',
    subtitle: 'Non-inventory purchase invoices posting to payables',
    noun: 'bill',
    prefix: 'BILL',
    contactSide: 'vendor',
    hasLines: true,
    hasDueDate: true,
    hasBank: false,
    appliesTo: null,
    lineHint: 'Expense or asset accounts — what was billed',
    lineAccountTypes: ['expense', 'asset'],
    lineTaxKind: 'input_vat',
    whtKind: null,
    hasSettlement: false,
    settleOnAccountLabel: '',
    settleCashLabel: '',
    hasItems: false,
  },
  expense: {
    type: 'expense',
    title: 'Expenses',
    subtitle: 'Directly-paid operating costs — no payable involved, straight from cash',
    noun: 'expense',
    prefix: 'EXP',
    contactSide: 'vendor',
    hasLines: true,
    hasDueDate: false,
    hasBank: true,
    appliesTo: null,
    lineHint: 'Expense accounts — what was paid for',
    lineAccountTypes: ['expense', 'asset'],
    lineTaxKind: 'input_vat',
    whtKind: null,
    hasSettlement: false,
    settleOnAccountLabel: '',
    settleCashLabel: '',
    hasItems: false,
  },
  receipt: {
    type: 'receipt',
    title: 'Collections',
    subtitle: 'Collecting receivables — applies cash to open invoices only',
    noun: 'collection',
    prefix: 'OR',
    contactSide: 'customer',
    hasLines: false,
    hasDueDate: false,
    hasBank: true,
    appliesTo: 'receivable',
    lineHint: '',
    lineAccountTypes: [],
    lineTaxKind: null,
    whtKind: 'withholding_sales',
    hasSettlement: false,
    settleOnAccountLabel: '',
    settleCashLabel: '',
    hasItems: false,
  },
  disbursement: {
    type: 'disbursement',
    title: 'Payments',
    subtitle: 'Settling payables — applies cash to open bills and purchases',
    noun: 'payment',
    prefix: 'CD',
    contactSide: 'vendor',
    hasLines: false,
    hasDueDate: false,
    hasBank: true,
    appliesTo: 'payable',
    lineHint: '',
    lineAccountTypes: [],
    lineTaxKind: null,
    whtKind: 'withholding_purchases',
    hasSettlement: false,
    settleOnAccountLabel: '',
    settleCashLabel: '',
    hasItems: false,
  },
}

export function docLabel(config: DocTypeConfig, docNo: number | null): string {
  return docNo !== null ? `${config.prefix}-${docNo}` : 'Draft'
}

/** Ref label for an open item by its actual doc type (payments settle two types). */
export function openItemRef(docType: string, docNo: number): string {
  const prefix = docType === 'invoice' ? 'INV' : docType === 'purchase' ? 'PR' : 'BILL'
  return `${prefix}-${docNo}`
}
