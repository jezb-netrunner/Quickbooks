-- Phase 3, part 2: issuing and voiding documents through the journal engine,
-- open-item subledgers, aging, and the client dashboard.

-- AR/AP control accounts resolve from the client's chart by template code.
-- 1100 = Accounts receivable — trade, 2000 = Accounts payable — trade.
create or replace function app.control_account(p_client_id uuid, p_code text) returns uuid
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select a.id into v_id
  from public.accounts a
  where a.client_id = p_client_id and a.code = p_code and a.archived_at is null;
  if v_id is null then
    raise exception 'control account % is missing from this chart — create it (or reseed the template) before issuing documents', p_code;
  end if;
  return v_id;
end $$;

-- Open balance of an issued invoice/bill: total minus applications from
-- ISSUED paying documents (draft and voided payments do not count).
create or replace function app.document_total(p_document_id uuid) returns numeric
language sql stable security definer
set search_path = ''
as $$
  select coalesce(sum(l.amount), 0)::numeric(18,2)
  from public.document_lines l
  where l.document_id = p_document_id
$$;

create or replace function app.document_applied(p_document_id uuid) returns numeric
language sql stable security definer
set search_path = ''
as $$
  select coalesce(sum(a.amount), 0)::numeric(18,2)
  from public.document_applications a
  join public.documents paying on paying.id = a.paying_document_id
  where a.target_document_id = p_document_id
    and paying.status = 'issued'
$$;

-- THE issuing gate. Assigns the per-type document number, builds the journal
-- entry for the document's shape, and posts it through post_entry — the same
-- balance/period/immutability gate as every manual entry.
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

  -- Shape validation per type
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
    -- Over-application check against each target's open balance, under the lock
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

  -- Build the journal entry
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

-- Voiding reverses the journal entry through the standard reversal path and
-- marks the document. A settled document cannot be voided while issued
-- payments still apply to it — void the payment first.
create or replace function public.void_document(p_document_id uuid, p_date date default null) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_doc record;
begin
  select d.* into v_doc from public.documents d where d.id = p_document_id;
  if v_doc.id is null then raise exception 'document not found'; end if;
  if not (select app.can_write_client(v_doc.client_id)) then
    raise exception 'not authorized';
  end if;
  if v_doc.status <> 'issued' then
    raise exception 'only issued documents can be voided';
  end if;
  if exists (
    select 1 from public.document_applications a
    join public.documents paying on paying.id = a.paying_document_id
    where a.target_document_id = p_document_id and paying.status = 'issued'
  ) then
    raise exception 'payments are applied to this document — void those payments first';
  end if;

  perform public.reverse_entry(v_doc.entry_id, p_date,
    'Void ' || v_doc.doc_type || ' #' || v_doc.doc_no);

  update public.documents
     set status = 'voided', voided_at = now()
   where id = p_document_id;
end $$;

revoke all on function public.issue_document(uuid), public.void_document(uuid, date)
  from public, anon, authenticated;
grant execute on function public.issue_document(uuid), public.void_document(uuid, date)
  to authenticated;

-- ------------------------------------------------------- subledger reports
-- SECURITY INVOKER: reads through the caller's own RLS.

create or replace function public.open_items(
  p_client_id uuid,
  p_doc_type text,
  p_as_of date
) returns table (
  document_id uuid,
  doc_no bigint,
  doc_date date,
  due_date date,
  contact_id uuid,
  contact_name text,
  total numeric(18,2),
  applied numeric(18,2),
  balance numeric(18,2),
  days_overdue int
)
language sql stable
set search_path = ''
as $$
  with totals as (
    select d.id, d.doc_no, d.doc_date, d.due_date, d.contact_id, c.name as contact_name,
           coalesce((select sum(l.amount) from public.document_lines l where l.document_id = d.id), 0)::numeric(18,2) as total,
           coalesce((
             select sum(a.amount)
             from public.document_applications a
             join public.documents paying on paying.id = a.paying_document_id
             where a.target_document_id = d.id
               and paying.status = 'issued'
               and paying.doc_date <= p_as_of
           ), 0)::numeric(18,2) as applied
    from public.documents d
    join public.contacts c on c.id = d.contact_id
    where d.client_id = p_client_id
      and d.doc_type = p_doc_type
      and d.status = 'issued'
      and d.doc_date <= p_as_of
  )
  select t.id, t.doc_no, t.doc_date, t.due_date, t.contact_id, t.contact_name,
         t.total, t.applied, (t.total - t.applied)::numeric(18,2),
         case when t.due_date is null or t.due_date >= p_as_of then 0
              else (p_as_of - t.due_date) end
  from totals t
  where t.total - t.applied > 0
  order by t.contact_name, t.doc_date
$$;

create or replace function public.aging(
  p_client_id uuid,
  p_doc_type text,
  p_as_of date
) returns table (
  contact_id uuid,
  contact_name text,
  current_amount numeric(18,2),
  days_1_30 numeric(18,2),
  days_31_60 numeric(18,2),
  days_61_90 numeric(18,2),
  days_over_90 numeric(18,2),
  total numeric(18,2)
)
language sql stable
set search_path = ''
as $$
  select
    o.contact_id,
    o.contact_name,
    coalesce(sum(o.balance) filter (where o.days_overdue <= 0), 0)::numeric(18,2)              as current_amount,
    coalesce(sum(o.balance) filter (where o.days_overdue between 1 and 30), 0)::numeric(18,2)  as days_1_30,
    coalesce(sum(o.balance) filter (where o.days_overdue between 31 and 60), 0)::numeric(18,2) as days_31_60,
    coalesce(sum(o.balance) filter (where o.days_overdue between 61 and 90), 0)::numeric(18,2) as days_61_90,
    coalesce(sum(o.balance) filter (where o.days_overdue > 90), 0)::numeric(18,2)              as days_over_90,
    coalesce(sum(o.balance), 0)::numeric(18,2)                                                 as total
  from public.open_items(p_client_id, p_doc_type, p_as_of) o
  group by o.contact_id, o.contact_name
  order by o.contact_name
$$;

-- ------------------------------------------------------------- dashboard
-- One round trip for the client overview: live balances, subledger totals,
-- twelve months of net movement, and what needs attention.
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
             sum(case when a.account_type = 'income' then pl.credit - pl.debit
                      when a.account_type = 'expense' then pl.debit - pl.credit
                      else 0 end)::numeric(18,2) as net
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
  public.open_items(uuid, text, date),
  public.aging(uuid, text, date),
  public.client_dashboard(uuid)
from public, anon, authenticated;
grant execute on function
  public.open_items(uuid, text, date),
  public.aging(uuid, text, date),
  public.client_dashboard(uuid)
to authenticated;
