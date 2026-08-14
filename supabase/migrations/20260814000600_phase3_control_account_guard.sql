-- Phase 3 remediation — accounting integrity (batch 4).
-- Fixes audit finding P3-02 (manual JE / bank categorize bypass the
-- control-account guard, desyncing the subledgers and inventory from the GL).
--
-- The document engine, reversals, opening balances, bank imports, and stock
-- adjustments legitimately post to control accounts — so the guard must fire
-- only for the free-form MANUAL journal-entry grid. Manual entries carry
-- source_type='manual'; the one collision was the stock-adjustment RPC, which
-- also used 'manual', so it gets its own tag first.

-- 1) New source tag for stock adjustments (existing 'manual' adjustment rows stay valid).
alter table public.journal_entries drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries add constraint journal_entries_source_type_check
  check (source_type in ('manual', 'opening_balance', 'reversal',
                         'invoice', 'bill', 'receipt', 'disbursement',
                         'purchase', 'expense', 'bank_import', 'inventory_adjustment'));

-- 2) Stock adjustments now tag their entry 'inventory_adjustment' (exempt from the guard).
create or replace function public.post_stock_adjustment(
  p_client_id uuid,
  p_item_id uuid,
  p_date date,
  p_qty_delta numeric,
  p_unit_cost numeric default null,
  p_account_id uuid default null,
  p_memo text default ''
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_adj uuid;
  v_entry uuid;
  v_amount numeric(18,2);
  v_acct_code text;
  v_item_sku text;
begin
  if not (select app.can_write_client(p_client_id)) then
    raise exception 'not authorized';
  end if;
  if p_qty_delta = 0 or p_qty_delta is null then
    raise exception 'the quantity change cannot be zero';
  end if;
  if p_qty_delta > 0 and (p_unit_cost is null or p_unit_cost < 0) then
    raise exception 'a positive adjustment needs the unit cost of the stock being added';
  end if;
  if p_account_id is null then
    raise exception 'choose the account on the other side of the adjustment';
  end if;
  select i.sku into v_item_sku from public.items i
   where i.id = p_item_id and i.client_id = p_client_id;
  if v_item_sku is null then raise exception 'item not found'; end if;
  select a.code into v_acct_code from public.accounts a
   where a.id = p_account_id and a.client_id = p_client_id and a.archived_at is null;
  if v_acct_code is null then
    raise exception 'offset account not found';
  end if;
  if v_acct_code in ('1100', '2000', '1200') or v_acct_code like '1000%' then
    raise exception 'the offset cannot be a control, inventory, or cash account';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_client_id::text, 2));

  insert into public.stock_adjustments
    (client_id, item_id, adj_date, qty_delta, unit_cost, account_id, memo, created_by)
  values (p_client_id, p_item_id, p_date, p_qty_delta, p_unit_cost, p_account_id,
          coalesce(p_memo, ''), (select auth.uid()))
  returning id into v_adj;

  if p_qty_delta > 0 then
    v_amount := round(p_qty_delta * p_unit_cost, 2);
    if v_amount <= 0 then
      raise exception 'the adjustment value computes to zero — raise the unit cost';
    end if;
    insert into public.inventory_layers
      (client_id, item_id, acquired_date, qty_in, qty_remaining, unit_cost, cost_total, source_adjustment_id)
    values (p_client_id, p_item_id, p_date, p_qty_delta, p_qty_delta,
            round(v_amount / p_qty_delta, 6), v_amount, v_adj);
  else
    v_amount := app.consume_fifo(p_client_id, p_item_id, -p_qty_delta, null, v_adj, p_date);
  end if;

  insert into public.journal_entries (client_id, entry_date, source_type, memo, created_by)
  values (p_client_id, p_date, 'inventory_adjustment',
          'Stock adjustment ' || v_item_sku ||
          case when coalesce(p_memo, '') <> '' then ': ' || p_memo else '' end,
          (select auth.uid()))
  returning id into v_entry;

  if p_qty_delta > 0 then
    insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit) values
      (v_entry, p_client_id, 1, app.control_account(p_client_id, '1200'), v_amount, 0),
      (v_entry, p_client_id, 2, p_account_id, 0, v_amount);
  else
    insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit) values
      (v_entry, p_client_id, 1, p_account_id, v_amount, 0),
      (v_entry, p_client_id, 2, app.control_account(p_client_id, '1200'), 0, v_amount);
  end if;

  perform public.post_entry(v_entry);
  update public.stock_adjustments set entry_id = v_entry where id = v_adj;
  return v_adj;
end $$;

-- 3) The posting trigger now blocks a MANUAL entry from touching any control
--    account. This binds on EVERY posting path (post_entry fires it), closing
--    the manual-JE hole that assert_lines_avoid_control (document-only) missed.
create or replace function app.assert_entry_postable() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_debits numeric(18,2);
  v_credits numeric(18,2);
  v_lines int;
  v_period record;
begin
  select coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0), count(*)
    into v_debits, v_credits, v_lines
  from public.journal_lines l
  where l.entry_id = new.id;

  if v_lines < 2 then
    raise exception 'an entry needs at least two lines';
  end if;
  if v_debits <> v_credits then
    raise exception 'entry is out of balance: debits % <> credits %', v_debits, v_credits;
  end if;
  if v_debits = 0 then
    raise exception 'an entry cannot post with zero amounts';
  end if;

  if new.period_id is null then
    raise exception 'posting requires a period';
  end if;
  select p.status, p.period_start, p.period_end into v_period
  from public.periods p where p.id = new.period_id;
  if v_period.status is distinct from 'open' then
    raise exception 'period % to % is % — posting is only allowed into an open period',
      v_period.period_start, v_period.period_end, coalesce(v_period.status, 'missing');
  end if;
  if new.entry_date < v_period.period_start or new.entry_date > v_period.period_end then
    raise exception 'entry date % is outside the posting period', new.entry_date;
  end if;

  if exists (
    select 1 from public.journal_lines l
    join public.accounts a on a.id = l.account_id
    where l.entry_id = new.id and a.archived_at is not null
  ) then
    raise exception 'entry uses an archived account';
  end if;

  -- P3-02: a free-form manual entry must not post to a control account (AR 1100 /
  -- AP 2000 / Inventory 1200 / any tax account). Those subledgers are maintained
  -- by the document engine and stock adjustments; a manual posting to them would
  -- move the GL while open_items / inventory_valuation stay put. Every other
  -- source_type (engine docs, reversal, opening_balance, bank_import,
  -- inventory_adjustment) is exempt because it owns its control-account legs.
  if new.source_type = 'manual' and exists (
    select 1 from public.journal_lines l
    join public.accounts a on a.id = l.account_id
    where l.entry_id = new.id
      and (a.code in ('1100', '2000', '1200')
           or a.code in (select tc.account_code from public.tax_codes tc
                         where tc.client_id = new.client_id))
  ) then
    raise exception 'a manual journal entry cannot post to a control account (receivable, payable, inventory, or tax) — record it as a document or a stock adjustment so the subledger and GL stay in step';
  end if;

  return new;
end $$;

-- 4) bank_categorize blocked 1100/2000/1200 but not tax control accounts
--    (1310/2200/…) — the narrower P3-02 variant. Extend it to tax accounts too.
create or replace function app.bank_categorize(p_txn_id uuid, p_account_id uuid, p_memo text) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v record;
  v_acct record;
  v_entry uuid;
  v_amt numeric(18,2);
begin
  select b.* into v from public.bank_txns b where b.id = p_txn_id;
  if v.id is null then raise exception 'bank line not found'; end if;
  if v.status <> 'pending' then raise exception 'only pending bank lines can be categorized'; end if;
  select a.id, a.code into v_acct from public.accounts a
   where a.id = p_account_id and a.client_id = v.client_id and a.archived_at is null;
  if v_acct.id is null then raise exception 'account not found'; end if;
  if v_acct.id = v.bank_account_id then
    raise exception 'categorize to a different account than the bank line''s own';
  end if;
  if v_acct.code in ('1100', '2000', '1200')
     or v_acct.code in (select tc.account_code from public.tax_codes tc where tc.client_id = v.client_id) then
    raise exception 'control accounts are posted by their own flows — use collections, payments, or purchases';
  end if;

  v_amt := abs(v.amount);
  insert into public.journal_entries (client_id, entry_date, source_type, memo, created_by)
  values (v.client_id, v.txn_date, 'bank_import',
          coalesce(nullif(btrim(p_memo), ''), v.description), (select auth.uid()))
  returning id into v_entry;
  if v.amount > 0 then
    insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit) values
      (v_entry, v.client_id, 1, v.bank_account_id, v_amt, 0),
      (v_entry, v.client_id, 2, p_account_id, 0, v_amt);
  else
    insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit) values
      (v_entry, v.client_id, 1, p_account_id, v_amt, 0),
      (v_entry, v.client_id, 2, v.bank_account_id, 0, v_amt);
  end if;
  perform public.post_entry(v_entry);
  update public.bank_txns
     set status = 'categorized', account_id = p_account_id, entry_id = v_entry
   where id = p_txn_id;
end $$;
