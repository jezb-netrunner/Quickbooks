-- Phase 7: practice workflow — bank import with saved mappings, duplicate
-- detection and a rules-driven categorization queue; attachments in
-- client-scoped storage; the staff-prepares -> reviewer-approves workflow;
-- audit coverage over the books; and the cross-client practice dashboard.
--
-- Review workflow design: 'submitted' is a review-locked state between draft
-- and posted/issued. The existing RLS policies already restrict API edits to
-- draft rows, so a submitted entry or document cannot drift under review —
-- only the definer RPCs (return, post, issue) move it. When a client's
-- require_approval flag is on, the posting gate itself (post_entry, which
-- every document and adjustment posts through) refuses non-admin callers.

-- ------------------------------------------------- approval flag + notes
alter table public.clients add column if not exists require_approval boolean not null default false;
grant update (require_approval) on public.clients to authenticated;

alter table public.journal_entries add column if not exists review_note text not null default '';
alter table public.journal_entries add column if not exists submitted_by uuid references auth.users(id);
alter table public.journal_entries drop constraint if exists journal_entries_status_check;
alter table public.journal_entries add constraint journal_entries_status_check
  check (status in ('draft', 'submitted', 'posted'));

alter table public.documents add column if not exists review_note text not null default '';
alter table public.documents add column if not exists submitted_by uuid references auth.users(id);
alter table public.documents drop constraint if exists documents_status_check;
alter table public.documents add constraint documents_status_check
  check (status in ('draft', 'submitted', 'issued', 'voided'));

-- Approver = a firm admin of the client's firm.
create or replace function app.can_approve(p_client_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select app.is_firm_admin((select c.firm_id from public.clients c where c.id = p_client_id))
$$;

-- The postable gate now fires on submitted -> posted as well.
drop trigger if exists trg_journal_entries_postable on public.journal_entries;
create trigger trg_journal_entries_postable
  before update of status on public.journal_entries
  for each row
  when (old.status in ('draft', 'submitted') and new.status = 'posted')
  execute function app.assert_entry_postable();

-- Documents: submitted rows are frozen except three definer-driven moves —
-- back to draft (return, with a note), on to issued, or nothing.
create or replace function app.assert_document_mutable() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'draft' then
    return coalesce(new, old);
  end if;
  if tg_op = 'DELETE' then
    raise exception 'only draft documents can be deleted';
  end if;
  if old.status = 'submitted' then
    if new.status = 'draft' then
      if (to_jsonb(new) - 'status' - 'review_note' - 'submitted_by' - 'updated_at')
         is distinct from (to_jsonb(old) - 'status' - 'review_note' - 'submitted_by' - 'updated_at') then
        raise exception 'returning a document to draft changes nothing but the note';
      end if;
    elsif new.status = 'issued' then
      if (to_jsonb(new) - 'status' - 'doc_no' - 'entry_id' - 'updated_at')
         is distinct from (to_jsonb(old) - 'status' - 'doc_no' - 'entry_id' - 'updated_at') then
        raise exception 'issuing a submitted document changes nothing but the number and entry';
      end if;
    elsif new.status is distinct from old.status then
      raise exception 'a submitted document moves only back to draft or on to issued';
    else
      raise exception 'submitted documents are locked for review — return to draft to edit';
    end if;
    return new;
  end if;
  -- issued / voided: immutable except the void transition
  if (to_jsonb(new) - 'status' - 'voided_at' - 'updated_at')
     is distinct from (to_jsonb(old) - 'status' - 'voided_at' - 'updated_at')
     or (new.status is distinct from old.status and not (old.status = 'issued' and new.status = 'voided')) then
    raise exception 'issued documents are immutable — void and recreate';
  end if;
  return coalesce(new, old);
end $$;

-- Children (lines, applications, taxes) stay editable while the parent is a
-- draft; while SUBMITTED only the definer engine may write (the API is
-- already fenced to draft parents by RLS); after issue everything freezes.
-- The engine writes document_taxes during issue of a submitted document.
create or replace function app.assert_document_children_mutable() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_parent uuid;
  v_status text;
begin
  if tg_table_name = 'document_applications' then
    v_parent := coalesce(new.paying_document_id, old.paying_document_id);
  else
    v_parent := coalesce(new.document_id, old.document_id);
  end if;
  select d.status into v_status from public.documents d where d.id = v_parent;
  if v_status is not null and v_status not in ('draft', 'submitted') then
    raise exception 'lines and applications are frozen once the document is issued';
  end if;
  return coalesce(new, old);
end $$;

-- ------------------------------------------------ submit / return RPCs
create or replace function public.submit_entry(p_entry_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v record;
begin
  select e.id, e.client_id, e.status into v from public.journal_entries e where e.id = p_entry_id;
  if v.id is null then raise exception 'entry not found'; end if;
  if not (select app.can_write_client(v.client_id)) then raise exception 'not authorized'; end if;
  if v.status <> 'draft' then raise exception 'only drafts can be submitted for review'; end if;
  update public.journal_entries
     set status = 'submitted', submitted_by = (select auth.uid())
   where id = p_entry_id;
end $$;

create or replace function public.return_entry(p_entry_id uuid, p_note text default '') returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v record;
begin
  select e.id, e.client_id, e.status into v from public.journal_entries e where e.id = p_entry_id;
  if v.id is null then raise exception 'entry not found'; end if;
  if not (select app.can_approve(v.client_id)) then raise exception 'only a firm admin returns submissions'; end if;
  if v.status <> 'submitted' then raise exception 'only submitted entries can be returned'; end if;
  update public.journal_entries
     set status = 'draft', review_note = coalesce(p_note, '')
   where id = p_entry_id;
end $$;

create or replace function public.submit_document(p_document_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v record;
begin
  select d.id, d.client_id, d.status into v from public.documents d where d.id = p_document_id;
  if v.id is null then raise exception 'document not found'; end if;
  if not (select app.can_write_client(v.client_id)) then raise exception 'not authorized'; end if;
  if v.status <> 'draft' then raise exception 'only drafts can be submitted for review'; end if;
  update public.documents
     set status = 'submitted', submitted_by = (select auth.uid())
   where id = p_document_id;
end $$;

create or replace function public.return_document(p_document_id uuid, p_note text default '') returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v record;
begin
  select d.id, d.client_id, d.status into v from public.documents d where d.id = p_document_id;
  if v.id is null then raise exception 'document not found'; end if;
  if not (select app.can_approve(v.client_id)) then raise exception 'only a firm admin returns submissions'; end if;
  if v.status <> 'submitted' then raise exception 'only submitted documents can be returned'; end if;
  update public.documents
     set status = 'draft', review_note = coalesce(p_note, '')
   where id = p_document_id;
end $$;

revoke all on function
  public.submit_entry(uuid), public.return_entry(uuid, text),
  public.submit_document(uuid), public.return_document(uuid, text)
from public, anon, authenticated;
grant execute on function
  public.submit_entry(uuid), public.return_entry(uuid, text),
  public.submit_document(uuid), public.return_document(uuid, text)
to authenticated;

-- ----------------------------------------------- post_entry with the gate
create or replace function public.post_entry(p_entry_id uuid) returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
  v_entry record;
  v_no bigint;
begin
  select e.id, e.client_id, e.status, e.entry_date into v_entry
  from public.journal_entries e where e.id = p_entry_id;
  if v_entry.id is null then raise exception 'entry not found'; end if;
  if not (select app.can_write_client(v_entry.client_id)) then
    raise exception 'not authorized';
  end if;
  if v_entry.status not in ('draft', 'submitted') then
    raise exception 'only drafts can be posted';
  end if;
  if (select c.require_approval from public.clients c where c.id = v_entry.client_id)
     and not (select app.can_approve(v_entry.client_id)) then
    raise exception 'this client requires review — submit for approval and a firm admin posts it';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_entry.client_id::text, 1));
  select coalesce(max(entry_no), 0) + 1 into v_no
  from public.journal_entries where client_id = v_entry.client_id;

  update public.journal_entries
     set status = 'posted',
         entry_no = v_no,
         period_id = app.ensure_period(v_entry.client_id, v_entry.entry_date),
         posted_by = (select auth.uid()),
         posted_at = now()
   where id = p_entry_id;

  return v_no;
end $$;

-- issue_document accepts submitted documents. Recreate with only the status
-- check changed from the 20260812001800 version; the approval gate lives in
-- post_entry, which every issue passes through.
create or replace function public.issue_document(p_document_id uuid) returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
  v_doc record;
  v_total numeric(18,2);
  v_applied numeric(18,2);
  v_net_total numeric(18,2) := 0;
  v_vat_total numeric(18,2) := 0;
  v_inv_total numeric(18,2) := 0;   -- purchase: net posted to 1200
  v_cogs numeric(18,2) := 0;        -- invoice: FIFO cost of items sold
  v_wht_amt numeric(18,2) := 0;
  v_wht_kind text;
  v_wht_account text;
  v_ar uuid;
  v_ap uuid;
  v_entry uuid;
  v_no bigint;
  v_line_no smallint := 0;
  v_net numeric(18,2);
  r record;
  v_label text;
  v_line_kind text;
begin
  select d.* into v_doc from public.documents d where d.id = p_document_id;
  if v_doc.id is null then raise exception 'document not found'; end if;
  if not (select app.can_write_client(v_doc.client_id)) then
    raise exception 'not authorized';
  end if;
  if v_doc.status not in ('draft', 'submitted') then
    raise exception 'only drafts can be issued';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_doc.client_id::text, 2));

  select coalesce(sum(l.amount), 0) into v_total
  from public.document_lines l where l.document_id = p_document_id;
  select coalesce(sum(a.amount), 0) into v_applied
  from public.document_applications a where a.paying_document_id = p_document_id;

  perform app.assert_lines_avoid_control(p_document_id, v_doc.client_id);

  -- Item lines belong to the flows that move stock.
  if v_doc.doc_type not in ('invoice', 'purchase') and exists (
    select 1 from public.document_lines l
    where l.document_id = p_document_id and l.item_id is not null
  ) then
    raise exception 'item lines belong on invoices and purchases — receive inventory with a purchase';
  end if;

  -- Which tax kind may appear on this document's lines.
  v_line_kind := case v_doc.doc_type
    when 'invoice' then 'output_vat'
    when 'bill' then 'input_vat'
    when 'purchase' then 'input_vat'
    when 'expense' then 'input_vat'
    when 'disbursement' then 'input_vat'
    else null
  end;
  if exists (
    select 1 from public.document_lines l
    join public.tax_codes tc on tc.id = l.tax_code_id
    where l.document_id = p_document_id
      and (not tc.active or tc.kind is distinct from v_line_kind)
  ) then
    raise exception 'a line carries a tax code that is inactive or of the wrong kind for this document type';
  end if;

  -- Withholding shape: receipts carry customer-withheld CWT, disbursements
  -- carry vendor EWT; other documents carry none.
  if v_doc.wht_tax_code_id is not null then
    select tc.kind, tc.account_code into v_wht_kind, v_wht_account
    from public.tax_codes tc where tc.id = v_doc.wht_tax_code_id and tc.active;
    if v_wht_kind is null then
      raise exception 'the withholding tax code is inactive';
    end if;
    if v_doc.doc_type = 'receipt' and v_wht_kind <> 'withholding_sales' then
      raise exception 'receipts take a customer-withholding (sales) tax code';
    end if;
    if v_doc.doc_type = 'disbursement' and v_wht_kind <> 'withholding_purchases' then
      raise exception 'disbursements take a vendor-withholding (purchases) tax code';
    end if;
    if v_doc.doc_type not in ('receipt', 'disbursement') then
      raise exception 'withholding is recorded on the payment document';
    end if;
    v_wht_amt := round(v_doc.wht_base * app.tax_rate(v_doc.wht_tax_code_id, v_doc.doc_date), 2);
    if v_wht_amt <= 0 then
      raise exception 'the withholding base and rate compute to zero — remove the code or fix the base';
    end if;
  end if;

  if v_doc.doc_type in ('invoice', 'bill', 'purchase', 'expense') then
    if v_total <= 0 then raise exception 'add at least one line before issuing'; end if;
    if v_applied > 0 then raise exception 'only payment documents carry applications'; end if;
    if v_doc.doc_type = 'expense' and v_doc.bank_account_id is null then
      raise exception 'an expense is paid from a cash or bank account — choose one';
    end if;
    if v_doc.doc_type in ('bill') and v_doc.bank_account_id is not null then
      raise exception 'bills are settled by payments — record a cash purchase or an expense instead';
    end if;
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
      if v_doc.doc_type = 'disbursement' and r.target_type not in ('bill', 'purchase') then
        raise exception 'payments apply to bills and purchases only';
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
    v_line_no := 1;   -- slot 1 reserved for the AR/cash debit inserted after totals
    for r in
      select l.account_id, l.amount, l.tax_code_id, l.item_id, l.qty,
             case when l.tax_code_id is null then null
                  else app.tax_rate(l.tax_code_id, v_doc.doc_date) end as rate
      from public.document_lines l
      where l.document_id = p_document_id order by l.line_no
    loop
      v_net := case
        when r.rate is null then r.amount
        when v_doc.amounts_include_tax then round(r.amount / (1 + r.rate), 2)
        else r.amount
      end;
      v_net_total := v_net_total + v_net;
      v_vat_total := v_vat_total + case
        when r.rate is null then 0
        when v_doc.amounts_include_tax then r.amount - v_net
        else round(r.amount * r.rate, 2)
      end;
      v_line_no := v_line_no + 1;
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v_doc.client_id, v_line_no, r.account_id, 0, v_net);
      if r.item_id is not null then
        v_cogs := v_cogs + app.consume_fifo(v_doc.client_id, r.item_id, r.qty,
                                            p_document_id, null, v_doc.doc_date);
      end if;
    end loop;
    for r in
      select l.tax_code_id, tc.account_code,
             sum(case when v_doc.amounts_include_tax
                      then round(l.amount / (1 + app.tax_rate(l.tax_code_id, v_doc.doc_date)), 2)
                      else l.amount end) as base,
             sum(case when v_doc.amounts_include_tax
                      then l.amount - round(l.amount / (1 + app.tax_rate(l.tax_code_id, v_doc.doc_date)), 2)
                      else round(l.amount * app.tax_rate(l.tax_code_id, v_doc.doc_date), 2) end) as tax
      from public.document_lines l
      join public.tax_codes tc on tc.id = l.tax_code_id
      where l.document_id = p_document_id
      group by l.tax_code_id, tc.account_code
    loop
      insert into public.document_taxes (document_id, client_id, tax_code_id, base, amount)
      values (p_document_id, v_doc.client_id, r.tax_code_id, r.base, r.tax);
      if r.tax <> 0 then
        v_line_no := v_line_no + 1;
        insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
        values (v_entry, v_doc.client_id, v_line_no,
                app.control_account(v_doc.client_id, r.account_code), 0, r.tax);
      end if;
    end loop;
    if v_cogs > 0 then
      v_line_no := v_line_no + 1;
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v_doc.client_id, v_line_no,
              app.control_account(v_doc.client_id, '5000'), v_cogs, 0);
      v_line_no := v_line_no + 1;
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v_doc.client_id, v_line_no,
              app.control_account(v_doc.client_id, '1200'), 0, v_cogs);
    end if;
    insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
    values (v_entry, v_doc.client_id, 1,
            coalesce(v_doc.bank_account_id, app.control_account(v_doc.client_id, '1100')),
            v_net_total + v_vat_total, 0);

  elsif v_doc.doc_type in ('bill', 'purchase', 'expense') then
    for r in
      select l.account_id, l.amount, l.tax_code_id, l.item_id, l.qty,
             case when l.tax_code_id is null then null
                  else app.tax_rate(l.tax_code_id, v_doc.doc_date) end as rate
      from public.document_lines l
      where l.document_id = p_document_id order by l.line_no
    loop
      v_net := case
        when r.rate is null then r.amount
        when v_doc.amounts_include_tax then round(r.amount / (1 + r.rate), 2)
        else r.amount
      end;
      v_net_total := v_net_total + v_net;
      v_vat_total := v_vat_total + case
        when r.rate is null then 0
        when v_doc.amounts_include_tax then r.amount - v_net
        else round(r.amount * r.rate, 2)
      end;
      if r.item_id is not null then
        -- inventory in: aggregate the 1200 debit, create the FIFO layer
        v_inv_total := v_inv_total + v_net;
        insert into public.inventory_layers
          (client_id, item_id, acquired_date, qty_in, qty_remaining, unit_cost, cost_total, source_document_id)
        values (v_doc.client_id, r.item_id, v_doc.doc_date, r.qty, r.qty,
                round(v_net / r.qty, 6), v_net, p_document_id);
      else
        v_line_no := v_line_no + 1;
        insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
        values (v_entry, v_doc.client_id, v_line_no, r.account_id, v_net, 0);
      end if;
    end loop;
    if v_inv_total > 0 then
      v_line_no := v_line_no + 1;
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v_doc.client_id, v_line_no,
              app.control_account(v_doc.client_id, '1200'), v_inv_total, 0);
    end if;
    for r in
      select l.tax_code_id, tc.account_code,
             sum(case when v_doc.amounts_include_tax
                      then round(l.amount / (1 + app.tax_rate(l.tax_code_id, v_doc.doc_date)), 2)
                      else l.amount end) as base,
             sum(case when v_doc.amounts_include_tax
                      then l.amount - round(l.amount / (1 + app.tax_rate(l.tax_code_id, v_doc.doc_date)), 2)
                      else round(l.amount * app.tax_rate(l.tax_code_id, v_doc.doc_date), 2) end) as tax
      from public.document_lines l
      join public.tax_codes tc on tc.id = l.tax_code_id
      where l.document_id = p_document_id
      group by l.tax_code_id, tc.account_code
    loop
      insert into public.document_taxes (document_id, client_id, tax_code_id, base, amount)
      values (p_document_id, v_doc.client_id, r.tax_code_id, r.base, r.tax);
      if r.tax <> 0 then
        v_line_no := v_line_no + 1;
        insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
        values (v_entry, v_doc.client_id, v_line_no,
                app.control_account(v_doc.client_id, r.account_code), r.tax, 0);
      end if;
    end loop;
    -- credit side: expense always cash; purchase cash when settled now; else AP
    if v_doc.doc_type = 'expense' or (v_doc.doc_type = 'purchase' and v_doc.bank_account_id is not null) then
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v_doc.client_id, v_line_no + 1, v_doc.bank_account_id, 0, v_net_total + v_vat_total);
    else
      v_ap := app.control_account(v_doc.client_id, '2000');
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v_doc.client_id, v_line_no + 1, v_ap, 0, v_net_total + v_vat_total);
    end if;

  elsif v_doc.doc_type = 'receipt' then
    if v_wht_amt >= v_applied then
      raise exception 'withholding cannot equal or exceed the amount collected';
    end if;
    v_ar := app.control_account(v_doc.client_id, '1100');
    insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
    values (v_entry, v_doc.client_id, 1, v_doc.bank_account_id, v_applied - v_wht_amt, 0);
    v_line_no := 1;
    if v_wht_amt > 0 then
      v_line_no := v_line_no + 1;
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v_doc.client_id, v_line_no,
              app.control_account(v_doc.client_id, v_wht_account), v_wht_amt, 0);
      insert into public.document_taxes (document_id, client_id, tax_code_id, base, amount)
      values (p_document_id, v_doc.client_id, v_doc.wht_tax_code_id, v_doc.wht_base, v_wht_amt);
    end if;
    v_line_no := v_line_no + 1;
    insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
    values (v_entry, v_doc.client_id, v_line_no, v_ar, 0, v_applied);

  elsif v_doc.doc_type = 'disbursement' then
    if v_applied > 0 then
      v_ap := app.control_account(v_doc.client_id, '2000');
      v_line_no := v_line_no + 1;
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v_doc.client_id, v_line_no, v_ap, v_applied, 0);
    end if;
    for r in
      select l.account_id, l.amount, l.tax_code_id,
             case when l.tax_code_id is null then null
                  else app.tax_rate(l.tax_code_id, v_doc.doc_date) end as rate
      from public.document_lines l
      where l.document_id = p_document_id order by l.line_no
    loop
      v_net := case
        when r.rate is null then r.amount
        when v_doc.amounts_include_tax then round(r.amount / (1 + r.rate), 2)
        else r.amount
      end;
      v_net_total := v_net_total + v_net;
      v_vat_total := v_vat_total + case
        when r.rate is null then 0
        when v_doc.amounts_include_tax then r.amount - v_net
        else round(r.amount * r.rate, 2)
      end;
      v_line_no := v_line_no + 1;
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v_doc.client_id, v_line_no, r.account_id, v_net, 0);
    end loop;
    for r in
      select l.tax_code_id, tc.account_code,
             sum(case when v_doc.amounts_include_tax
                      then round(l.amount / (1 + app.tax_rate(l.tax_code_id, v_doc.doc_date)), 2)
                      else l.amount end) as base,
             sum(case when v_doc.amounts_include_tax
                      then l.amount - round(l.amount / (1 + app.tax_rate(l.tax_code_id, v_doc.doc_date)), 2)
                      else round(l.amount * app.tax_rate(l.tax_code_id, v_doc.doc_date), 2) end) as tax
      from public.document_lines l
      join public.tax_codes tc on tc.id = l.tax_code_id
      where l.document_id = p_document_id
      group by l.tax_code_id, tc.account_code
    loop
      insert into public.document_taxes (document_id, client_id, tax_code_id, base, amount)
      values (p_document_id, v_doc.client_id, r.tax_code_id, r.base, r.tax);
      if r.tax <> 0 then
        v_line_no := v_line_no + 1;
        insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
        values (v_entry, v_doc.client_id, v_line_no,
                app.control_account(v_doc.client_id, r.account_code), r.tax, 0);
      end if;
    end loop;
    if v_wht_amt >= v_applied + v_net_total + v_vat_total then
      raise exception 'withholding cannot equal or exceed the amount paid';
    end if;
    if v_wht_amt > 0 then
      v_line_no := v_line_no + 1;
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v_doc.client_id, v_line_no,
              app.control_account(v_doc.client_id, v_wht_account), 0, v_wht_amt);
      insert into public.document_taxes (document_id, client_id, tax_code_id, base, amount)
      values (p_document_id, v_doc.client_id, v_doc.wht_tax_code_id, v_doc.wht_base, v_wht_amt);
    end if;
    insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
    values (v_entry, v_doc.client_id, v_line_no + 1, v_doc.bank_account_id, 0,
            v_applied + v_net_total + v_vat_total - v_wht_amt);
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

-- ------------------------------------------------------------ bank import
alter table public.journal_entries drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries add constraint journal_entries_source_type_check
  check (source_type in ('manual', 'opening_balance', 'reversal',
                         'invoice', 'bill', 'receipt', 'disbursement',
                         'purchase', 'expense', 'bank_import'));

create table if not exists public.bank_import_profiles (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references public.clients(id),
  name            text not null check (length(btrim(name)) between 1 and 80),
  bank_account_id uuid not null,
  date_col        int not null default 1 check (date_col >= 1),
  desc_col        int not null default 2 check (desc_col >= 1),
  amount_col      int check (amount_col is null or amount_col >= 1),
  debit_col       int check (debit_col is null or debit_col >= 1),
  credit_col      int check (credit_col is null or credit_col >= 1),
  date_format     text not null default 'YMD' check (date_format in ('YMD', 'DMY', 'MDY')),
  skip_rows       int not null default 1 check (skip_rows >= 0),
  negate          boolean not null default false,
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  unique (client_id, name),
  foreign key (bank_account_id, client_id) references public.accounts (id, client_id),
  check (amount_col is not null or (debit_col is not null and credit_col is not null))
);

drop trigger if exists trg_bank_import_profiles_created_by on public.bank_import_profiles;
create trigger trg_bank_import_profiles_created_by
  before insert on public.bank_import_profiles
  for each row execute function app.force_created_by();

alter table public.bank_import_profiles enable row level security;
drop policy if exists bank_import_profiles_select on public.bank_import_profiles;
create policy bank_import_profiles_select on public.bank_import_profiles
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));
drop policy if exists bank_import_profiles_insert on public.bank_import_profiles;
create policy bank_import_profiles_insert on public.bank_import_profiles
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));
drop policy if exists bank_import_profiles_update on public.bank_import_profiles;
create policy bank_import_profiles_update on public.bank_import_profiles
  for update to authenticated
  using ((select app.can_write_client(client_id)))
  with check ((select app.can_write_client(client_id)));
drop policy if exists bank_import_profiles_delete on public.bank_import_profiles;
create policy bank_import_profiles_delete on public.bank_import_profiles
  for delete to authenticated
  using ((select app.can_write_client(client_id)));
grant select on public.bank_import_profiles to authenticated;
grant insert (client_id, name, bank_account_id, date_col, desc_col, amount_col, debit_col,
              credit_col, date_format, skip_rows, negate) on public.bank_import_profiles to authenticated;
grant update (name, bank_account_id, date_col, desc_col, amount_col, debit_col,
              credit_col, date_format, skip_rows, negate) on public.bank_import_profiles to authenticated;
grant delete on public.bank_import_profiles to authenticated;

-- Staged bank lines. amount is signed from the BANK's view: positive = money
-- into the account. The fingerprint dedupes re-imports per client.
create table if not exists public.bank_txns (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references public.clients(id),
  bank_account_id uuid not null,
  txn_date        date not null,
  description     text not null default '',
  amount          numeric(18,2) not null check (amount <> 0),
  fingerprint     text not null,
  status          text not null default 'pending' check (status in ('pending', 'categorized', 'excluded')),
  account_id      uuid,
  entry_id        uuid,
  note            text not null default '',
  imported_by     uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  unique (client_id, fingerprint),
  foreign key (bank_account_id, client_id) references public.accounts (id, client_id),
  foreign key (account_id, client_id) references public.accounts (id, client_id),
  foreign key (entry_id, client_id) references public.journal_entries (id, client_id)
);
create index if not exists bank_txns_queue_idx on public.bank_txns (client_id, status, txn_date);

alter table public.bank_txns enable row level security;
drop policy if exists bank_txns_select on public.bank_txns;
create policy bank_txns_select on public.bank_txns
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));
-- Writes go through the RPCs only.
grant select on public.bank_txns to authenticated;

create table if not exists public.bank_rules (
  id         uuid primary key default gen_random_uuid(),
  client_id  uuid not null references public.clients(id),
  match_text text not null check (length(btrim(match_text)) between 2 and 80),
  account_id uuid not null,
  priority   int not null default 100,
  active     boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key (account_id, client_id) references public.accounts (id, client_id)
);

drop trigger if exists trg_bank_rules_created_by on public.bank_rules;
create trigger trg_bank_rules_created_by
  before insert on public.bank_rules
  for each row execute function app.force_created_by();

alter table public.bank_rules enable row level security;
drop policy if exists bank_rules_select on public.bank_rules;
create policy bank_rules_select on public.bank_rules
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));
drop policy if exists bank_rules_insert on public.bank_rules;
create policy bank_rules_insert on public.bank_rules
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));
drop policy if exists bank_rules_update on public.bank_rules;
create policy bank_rules_update on public.bank_rules
  for update to authenticated
  using ((select app.can_write_client(client_id)))
  with check ((select app.can_write_client(client_id)));
drop policy if exists bank_rules_delete on public.bank_rules;
create policy bank_rules_delete on public.bank_rules
  for delete to authenticated
  using ((select app.can_write_client(client_id)));
grant select on public.bank_rules to authenticated;
grant insert (client_id, match_text, account_id, priority, active) on public.bank_rules to authenticated;
grant update (match_text, account_id, priority, active) on public.bank_rules to authenticated;
grant delete on public.bank_rules to authenticated;

-- Import parsed rows: [{"d": "2026-01-05", "m": "description", "a": -123.45}].
-- The browser parses the CSV with the saved column mapping; the server owns
-- validation and duplicate detection.
create or replace function public.import_bank_txns(
  p_client_id uuid,
  p_bank_account_id uuid,
  p_rows jsonb
) returns table (inserted int, duplicates int, skipped int)
language plpgsql security definer
set search_path = ''
as $$
declare
  v_code text;
  r jsonb;
  v_date date;
  v_amount numeric(18,2);
  v_desc text;
  v_fp text;
  v_ins int := 0;
  v_dup int := 0;
  v_skip int := 0;
  v_count int;
begin
  if not (select app.can_write_client(p_client_id)) then
    raise exception 'not authorized';
  end if;
  select a.code into v_code from public.accounts a
   where a.id = p_bank_account_id and a.client_id = p_client_id and a.archived_at is null;
  if v_code is null or v_code not like '1000%' then
    raise exception 'import lands in an active 1000-series cash account';
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    begin
      v_date := (r ->> 'd')::date;
      v_amount := round((r ->> 'a')::numeric, 2);
      v_desc := btrim(coalesce(r ->> 'm', ''));
    exception when others then
      v_skip := v_skip + 1;
      continue;
    end;
    if v_date is null or v_amount is null or v_amount = 0 then
      v_skip := v_skip + 1;
      continue;
    end if;
    v_fp := md5(p_bank_account_id::text || '|' || v_date || '|' || v_amount || '|' || lower(v_desc));
    insert into public.bank_txns
      (client_id, bank_account_id, txn_date, description, amount, fingerprint, imported_by)
    values (p_client_id, p_bank_account_id, v_date, v_desc, v_amount, v_fp, (select auth.uid()))
    on conflict (client_id, fingerprint) do nothing;
    get diagnostics v_count = row_count;
    if v_count = 1 then v_ins := v_ins + 1; else v_dup := v_dup + 1; end if;
  end loop;
  return query select v_ins, v_dup, v_skip;
end $$;

-- The categorization core: post the journal entry a staged line implies.
-- Inflow: DR bank / CR account. Outflow: DR account / CR bank. Posting runs
-- through post_entry, so period gates and the approval regime apply.
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
  if v_acct.code in ('1100', '2000', '1200') then
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

create or replace function public.categorize_bank_txn(
  p_txn_id uuid,
  p_account_id uuid,
  p_memo text default null
) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_client uuid;
begin
  select b.client_id into v_client from public.bank_txns b where b.id = p_txn_id;
  if v_client is null then raise exception 'bank line not found'; end if;
  if not (select app.can_write_client(v_client)) then raise exception 'not authorized'; end if;
  perform app.bank_categorize(p_txn_id, p_account_id, p_memo);
end $$;

create or replace function public.exclude_bank_txn(p_txn_id uuid, p_note text default '') returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v record;
begin
  select b.id, b.client_id, b.status into v from public.bank_txns b where b.id = p_txn_id;
  if v.id is null then raise exception 'bank line not found'; end if;
  if not (select app.can_write_client(v.client_id)) then raise exception 'not authorized'; end if;
  if v.status <> 'pending' then raise exception 'only pending bank lines can be excluded'; end if;
  update public.bank_txns set status = 'excluded', note = coalesce(p_note, '') where id = p_txn_id;
end $$;

create or replace function public.restore_bank_txn(p_txn_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v record;
begin
  select b.id, b.client_id, b.status into v from public.bank_txns b where b.id = p_txn_id;
  if v.id is null then raise exception 'bank line not found'; end if;
  if not (select app.can_write_client(v.client_id)) then raise exception 'not authorized'; end if;
  if v.status <> 'excluded' then raise exception 'only excluded bank lines can be restored'; end if;
  update public.bank_txns set status = 'pending', note = '' where id = p_txn_id;
end $$;

-- Auto-categorize every pending line whose description matches a rule.
-- First match by priority wins; lines that fail to post (closed period,
-- approval regime) stay pending. Returns how many were categorized.
create or replace function public.apply_bank_rules(p_client_id uuid) returns int
language plpgsql security definer
set search_path = ''
as $$
declare
  t record;
  v_rule record;
  v_done int := 0;
begin
  if not (select app.can_write_client(p_client_id)) then
    raise exception 'not authorized';
  end if;
  for t in
    select b.id, b.description from public.bank_txns b
    where b.client_id = p_client_id and b.status = 'pending'
    order by b.txn_date, b.created_at
  loop
    select r.account_id into v_rule
    from public.bank_rules r
    where r.client_id = p_client_id and r.active
      and position(lower(r.match_text) in lower(t.description)) > 0
    order by r.priority, r.created_at
    limit 1;
    if v_rule.account_id is not null then
      begin
        perform app.bank_categorize(t.id, v_rule.account_id, null);
        v_done := v_done + 1;
      exception when others then
        null;   -- leave it pending; the queue shows why when tried by hand
      end;
    end if;
  end loop;
  return v_done;
end $$;

revoke all on function
  public.import_bank_txns(uuid, uuid, jsonb),
  public.categorize_bank_txn(uuid, uuid, text),
  public.exclude_bank_txn(uuid, text),
  public.restore_bank_txn(uuid),
  public.apply_bank_rules(uuid)
from public, anon, authenticated;
grant execute on function
  public.import_bank_txns(uuid, uuid, jsonb),
  public.categorize_bank_txn(uuid, uuid, text),
  public.exclude_bank_txn(uuid, text),
  public.restore_bank_txn(uuid),
  public.apply_bank_rules(uuid)
to authenticated;

-- ------------------------------------------------------------ attachments
-- Object paths are '<client_id>/<uuid>-<filename>' in the private
-- 'attachments' bucket; the path prefix is the tenancy wall.
-- Guarded: some hosted environments do not let the migration role manage
-- storage policies. If this block is skipped, create the same bucket and
-- policies from the dashboard (documented in the hosted-project runbook) —
-- the pgTAP suite proves the intended policies on every CI run.
do $$ begin
  insert into storage.buckets (id, name, public)
  values ('attachments', 'attachments', false)
  on conflict (id) do nothing;
exception when insufficient_privilege then
  raise notice 'SKIPPED creating the attachments bucket — create it manually (private)';
end $$;

do $$ begin
  drop policy if exists attachments_read on storage.objects;
  create policy attachments_read on storage.objects
    for select to authenticated
    using (
      bucket_id = 'attachments'
      and (split_part(name, '/', 1))::uuid in (select app.accessible_client_ids())
    );

  drop policy if exists attachments_write on storage.objects;
  create policy attachments_write on storage.objects
    for insert to authenticated
    with check (
      bucket_id = 'attachments'
      and (select app.can_write_client((split_part(name, '/', 1))::uuid))
    );

  drop policy if exists attachments_remove on storage.objects;
  create policy attachments_remove on storage.objects
    for delete to authenticated
    using (
      bucket_id = 'attachments'
      and (select app.can_write_client((split_part(name, '/', 1))::uuid))
    );
exception when insufficient_privilege then
  raise notice 'SKIPPED storage policies — add attachments_read/write/remove from the dashboard';
end $$;

create table if not exists public.attachments (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.clients(id),
  document_id uuid,
  entry_id    uuid,
  storage_path text not null unique,
  filename    text not null check (length(btrim(filename)) between 1 and 200),
  mime        text not null default '',
  size_bytes  bigint not null default 0 check (size_bytes >= 0),
  uploaded_by uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  check (document_id is not null or entry_id is not null),
  foreign key (document_id, client_id) references public.documents (id, client_id) on delete cascade,
  foreign key (entry_id, client_id) references public.journal_entries (id, client_id) on delete cascade
);
create index if not exists attachments_document_idx on public.attachments (document_id);
create index if not exists attachments_entry_idx on public.attachments (entry_id);

-- force_created_by targets a created_by column; attachments uses uploaded_by.
create or replace function app.force_created_by_uploaded() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  new.uploaded_by := (select auth.uid());
  return new;
end $$;

drop trigger if exists trg_attachments_created_by on public.attachments;
create trigger trg_attachments_created_by
  before insert on public.attachments
  for each row execute function app.force_created_by_uploaded();

alter table public.attachments enable row level security;
drop policy if exists attachments_select on public.attachments;
create policy attachments_select on public.attachments
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));
drop policy if exists attachments_insert on public.attachments;
create policy attachments_insert on public.attachments
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));
drop policy if exists attachments_delete on public.attachments;
create policy attachments_delete on public.attachments
  for delete to authenticated
  using ((select app.can_write_client(client_id)));
grant select on public.attachments to authenticated;
grant insert (client_id, document_id, entry_id, storage_path, filename, mime, size_bytes)
  on public.attachments to authenticated;
grant delete on public.attachments to authenticated;

-- ------------------------------------------------- audit over the books
-- The Phase 1 audit tables all carried firm_id directly; the books tables
-- carry client_id only, so the writer now resolves the firm through the
-- client. Behavior for the original four tables is unchanged.
create or replace function app.write_audit() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_new    jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_old    jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_row    jsonb := coalesce(v_new, v_old);
  v_firm   uuid;
  v_client uuid;
  v_record uuid;
begin
  v_client := case
    when tg_table_name = 'clients' then (v_row ->> 'id')::uuid
    else (v_row ->> 'client_id')::uuid
  end;
  v_firm := case
    when tg_table_name = 'firms' then (v_row ->> 'id')::uuid
    when v_row ? 'firm_id' then (v_row ->> 'firm_id')::uuid
    else (select c.firm_id from public.clients c where c.id = v_client)
  end;
  -- client_assignments has a composite PK; its membership_id identifies the row.
  v_record := coalesce((v_row ->> 'id')::uuid, (v_row ->> 'membership_id')::uuid);

  insert into public.audit_log (actor_id, firm_id, client_id, table_name, record_id, action, changes)
  values (
    (select auth.uid()),
    v_firm,
    v_client,
    tg_table_name,
    v_record,
    lower(tg_op),
    jsonb_strip_nulls(jsonb_build_object('old', v_old, 'new', v_new))
  );
  return coalesce(new, old);
end $$;

drop trigger if exists trg_audit_journal_entries on public.journal_entries;
create trigger trg_audit_journal_entries
  after insert or update or delete on public.journal_entries
  for each row execute function app.write_audit();

drop trigger if exists trg_audit_documents on public.documents;
create trigger trg_audit_documents
  after insert or update or delete on public.documents
  for each row execute function app.write_audit();

drop trigger if exists trg_audit_tax_codes on public.tax_codes;
create trigger trg_audit_tax_codes
  after insert or update or delete on public.tax_codes
  for each row execute function app.write_audit();

drop trigger if exists trg_audit_tax_code_rates on public.tax_code_rates;
create trigger trg_audit_tax_code_rates
  after insert or update or delete on public.tax_code_rates
  for each row execute function app.write_audit();

drop trigger if exists trg_audit_compliance_filings on public.compliance_filings;
create trigger trg_audit_compliance_filings
  after insert or update or delete on public.compliance_filings
  for each row execute function app.write_audit();

-- ------------------------------------------------- practice dashboard
-- One row per accessible, unarchived client: where its books and its
-- compliance stand right now. SECURITY INVOKER end to end.
create or replace function public.practice_dashboard() returns table (
  client_id uuid,
  name text,
  code text,
  period_status text,
  drafts bigint,
  submitted bigint,
  pending_bank bigint,
  ar_overdue numeric(18,2),
  overdue_filings bigint,
  next_due_form text,
  next_due_date date
)
language sql stable
set search_path = ''
as $$
  select c.id, c.name, c.code,
         coalesce((select p.status from public.periods p
                   where p.client_id = c.id
                     and current_date between p.period_start and p.period_end), 'none'),
         (select count(*) from public.documents d where d.client_id = c.id and d.status = 'draft')
           + (select count(*) from public.journal_entries e where e.client_id = c.id and e.status = 'draft'),
         (select count(*) from public.documents d where d.client_id = c.id and d.status = 'submitted')
           + (select count(*) from public.journal_entries e where e.client_id = c.id and e.status = 'submitted'),
         (select count(*) from public.bank_txns b where b.client_id = c.id and b.status = 'pending'),
         (select coalesce(sum(o.balance) filter (where o.days_overdue > 0), 0)
          from public.open_items(c.id, 'receivable', current_date) o)::numeric(18,2),
         cal.overdue,
         cal.next_form,
         cal.next_date
  from public.clients c
  left join lateral (
    select count(*) filter (where x.status = 'pending' and x.due_date < current_date) as overdue,
           (array_agg(x.form order by x.due_date)
              filter (where x.status = 'pending' and x.due_date >= current_date))[1] as next_form,
           min(x.due_date) filter (where x.status = 'pending' and x.due_date >= current_date) as next_date
    from (
      select * from public.compliance_calendar(c.id, extract(year from current_date)::int - 1)
      union all
      select * from public.compliance_calendar(c.id, extract(year from current_date)::int)
    ) x
  ) cal on true
  where c.id in (select app.accessible_client_ids())
    and c.archived_at is null
  order by c.name
$$;

revoke all on function public.practice_dashboard() from public, anon, authenticated;
grant execute on function public.practice_dashboard() to authenticated;
