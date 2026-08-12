-- Phase 4: financial statements and GL drill-down — plus a hardening of the
-- document engine that field testing exposed: an invoice line could point at
-- the AR control account itself, posting AR-against-AR (an open subledger item
-- with no income ever recognized). Control accounts are now rejected as
-- document line accounts at the issuing gate, not just discouraged by the UI.

create or replace function app.assert_lines_avoid_control(p_document_id uuid, p_client_id uuid) returns void
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.document_lines l
    join public.accounts a on a.id = l.account_id
    where l.document_id = p_document_id
      and a.code in ('1100', '2000')
  ) then
    raise exception 'document lines cannot use the receivable or payable control accounts — those sides post automatically';
  end if;
end $$;

-- Re-create issue_document with the control-account guard added to the shape
-- validation. Everything else is unchanged from 20260812001400.
create or replace function public.issue_document(p_document_id uuid) returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
  v_doc record;
  v_total numeric(18,2);
  v_applied numeric(18,2);
  v_ar uuid;
  v_ap uuid;
  v_entry uuid;
  v_no bigint;
  v_line_no smallint := 0;
  r record;
  v_label text;
begin
  select d.* into v_doc from public.documents d where d.id = p_document_id;
  if v_doc.id is null then raise exception 'document not found'; end if;
  if not (select app.can_write_client(v_doc.client_id)) then
    raise exception 'not authorized';
  end if;
  if v_doc.status <> 'draft' then
    raise exception 'only drafts can be issued';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_doc.client_id::text, 2));

  select coalesce(sum(l.amount), 0) into v_total
  from public.document_lines l where l.document_id = p_document_id;
  select coalesce(sum(a.amount), 0) into v_applied
  from public.document_applications a where a.paying_document_id = p_document_id;

  perform app.assert_lines_avoid_control(p_document_id, v_doc.client_id);

  if v_doc.doc_type in ('invoice', 'bill') then
    if v_total <= 0 then raise exception 'add at least one line before issuing'; end if;
    if v_applied > 0 then raise exception 'invoices and bills do not carry applications'; end if;
  elsif v_doc.doc_type in ('receipt', 'disbursement') then
    if v_doc.bank_account_id is null then
      raise exception 'choose the cash or bank account this payment moved through';
    end if;
    if v_applied + v_total <= 0 then
      raise exception 'a payment needs applied documents or direct expense lines';
    end if;
    for r in
      select a.target_document_id, a.amount, t.doc_type as target_type, t.status as target_status
      from public.document_applications a
      join public.documents t on t.id = a.target_document_id
      where a.paying_document_id = p_document_id
    loop
      if r.target_status <> 'issued' then
        raise exception 'applications must target issued documents';
      end if;
      if v_doc.doc_type = 'receipt' and r.target_type <> 'invoice' then
        raise exception 'receipts apply to invoices only';
      end if;
      if v_doc.doc_type = 'disbursement' and r.target_type <> 'bill' then
        raise exception 'disbursements apply to bills only';
      end if;
      if r.amount > (app.document_total(r.target_document_id) - app.document_applied(r.target_document_id)) then
        raise exception 'application exceeds the open balance of the target document';
      end if;
    end loop;
    if v_doc.doc_type = 'receipt' and v_total > 0 then
      raise exception 'receipts settle invoices — use a journal entry for other collections';
    end if;
  end if;

  v_label := initcap(v_doc.doc_type);
  insert into public.journal_entries (client_id, entry_date, source_type, memo, created_by)
  values (
    v_doc.client_id, v_doc.doc_date, v_doc.doc_type,
    v_label || case when v_doc.memo <> '' then ': ' || v_doc.memo else '' end,
    (select auth.uid())
  ) returning id into v_entry;

  if v_doc.doc_type = 'invoice' then
    v_ar := app.control_account(v_doc.client_id, '1100');
    insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
    values (v_entry, v_doc.client_id, 1, v_ar, v_total, 0);
    v_line_no := 1;
    for r in select * from public.document_lines where document_id = p_document_id order by line_no loop
      v_line_no := v_line_no + 1;
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v_doc.client_id, v_line_no, r.account_id, 0, r.amount);
    end loop;

  elsif v_doc.doc_type = 'bill' then
    v_ap := app.control_account(v_doc.client_id, '2000');
    for r in select * from public.document_lines where document_id = p_document_id order by line_no loop
      v_line_no := v_line_no + 1;
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v_doc.client_id, v_line_no, r.account_id, r.amount, 0);
    end loop;
    insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
    values (v_entry, v_doc.client_id, v_line_no + 1, v_ap, 0, v_total);

  elsif v_doc.doc_type = 'receipt' then
    v_ar := app.control_account(v_doc.client_id, '1100');
    insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
    values (v_entry, v_doc.client_id, 1, v_doc.bank_account_id, v_applied, 0),
           (v_entry, v_doc.client_id, 2, v_ar, 0, v_applied);

  elsif v_doc.doc_type = 'disbursement' then
    v_line_no := 0;
    if v_applied > 0 then
      v_ap := app.control_account(v_doc.client_id, '2000');
      v_line_no := v_line_no + 1;
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v_doc.client_id, v_line_no, v_ap, v_applied, 0);
    end if;
    for r in select * from public.document_lines where document_id = p_document_id order by line_no loop
      v_line_no := v_line_no + 1;
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v_doc.client_id, v_line_no, r.account_id, r.amount, 0);
    end loop;
    insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
    values (v_entry, v_doc.client_id, v_line_no + 1, v_doc.bank_account_id, 0, v_applied + v_total);
  end if;

  perform public.post_entry(v_entry);

  select coalesce(max(doc_no), 0) + 1 into v_no
  from public.documents
  where client_id = v_doc.client_id and doc_type = v_doc.doc_type;

  update public.documents
     set status = 'issued', doc_no = v_no, entry_id = v_entry
   where id = p_document_id;

  return v_no;
end $$;

-- ---------------------------------------------------------- P&L
-- SECURITY INVOKER: every statement reads through the caller's RLS.
create or replace function public.profit_and_loss(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (
  account_type text,
  code text,
  name text,
  amount numeric(18,2)
)
language sql stable
set search_path = ''
as $$
  select
    a.account_type,
    a.code,
    a.name,
    (case when a.account_type = 'income'
          then coalesce(sum(l.credit - l.debit), 0)
          else coalesce(sum(l.debit - l.credit), 0) end)::numeric(18,2)
  from public.accounts a
  join public.journal_lines l on l.account_id = a.id
  join public.journal_entries e on e.id = l.entry_id
  where a.client_id = p_client_id
    and a.account_type in ('income', 'expense')
    and e.status = 'posted'
    and e.entry_date between p_date_from and p_date_to
  group by a.account_type, a.code, a.name
  having coalesce(sum(l.credit - l.debit), 0) <> 0 or coalesce(sum(l.debit - l.credit), 0) <> 0
  order by a.account_type desc, a.code   -- income first, then expenses
$$;

-- ---------------------------------------------------------- balance sheet
-- Cumulative balances through the as-of date. No closing entries exist, so
-- lifetime earnings appear as one synthetic equity row — that is what makes
-- assets equal liabilities plus equity.
create or replace function public.balance_sheet(
  p_client_id uuid,
  p_as_of date
) returns table (
  account_type text,
  code text,
  name text,
  balance numeric(18,2)
)
language sql stable
set search_path = ''
as $$
  with movement as (
    select a.account_type, a.code, a.name,
           (case when a.account_type = 'asset'
                 then sum(l.debit - l.credit)
                 else sum(l.credit - l.debit) end)::numeric(18,2) as balance
    from public.accounts a
    join public.journal_lines l on l.account_id = a.id
    join public.journal_entries e on e.id = l.entry_id
    where a.client_id = p_client_id
      and a.account_type in ('asset', 'liability', 'equity')
      and e.status = 'posted'
      and e.entry_date <= p_as_of
    group by a.account_type, a.code, a.name
  ),
  earnings as (
    -- credit - debit works for both types: income accumulates as credit,
    -- expenses as debit, so the sum IS income minus expenses.
    select coalesce(sum(l.credit - l.debit), 0)::numeric(18,2) as amount
    from public.journal_lines l
    join public.journal_entries e on e.id = l.entry_id
    join public.accounts a on a.id = l.account_id
    where a.client_id = p_client_id
      and a.account_type in ('income', 'expense')
      and e.status = 'posted'
      and e.entry_date <= p_as_of
  )
  select m.account_type, m.code, m.name, m.balance from movement m where m.balance <> 0
  union all
  select 'equity', '3999', 'Cumulative earnings', amount from earnings where amount <> 0
  order by 1, 2
$$;

-- ---------------------------------------------------------- cash flow (indirect)
-- Classification by chart structure, documented and deliberately simple until
-- the Phase 5 tax layer introduces richer account metadata:
--   operating: net income, plus movements in 11xx-14xx assets (sign flipped),
--              1510 accumulated depreciation, and 20xx-23xx liabilities
--   investing: movements in 15xx-16xx assets except 1510
--   financing: movements in 24xx liabilities and 3xxx equity accounts
-- The statement reconciles to the actual change in 1000-series cash accounts.
create or replace function public.cash_flow_indirect(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (
  section text,
  label text,
  amount numeric(18,2)
)
language sql stable
set search_path = ''
as $$
  with period_lines as (
    select l.account_id, l.debit, l.credit
    from public.journal_lines l
    join public.journal_entries e on e.id = l.entry_id
    where e.client_id = p_client_id
      and e.status = 'posted'
      and e.entry_date between p_date_from and p_date_to
  ),
  net_income as (
    select coalesce(sum(pl.credit - pl.debit), 0)::numeric(18,2) as amount
    from period_lines pl
    join public.accounts a on a.id = pl.account_id
    where a.account_type in ('income', 'expense')
  ),
  deltas as (
    select a.code, a.name, a.account_type,
           sum(pl.debit - pl.credit)::numeric(18,2) as debit_delta
    from period_lines pl
    join public.accounts a on a.id = pl.account_id
    where a.account_type in ('asset', 'liability', 'equity')
    group by a.code, a.name, a.account_type
    having sum(pl.debit - pl.credit) <> 0
  ),
  classified as (
    select
      case
        when code like '1000%' then 'cash'
        when code = '1510' then 'operating'
        when account_type = 'asset' and code >= '1100' and code < '1500' then 'operating'
        when account_type = 'asset' then 'investing'
        when account_type = 'liability' and code < '2400' then 'operating'
        when account_type = 'liability' then 'financing'
        else 'financing'
      end as section,
      name,
      -- cash impact: an asset increase consumes cash; a liability/equity
      -- increase provides cash. debit_delta is the debit-side movement.
      (-debit_delta)::numeric(18,2) as amount
    from deltas
  )
  select 'operating', 'Net income', (select amount from net_income)
  union all
  select c.section, c.name, c.amount from classified c where c.section <> 'cash'
  union all
  select 'cash', 'Net change in cash',
         coalesce((select sum(d.debit_delta) from deltas d where d.code like '1000%'), 0)
$$;

-- ---------------------------------------------------------- GL drill-down
create or replace function public.general_ledger(
  p_client_id uuid,
  p_account_id uuid,
  p_date_from date,
  p_date_to date
) returns table (
  entry_id uuid,
  entry_no bigint,
  entry_date date,
  memo text,
  source_type text,
  debit numeric(18,2),
  credit numeric(18,2),
  running numeric(18,2)
)
language sql stable
set search_path = ''
as $$
  with opening as (
    select coalesce(sum(l.debit - l.credit), 0)::numeric(18,2) as amount
    from public.journal_lines l
    join public.journal_entries e on e.id = l.entry_id
    where e.client_id = p_client_id
      and l.account_id = p_account_id
      and e.status = 'posted'
      and e.entry_date < p_date_from
  ),
  movements as (
    select e.id, e.entry_no, e.entry_date, e.memo, e.source_type,
           sum(l.debit)::numeric(18,2) as debit,
           sum(l.credit)::numeric(18,2) as credit
    from public.journal_lines l
    join public.journal_entries e on e.id = l.entry_id
    where e.client_id = p_client_id
      and l.account_id = p_account_id
      and e.status = 'posted'
      and e.entry_date between p_date_from and p_date_to
    group by e.id, e.entry_no, e.entry_date, e.memo, e.source_type
  )
  select null::uuid, null::bigint, p_date_from, 'Opening balance', 'opening',
         0::numeric(18,2), 0::numeric(18,2), o.amount
  from opening o
  union all
  select m.id, m.entry_no, m.entry_date, m.memo, m.source_type, m.debit, m.credit,
         ((select amount from opening)
          + sum(m.debit - m.credit) over (order by m.entry_date, m.entry_no))::numeric(18,2)
  from movements m
  order by 3, 2 nulls first
$$;

-- Field-test fix for the dashboard's 12-month net series: the original
-- expression added expenses to income instead of subtracting them. credit -
-- debit across income+expense accounts is the correct net. Everything else in
-- client_dashboard is unchanged from 20260812001400.
create or replace function public.client_dashboard(p_client_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  with posted_lines as (
    select l.account_id, l.debit, l.credit, e.entry_date
    from public.journal_lines l
    join public.journal_entries e on e.id = l.entry_id
    where e.client_id = p_client_id and e.status = 'posted'
  ),
  cash as (
    select coalesce(sum(pl.debit - pl.credit), 0)::numeric(18,2) as balance
    from posted_lines pl
    join public.accounts a on a.id = pl.account_id
    where a.client_id = p_client_id and a.code like '1000%'
  ),
  mtd as (
    select
      coalesce(sum(case when a.account_type = 'income' then pl.credit - pl.debit end), 0)::numeric(18,2) as income,
      coalesce(sum(case when a.account_type = 'expense' then pl.debit - pl.credit end), 0)::numeric(18,2) as expense
    from posted_lines pl
    join public.accounts a on a.id = pl.account_id
    where pl.entry_date >= date_trunc('month', current_date)::date
  ),
  series as (
    select coalesce(jsonb_agg(jsonb_build_object('month', m.month, 'net', m.net) order by m.month), '[]'::jsonb) as months
    from (
      select to_char(date_trunc('month', pl.entry_date), 'YYYY-MM') as month,
             sum(pl.credit - pl.debit)::numeric(18,2) as net
      from posted_lines pl
      join public.accounts a on a.id = pl.account_id
      where a.account_type in ('income', 'expense')
        and pl.entry_date >= (date_trunc('month', current_date) - interval '11 months')::date
      group by 1
    ) m
  ),
  ar as (
    select coalesce(sum(balance), 0)::numeric(18,2) as open_total,
           coalesce(sum(balance) filter (where days_overdue > 0), 0)::numeric(18,2) as overdue_total,
           count(*) filter (where days_overdue > 0) as overdue_count
    from public.open_items(p_client_id, 'invoice', current_date)
  ),
  ap as (
    select coalesce(sum(balance), 0)::numeric(18,2) as open_total
    from public.open_items(p_client_id, 'bill', current_date)
  ),
  attention as (
    select
      (select count(*) from public.journal_entries e
        where e.client_id = p_client_id and e.status = 'draft') as draft_entries,
      (select count(*) from public.documents d
        where d.client_id = p_client_id and d.status = 'draft') as draft_documents
  ),
  recent as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'entry_no', e.entry_no, 'entry_date', e.entry_date, 'memo', e.memo,
             'source_type', e.source_type,
             'amount', (select sum(l.debit) from public.journal_lines l where l.entry_id = e.id)
           ) order by e.posted_at desc), '[]'::jsonb) as items
    from (
      select * from public.journal_entries e
      where e.client_id = p_client_id and e.status = 'posted'
      order by e.posted_at desc limit 8
    ) e
  )
  select jsonb_build_object(
    'cash', (select balance from cash),
    'income_mtd', (select income from mtd),
    'expense_mtd', (select expense from mtd),
    'net_series', (select months from series),
    'ar_open', (select open_total from ar),
    'ar_overdue', (select overdue_total from ar),
    'ar_overdue_count', (select overdue_count from ar),
    'ap_open', (select open_total from ap),
    'draft_entries', (select draft_entries from attention),
    'draft_documents', (select draft_documents from attention),
    'recent', (select items from recent)
  )
$$;

revoke all on function
  public.profit_and_loss(uuid, date, date),
  public.balance_sheet(uuid, date),
  public.cash_flow_indirect(uuid, date, date),
  public.general_ledger(uuid, uuid, date, date)
from public, anon, authenticated;
grant execute on function
  public.profit_and_loss(uuid, date, date),
  public.balance_sheet(uuid, date),
  public.cash_flow_indirect(uuid, date, date),
  public.general_ledger(uuid, uuid, date, date)
to authenticated;
