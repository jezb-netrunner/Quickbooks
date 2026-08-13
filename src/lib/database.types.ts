// Database types for the Phase 1 schema.
//
// Hand-maintained for now (the local Supabase stack cannot run in every
// environment); regenerate with `npm run gen:types` against a running local
// stack whenever a migration changes the schema, and refresh in the same PR.

export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type MembershipRole = 'firm_admin' | 'reviewer' | 'staff' | 'client_viewer'
export type ReportingBasis = 'accrual' | 'cash'
export type AccountType = 'asset' | 'liability' | 'equity' | 'income' | 'expense'
export type NormalBalance = 'debit' | 'credit'
export type PeriodStatus = 'open' | 'closed' | 'locked'
export type EntryStatus = 'draft' | 'posted'
export type ContactType = 'customer' | 'vendor' | 'both'
export type DocType = 'invoice' | 'bill' | 'receipt' | 'disbursement' | 'purchase' | 'expense'
export type DocStatus = 'draft' | 'issued' | 'voided'
export type TaxRegime = 'vat' | 'non_vat'
export type TaxKind = 'output_vat' | 'input_vat' | 'withholding_sales' | 'withholding_purchases'
export type VatClass = 'taxable' | 'zero_rated' | 'exempt'

export interface Database {
  public: {
    Tables: {
      profiles: {
        Row: {
          user_id: string
          email: string
          full_name: string
          created_at: string
          updated_at: string
        }
        Insert: never
        Update: { full_name?: string }
        Relationships: []
      }
      firms: {
        Row: {
          id: string
          name: string
          created_by: string
          created_at: string
          updated_at: string
        }
        Insert: never
        Update: { name?: string }
        Relationships: []
      }
      clients: {
        Row: {
          id: string
          firm_id: string
          name: string
          code: string | null
          tin: string | null
          reporting_basis: ReportingBasis
          fiscal_year_end_month: number
          functional_currency: string
          archived_at: string | null
          created_by: string
          created_at: string
          updated_at: string
        }
        Insert: {
          firm_id: string
          name: string
          code?: string | null
          tin?: string | null
          reporting_basis?: ReportingBasis
          fiscal_year_end_month?: number
        }
        Update: {
          name?: string
          code?: string | null
          tin?: string | null
          reporting_basis?: ReportingBasis
          fiscal_year_end_month?: number
          archived_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: 'clients_firm_id_fkey'
            columns: ['firm_id']
            isOneToOne: false
            referencedRelation: 'firms'
            referencedColumns: ['id']
          },
        ]
      }
      memberships: {
        Row: {
          id: string
          firm_id: string
          user_id: string
          role: MembershipRole
          has_all_clients: boolean
          client_id: string | null
          created_by: string | null
          created_at: string
          updated_at: string
        }
        Insert: never
        Update: never
        Relationships: [
          {
            foreignKeyName: 'memberships_firm_id_fkey'
            columns: ['firm_id']
            isOneToOne: false
            referencedRelation: 'firms'
            referencedColumns: ['id']
          },
          {
            foreignKeyName: 'memberships_user_id_fkey'
            columns: ['user_id']
            isOneToOne: false
            referencedRelation: 'profiles'
            referencedColumns: ['user_id']
          },
        ]
      }
      client_assignments: {
        Row: {
          membership_id: string
          firm_id: string
          client_id: string
          created_by: string | null
          created_at: string
        }
        Insert: never
        Update: never
        Relationships: [
          {
            foreignKeyName: 'client_assignments_membership_id_firm_id_fkey'
            columns: ['membership_id', 'firm_id']
            isOneToOne: false
            referencedRelation: 'memberships'
            referencedColumns: ['id', 'firm_id']
          },
        ]
      }
      audit_log: {
        Row: {
          id: number
          occurred_at: string
          actor_id: string | null
          firm_id: string
          client_id: string | null
          table_name: string
          record_id: string
          action: 'insert' | 'update' | 'delete'
          changes: Json | null
        }
        Insert: never
        Update: never
        Relationships: []
      }
      accounts: {
        Row: {
          id: string
          client_id: string
          code: string
          name: string
          account_type: AccountType
          normal_balance: NormalBalance
          parent_id: string | null
          archived_at: string | null
          created_by: string | null
          created_at: string
          updated_at: string
        }
        Insert: {
          client_id: string
          code: string
          name: string
          account_type: AccountType
          normal_balance: NormalBalance
          parent_id?: string | null
        }
        Update: {
          code?: string
          name?: string
          parent_id?: string | null
          archived_at?: string | null
        }
        Relationships: []
      }
      dimensions: {
        Row: {
          id: string
          client_id: string
          name: string
          archived_at: string | null
          created_by: string | null
          created_at: string
          updated_at: string
        }
        Insert: { client_id: string; name: string }
        Update: { name?: string; archived_at?: string | null }
        Relationships: []
      }
      coa_template: {
        Row: {
          code: string
          name: string
          account_type: AccountType
          normal_balance: NormalBalance
          parent_code: string | null
          sort_order: number
        }
        Insert: never
        Update: never
        Relationships: []
      }
      periods: {
        Row: {
          id: string
          client_id: string
          period_start: string
          period_end: string
          status: PeriodStatus
          created_at: string
          updated_at: string
        }
        Insert: never
        Update: never
        Relationships: []
      }
      journal_entries: {
        Row: {
          id: string
          client_id: string
          entry_no: number | null
          entry_date: string
          period_id: string | null
          status: EntryStatus
          source_type: 'manual' | 'opening_balance' | 'reversal'
          memo: string
          reversal_of: string | null
          reversed_by: string | null
          created_by: string | null
          posted_by: string | null
          posted_at: string | null
          created_at: string
          updated_at: string
        }
        Insert: { client_id: string; entry_date: string; memo?: string }
        Update: { entry_date?: string; memo?: string }
        Relationships: []
      }
      contacts: {
        Row: {
          id: string
          client_id: string
          name: string
          contact_type: ContactType
          tin: string | null
          email: string | null
          archived_at: string | null
          created_by: string | null
          created_at: string
          updated_at: string
        }
        Insert: {
          client_id: string
          name: string
          contact_type: ContactType
          tin?: string | null
          email?: string | null
        }
        Update: {
          name?: string
          contact_type?: ContactType
          tin?: string | null
          email?: string | null
          archived_at?: string | null
        }
        Relationships: []
      }
      documents: {
        Row: {
          id: string
          client_id: string
          doc_type: DocType
          doc_no: number | null
          doc_date: string
          due_date: string | null
          contact_id: string
          bank_account_id: string | null
          memo: string
          status: DocStatus
          entry_id: string | null
          voided_at: string | null
          amounts_include_tax: boolean
          wht_tax_code_id: string | null
          wht_base: string | null
          created_by: string | null
          created_at: string
          updated_at: string
        }
        Insert: {
          client_id: string
          doc_type: DocType
          doc_date: string
          due_date?: string | null
          contact_id: string
          bank_account_id?: string | null
          memo?: string
          amounts_include_tax?: boolean
          wht_tax_code_id?: string | null
          wht_base?: number | string | null
        }
        Update: {
          doc_date?: string
          due_date?: string | null
          contact_id?: string
          bank_account_id?: string | null
          memo?: string
          amounts_include_tax?: boolean
          wht_tax_code_id?: string | null
          wht_base?: number | string | null
        }
        Relationships: [
          {
            foreignKeyName: 'documents_contact_id_client_id_fkey'
            columns: ['contact_id', 'client_id']
            isOneToOne: false
            referencedRelation: 'contacts'
            referencedColumns: ['id', 'client_id']
          },
        ]
      }
      document_lines: {
        Row: {
          id: string
          document_id: string
          client_id: string
          line_no: number
          account_id: string
          description: string
          amount: string
          tax_code_id: string | null
          item_id: string | null
          qty: string | null
        }
        Insert: {
          document_id: string
          client_id: string
          line_no: number
          account_id: string
          description?: string
          amount: number | string
          tax_code_id?: string | null
          item_id?: string | null
          qty?: number | string | null
        }
        Update: {
          line_no?: number
          account_id?: string
          description?: string
          amount?: number | string
          tax_code_id?: string | null
          item_id?: string | null
          qty?: number | string | null
        }
        Relationships: []
      }
      items: {
        Row: {
          id: string
          client_id: string
          sku: string
          name: string
          uom: string
          income_account_id: string | null
          sales_price: string | null
          purchase_cost: string | null
          archived_at: string | null
          created_by: string | null
          created_at: string
          updated_at: string
        }
        Insert: {
          client_id: string
          sku: string
          name: string
          uom?: string
          income_account_id?: string | null
          sales_price?: number | string | null
          purchase_cost?: number | string | null
        }
        Update: {
          sku?: string
          name?: string
          uom?: string
          income_account_id?: string | null
          sales_price?: number | string | null
          purchase_cost?: number | string | null
          archived_at?: string | null
        }
        Relationships: []
      }
      inventory_layers: {
        Row: {
          id: string
          client_id: string
          item_id: string
          acquired_date: string
          qty_in: string
          qty_remaining: string
          unit_cost: string
          cost_total: string
          source_document_id: string | null
          source_adjustment_id: string | null
          created_at: string
        }
        Insert: never
        Update: never
        Relationships: []
      }
      layer_consumptions: {
        Row: {
          id: string
          client_id: string
          layer_id: string
          document_id: string | null
          adjustment_id: string | null
          move_date: string
          qty: string
          cost: string
          created_at: string
        }
        Insert: never
        Update: never
        Relationships: []
      }
      stock_adjustments: {
        Row: {
          id: string
          client_id: string
          item_id: string
          adj_date: string
          qty_delta: string
          unit_cost: string | null
          account_id: string
          memo: string
          entry_id: string | null
          created_by: string | null
          created_at: string
        }
        Insert: never
        Update: never
        Relationships: []
      }
      client_tax_profiles: {
        Row: {
          client_id: string
          regime: TaxRegime
          updated_at: string
        }
        Insert: { client_id: string; regime: TaxRegime }
        Update: { regime?: TaxRegime }
        Relationships: []
      }
      tax_codes: {
        Row: {
          id: string
          client_id: string
          code: string
          name: string
          kind: TaxKind
          vat_class: VatClass | null
          account_code: string
          atc: string
          active: boolean
          created_by: string | null
          created_at: string
          updated_at: string
        }
        Insert: {
          client_id: string
          code: string
          name: string
          kind: TaxKind
          vat_class?: VatClass | null
          account_code: string
          atc?: string
          active?: boolean
        }
        Update: {
          name?: string
          vat_class?: VatClass | null
          account_code?: string
          atc?: string
          active?: boolean
        }
        Relationships: []
      }
      tax_code_rates: {
        Row: {
          id: string
          tax_code_id: string
          client_id: string
          effective_from: string
          rate: string
          created_at: string
        }
        Insert: {
          tax_code_id: string
          client_id: string
          effective_from: string
          rate: number | string
        }
        Update: {
          effective_from?: string
          rate?: number | string
        }
        Relationships: []
      }
      document_taxes: {
        Row: {
          id: string
          document_id: string
          client_id: string
          tax_code_id: string
          base: string
          amount: string
        }
        Insert: never
        Update: never
        Relationships: []
      }
      document_applications: {
        Row: {
          id: string
          client_id: string
          paying_document_id: string
          target_document_id: string
          amount: string
        }
        Insert: {
          client_id: string
          paying_document_id: string
          target_document_id: string
          amount: number | string
        }
        Update: { amount?: number | string }
        Relationships: []
      }
      journal_lines: {
        Row: {
          id: string
          entry_id: string
          client_id: string
          line_no: number
          account_id: string
          debit: string
          credit: string
          dimension_id: string | null
        }
        Insert: {
          entry_id: string
          client_id: string
          line_no: number
          account_id: string
          debit?: number | string
          credit?: number | string
          dimension_id?: string | null
        }
        Update: {
          line_no?: number
          account_id?: string
          debit?: number | string
          credit?: number | string
          dimension_id?: string | null
        }
        Relationships: []
      }
    }
    Views: Record<string, never>
    Functions: {
      create_firm: {
        Args: { p_name: string }
        Returns: string
      }
      add_member: {
        Args: {
          p_firm_id: string
          p_email: string
          p_role: MembershipRole
          p_client_id?: string | null
          p_has_all_clients?: boolean
        }
        Returns: string
      }
      update_member: {
        Args: {
          p_membership_id: string
          p_role: MembershipRole
          p_has_all_clients: boolean
          p_client_id?: string | null
        }
        Returns: undefined
      }
      remove_member: {
        Args: { p_membership_id: string }
        Returns: undefined
      }
      set_client_assignments: {
        Args: { p_membership_id: string; p_client_ids: string[] }
        Returns: undefined
      }
      seed_client_coa: {
        Args: { p_client_id: string }
        Returns: number
      }
      close_period: {
        Args: { p_period_id: string }
        Returns: undefined
      }
      reopen_period: {
        Args: { p_period_id: string }
        Returns: undefined
      }
      lock_period: {
        Args: { p_period_id: string }
        Returns: undefined
      }
      post_entry: {
        Args: { p_entry_id: string }
        Returns: number
      }
      reverse_entry: {
        Args: { p_entry_id: string; p_date?: string | null; p_memo?: string | null }
        Returns: string
      }
      issue_document: {
        Args: { p_document_id: string }
        Returns: number
      }
      void_document: {
        Args: { p_document_id: string; p_date?: string | null }
        Returns: undefined
      }
      open_items: {
        Args: { p_client_id: string; p_doc_type: string; p_as_of: string }
        Returns: {
          document_id: string
          doc_type: string
          doc_no: number
          doc_date: string
          due_date: string | null
          contact_id: string
          contact_name: string
          total: string
          applied: string
          balance: string
          days_overdue: number
        }[]
      }
      aging: {
        Args: { p_client_id: string; p_doc_type: string; p_as_of: string }
        Returns: {
          contact_id: string
          contact_name: string
          current_amount: string
          days_1_30: string
          days_31_60: string
          days_61_90: string
          days_over_90: string
          total: string
        }[]
      }
      client_dashboard: {
        Args: { p_client_id: string }
        Returns: Json
      }
      trial_balance: {
        Args: { p_client_id: string; p_date_from: string; p_date_to: string }
        Returns: {
          account_id: string
          code: string
          name: string
          account_type: AccountType
          normal_balance: NormalBalance
          total_debit: string
          total_credit: string
        }[]
      }
      profit_and_loss: {
        Args: { p_client_id: string; p_date_from: string; p_date_to: string }
        Returns: {
          account_type: string
          code: string
          name: string
          amount: string
        }[]
      }
      balance_sheet: {
        Args: { p_client_id: string; p_as_of: string }
        Returns: {
          account_type: string
          code: string
          name: string
          balance: string
        }[]
      }
      cash_flow_indirect: {
        Args: { p_client_id: string; p_date_from: string; p_date_to: string }
        Returns: {
          section: string
          label: string
          amount: string
        }[]
      }
      general_ledger: {
        Args: { p_client_id: string; p_account_id: string; p_date_from: string; p_date_to: string }
        Returns: {
          entry_id: string | null
          entry_no: number | null
          entry_date: string
          memo: string
          source_type: string
          debit: string
          credit: string
          running: string
        }[]
      }
      seed_client_tax_codes: {
        Args: { p_client_id: string; p_regime: string }
        Returns: undefined
      }
      sales_book: {
        Args: { p_client_id: string; p_date_from: string; p_date_to: string }
        Returns: {
          doc_date: string
          doc_no: number
          customer: string
          tin: string
          status: string
          gross: string
          exempt: string
          zero_rated: string
          taxable: string
          output_vat: string
        }[]
      }
      purchases_book: {
        Args: { p_client_id: string; p_date_from: string; p_date_to: string }
        Returns: {
          doc_date: string
          ref: string
          supplier: string
          tin: string
          status: string
          gross: string
          exempt: string
          taxable: string
          input_vat: string
        }[]
      }
      cash_receipts_book: {
        Args: { p_client_id: string; p_date_from: string; p_date_to: string }
        Returns: {
          entry_date: string
          entry_no: number
          source_type: string
          memo: string
          cash: string
          cwt: string
          ar_credit: string
          sales: string
          output_vat: string
          sundry_debit: string
          sundry_credit: string
        }[]
      }
      cash_disbursements_book: {
        Args: { p_client_id: string; p_date_from: string; p_date_to: string }
        Returns: {
          entry_date: string
          entry_no: number
          source_type: string
          memo: string
          cash: string
          ap_debit: string
          purchases: string
          input_vat: string
          ewt: string
          sundry_debit: string
          sundry_credit: string
        }[]
      }
      general_journal_book: {
        Args: { p_client_id: string; p_date_from: string; p_date_to: string }
        Returns: {
          entry_date: string
          entry_no: number
          source_type: string
          memo: string
          line_no: number
          code: string
          account: string
          debit: string
          credit: string
        }[]
      }
      post_stock_adjustment: {
        Args: {
          p_client_id: string
          p_item_id: string
          p_date: string
          p_qty_delta: number
          p_unit_cost?: number | null
          p_account_id?: string | null
          p_memo?: string
        }
        Returns: string
      }
      inventory_valuation: {
        Args: { p_client_id: string }
        Returns: {
          item_id: string
          sku: string
          name: string
          uom: string
          qty_on_hand: string
          value: string
          avg_cost: string
        }[]
      }
      stock_card: {
        Args: { p_client_id: string; p_item_id: string; p_date_from: string; p_date_to: string }
        Returns: {
          move_date: string
          ref: string
          memo: string
          qty_in: string
          qty_out: string
          cost: string
          running_qty: string
          running_value: string
        }[]
      }
    }
    Enums: Record<string, never>
    CompositeTypes: Record<string, never>
  }
}

export type Client = Database['public']['Tables']['clients']['Row']
export type Firm = Database['public']['Tables']['firms']['Row']
export type Membership = Database['public']['Tables']['memberships']['Row']
export type Profile = Database['public']['Tables']['profiles']['Row']
export type ClientAssignment = Database['public']['Tables']['client_assignments']['Row']
export type Account = Database['public']['Tables']['accounts']['Row']
export type Period = Database['public']['Tables']['periods']['Row']
export type JournalEntry = Database['public']['Tables']['journal_entries']['Row']
export type JournalLine = Database['public']['Tables']['journal_lines']['Row']
export type TrialBalanceRow = Database['public']['Functions']['trial_balance']['Returns'][number]
export type Contact = Database['public']['Tables']['contacts']['Row']
export type DocumentRow = Database['public']['Tables']['documents']['Row']
export type DocumentLine = Database['public']['Tables']['document_lines']['Row']
export type DocumentApplication = Database['public']['Tables']['document_applications']['Row']
export type OpenItemRow = Database['public']['Functions']['open_items']['Returns'][number]
export type AgingRow = Database['public']['Functions']['aging']['Returns'][number]
export type PnlRow = Database['public']['Functions']['profit_and_loss']['Returns'][number]
export type BalanceSheetRow = Database['public']['Functions']['balance_sheet']['Returns'][number]
export type CashFlowRow = Database['public']['Functions']['cash_flow_indirect']['Returns'][number]
export type GeneralLedgerRow = Database['public']['Functions']['general_ledger']['Returns'][number]
export type ClientTaxProfile = Database['public']['Tables']['client_tax_profiles']['Row']
export type TaxCode = Database['public']['Tables']['tax_codes']['Row']
export type TaxCodeRate = Database['public']['Tables']['tax_code_rates']['Row']
export type Item = Database['public']['Tables']['items']['Row']
export type StockAdjustment = Database['public']['Tables']['stock_adjustments']['Row']
export type InventoryValuationRow = Database['public']['Functions']['inventory_valuation']['Returns'][number]
export type StockCardRow = Database['public']['Functions']['stock_card']['Returns'][number]
export type SalesBookRow = Database['public']['Functions']['sales_book']['Returns'][number]
export type PurchasesBookRow = Database['public']['Functions']['purchases_book']['Returns'][number]
export type CashReceiptsBookRow = Database['public']['Functions']['cash_receipts_book']['Returns'][number]
export type CashDisbursementsBookRow = Database['public']['Functions']['cash_disbursements_book']['Returns'][number]
export type GeneralJournalBookRow = Database['public']['Functions']['general_journal_book']['Returns'][number]
