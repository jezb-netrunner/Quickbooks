import type { DocType, TaxKind } from '@/lib/database.types'

// One config drives all four document screens.
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
  /** Payments settle open items of this target type. */
  appliesTo: 'invoice' | 'bill' | null
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
   * Invoices may settle straight to cash at issue (EOPT: the invoice covers
   * cash and credit sales alike) — shows the settlement selector.
   */
  hasSettlement: boolean
}

export const DOC_TYPES: Record<DocType, DocTypeConfig> = {
  invoice: {
    type: 'invoice',
    title: 'Invoices',
    subtitle: 'Sales invoices post to receivables through the journal',
    noun: 'invoice',
    prefix: 'INV',
    contactSide: 'customer',
    hasLines: true,
    hasDueDate: true,
    hasBank: false,
    appliesTo: null,
    lineHint: 'Income accounts — what was sold',
    lineAccountTypes: ['income'],
    lineTaxKind: 'output_vat',
    whtKind: null,
    hasSettlement: true,
  },
  bill: {
    type: 'bill',
    title: 'Bills',
    subtitle: 'Purchase invoices post to payables through the journal',
    noun: 'bill',
    prefix: 'BILL',
    contactSide: 'vendor',
    hasLines: true,
    hasDueDate: true,
    hasBank: false,
    appliesTo: null,
    lineHint: 'Expense or asset accounts — what was bought',
    lineAccountTypes: ['expense', 'asset'],
    lineTaxKind: 'input_vat',
    whtKind: null,
    hasSettlement: false,
  },
  receipt: {
    type: 'receipt',
    title: 'Money in',
    subtitle: 'Collections applied to open invoices',
    noun: 'receipt',
    prefix: 'OR',
    contactSide: 'customer',
    hasLines: false,
    hasDueDate: false,
    hasBank: true,
    appliesTo: 'invoice',
    lineHint: '',
    lineAccountTypes: [],
    lineTaxKind: null,
    whtKind: 'withholding_sales',
    hasSettlement: false,
  },
  disbursement: {
    type: 'disbursement',
    title: 'Money out',
    subtitle: 'Payments applied to bills, plus direct expenses',
    noun: 'disbursement',
    prefix: 'CD',
    contactSide: 'vendor',
    hasLines: true,
    hasDueDate: false,
    hasBank: true,
    appliesTo: 'bill',
    lineHint: 'Direct expenses paid without a bill (optional)',
    lineAccountTypes: ['expense', 'asset'],
    lineTaxKind: 'input_vat',
    whtKind: 'withholding_purchases',
    hasSettlement: false,
  },
}

export function docLabel(config: DocTypeConfig, docNo: number | null): string {
  return docNo !== null ? `${config.prefix}-${docNo}` : 'Draft'
}
