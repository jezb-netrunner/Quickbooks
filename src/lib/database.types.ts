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
