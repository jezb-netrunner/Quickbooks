-- Hardening pass, batch 1 — the posting engine.
-- Fixes audit findings P3-06 (FIFO sub-centavo overshoot), P3-01 (issue race:
-- status re-checked under the advisory lock), P3-03 (withholding base capped
-- at the net-of-VAT of what the payment settles), and extends open_items with
-- the net/VAT split the payment form needs (T-04).

-- ---------------------------------------------------------------------------
-- P3-06 — consume_fifo priced a partial take as round(qty*unit_cost, 2) with
-- no cap, so a fractional-centavo unit cost that rounds UP (100 @ ₱0.50 →
-- unit_cost 0.005 → every 1-unit take = ₱0.01) pushed cumulative consumption
-- past the layer's cost_total: valuation and GL 1200 went negative with stock
-- on hand, and the exhausting take computed a negative residual that the
-- layer_consumptions cost >= 0 CHECK rejected — the last unit could not be
-- sold. Fix: cap every take at the layer's remaining residual value, so
-- cumulative consumption can never exceed cost_total. Under-rounded partials
-- are still trued up by the exhausting take (which takes the whole residual).
create or replace function app.consume_fifo(
  p_client_id uuid,
  p_item_id uuid,
  p_qty numeric,
  p_document_id uuid,
  p_adjustment_id uuid,
  p_move_date date
) returns numeric
language plpgsql security definer
set search_path = ''
as $$
declare
  v_needed numeric := p_qty;
  v_total numeric(18,2) := 0;
  v_take numeric;
  v_cost numeric(18,2);
  v_residual numeric(18,2);
  r record;
begin
  for r in
    select l.id, l.qty_remaining, l.unit_cost, l.cost_total
    from public.inventory_layers l
    where l.client_id = p_client_id and l.item_id = p_item_id and l.qty_remaining > 0
    order by l.acquired_date, l.created_at, l.id
  loop
    exit when v_needed <= 0;
    v_take := least(r.qty_remaining, v_needed);
    select greatest(r.cost_total - coalesce(sum(c.cost), 0), 0) into v_residual
    from public.layer_consumptions c where c.layer_id = r.id;
    if v_take = r.qty_remaining then
      -- exhausting: take the layer's entire remaining residual value
      v_cost := v_residual;
    else
      v_cost := least(round(v_take * r.unit_cost, 2), v_residual);
    end if;
    update public.inventory_layers
       set qty_remaining = qty_remaining - v_take
     where id = r.id;
    insert into public.layer_consumptions
      (client_id, layer_id, document_id, adjustment_id, move_date, qty, cost)
    values (p_client_id, r.id, p_document_id, p_adjustment_id, p_move_date, v_take, v_cost);
    v_total := v_total + v_cost;
    v_needed := v_needed - v_take;
  end loop;
  if v_needed > 0 then
    raise exception 'not enough stock of % — % short (stock cannot go negative)',
      (select i.sku from public.items i where i.id = p_item_id), v_needed;
  end if;
  return v_total;
end $$;

-- ---------------------------------------------------------------------------
-- Net-of-VAT of an issued document from its frozen data. Exclusive docs:
-- gross = lines + VAT, net = lines. Inclusive docs: gross = lines,
-- net = lines − VAT. Both collapse to net = gross − VAT, with VAT read from
-- the frozen document_taxes rows of VAT kinds (the payment doc's own WHT rows
-- share the table and must never count here).
create or replace function app.document_net(p_document_id uuid) returns numeric
language sql stable security definer
set search_path = ''
as $$
  select (app.document_total(p_document_id)
        - coalesce((select sum(t.amount)
                    from public.document_taxes t
                    join public.tax_codes tc on tc.id = t.tax_code_id
                    where t.document_id = p_document_id
                      and tc.kind in ('output_vat', 'input_vat')), 0))::numeric(18,2)
$$;

-- ---------------------------------------------------------------------------
-- issue_document — full recreation with two changes:
--   P3-01: the draft/submitted status check is REPEATED after taking the
--     client's posting advisory lock. Two concurrent issues (double-click,
--     retried request) both passed the pre-lock check, serialized on the
--     lock, and the second posted the same document again. The re-check makes
--     the loser fail cleanly with "only drafts can be issued".
--   P3-03: the withholding base is capped at the net-of-VAT value of what
--     this payment settles: Σ(application × net/gross of its target),
--     pro-rated for partial payments, plus (disbursements) the net of any
--     direct expense lines. PH withholding applies to the income payment net
--     of VAT (practice CPA confirmed), so a base above that ceiling is a
--     typo, not a choice. One-centavo tolerance absorbs per-application
--     rounding.
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
  v_wht_base_max numeric(18,2);
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

  -- P3-01: re-check under the lock — a concurrent issue of the same document
  -- serialized on the lock above and may already have posted it.
  select d.status into v_label from public.documents d where d.id = p_document_id;
  if v_label not in ('draft', 'submitted') then
    raise exception 'only drafts can be issued';
  end if;

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
    -- P3-03: the base cannot exceed the net-of-VAT of what this payment
    -- settles. Applications are gross, so each contributes its pro-rated net;
    -- disbursement direct lines contribute their line net.
    select coalesce(sum(round(a.amount * app.document_net(a.target_document_id)
                              / nullif(app.document_total(a.target_document_id), 0), 2)), 0)
      into v_wht_base_max
    from public.document_applications a
    where a.paying_document_id = p_document_id;
    select v_wht_base_max + coalesce(sum(case
             when l.tax_code_id is null then l.amount
             when v_doc.amounts_include_tax then round(l.amount / (1 + app.tax_rate(l.tax_code_id, v_doc.doc_date)), 2)
             else l.amount end), 0)
      into v_wht_base_max
    from public.document_lines l
    where l.document_id = p_document_id;
    if v_doc.wht_base > v_wht_base_max + 0.01 then
      raise exception 'the withholding base (%) exceeds the net-of-VAT value this payment settles (%) — PH withholding applies to the income payment net of VAT',
        v_doc.wht_base, v_wht_base_max;
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

-- ---------------------------------------------------------------------------
-- open_items gains vat/net columns so the payment form can show the applied
-- documents' Net + VAT split and derive the withholding base (T-04). Same
-- rows, same math; net = gross − VAT works for inclusive and exclusive docs.
drop function if exists public.open_items(uuid, text, date);
create function public.open_items(
  p_client_id uuid,
  p_doc_type text,
  p_as_of date
) returns table (
  document_id uuid,
  doc_type text,
  doc_no bigint,
  doc_date date,
  due_date date,
  contact_id uuid,
  contact_name text,
  total numeric(18,2),
  applied numeric(18,2),
  balance numeric(18,2),
  days_overdue int,
  vat numeric(18,2),
  net numeric(18,2)
)
language sql stable
set search_path = ''
as $$
  with totals as (
    select d.id, d.doc_type, d.doc_no, d.doc_date, d.due_date, d.contact_id, c.name as contact_name,
           (coalesce((select sum(l.amount) from public.document_lines l where l.document_id = d.id), 0)
            + case when d.amounts_include_tax then 0
                   else coalesce((select sum(t.amount)
                                  from public.document_taxes t
                                  join public.tax_codes tc on tc.id = t.tax_code_id
                                  where t.document_id = d.id
                                    and tc.kind in ('output_vat', 'input_vat')), 0)
              end)::numeric(18,2) as total,
           coalesce((select sum(t.amount)
                     from public.document_taxes t
                     join public.tax_codes tc on tc.id = t.tax_code_id
                     where t.document_id = d.id
                       and tc.kind in ('output_vat', 'input_vat')), 0)::numeric(18,2) as vat,
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
      and case p_doc_type
            when 'receivable' then d.doc_type = 'invoice'
            when 'payable' then d.doc_type in ('bill', 'purchase')
            else d.doc_type = p_doc_type
          end
      and d.status = 'issued'
      and d.doc_date <= p_as_of
      and d.bank_account_id is null
  )
  select t.id, t.doc_type, t.doc_no, t.doc_date, t.due_date, t.contact_id, t.contact_name,
         t.total, t.applied, (t.total - t.applied)::numeric(18,2),
         case when t.due_date is null or t.due_date >= p_as_of then 0
              else (p_as_of - t.due_date) end,
         t.vat, (t.total - t.vat)::numeric(18,2)
  from totals t
  where t.total - t.applied > 0
  order by t.contact_name, t.doc_date
$$;

-- Recreated functions keep default-closed grants (P4-07/P4-08 discipline).
revoke all on function public.open_items(uuid, text, date) from public, anon, authenticated;
grant execute on function public.open_items(uuid, text, date) to authenticated;
