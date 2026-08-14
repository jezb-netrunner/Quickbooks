-- Phase 3 remediation — accounting integrity (batch 2).
-- Fixes audit finding P3-07.

-- ---------------------------------------------------------------------------
-- P3-07 — trial_balance filtered `a.archived_at is null`, but balance_sheet and
-- profit_and_loss do not, and archiving an account that already has postings is
-- permitted. So after archiving ONE side of a posted entry, that side's lines
-- vanished from the TB while the other side stayed → total_debit <> total_credit
-- (the trial balance itself stopped balancing) and it disagreed with the BS.
-- Fix: keep an account in the TB if it is not archived OR it has posted
-- movements in range, so both sides of every in-range entry are always present.
create or replace function public.trial_balance(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (
  account_id uuid,
  code text,
  name text,
  account_type text,
  normal_balance text,
  total_debit numeric(18,2),
  total_credit numeric(18,2)
)
language sql stable
set search_path = ''
as $$
  select
    a.id,
    a.code,
    a.name,
    a.account_type,
    a.normal_balance,
    coalesce(sum(l.debit), 0)::numeric(18,2),
    coalesce(sum(l.credit), 0)::numeric(18,2)
  from public.accounts a
  left join public.journal_lines l
    on l.account_id = a.id
   and l.entry_id in (
     select e.id from public.journal_entries e
     where e.client_id = p_client_id
       and e.status = 'posted'
       and e.entry_date between p_date_from and p_date_to
   )
  where a.client_id = p_client_id
    and (
      a.archived_at is null
      or exists (
        select 1
        from public.journal_lines l2
        join public.journal_entries e2 on e2.id = l2.entry_id
        where l2.account_id = a.id
          and e2.client_id = p_client_id
          and e2.status = 'posted'
          and e2.entry_date between p_date_from and p_date_to
      )
    )
  group by a.id, a.code, a.name, a.account_type, a.normal_balance
  order by a.code
$$;
