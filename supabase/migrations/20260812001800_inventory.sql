-- Inventory & the purchases cycle: FIFO cost layers, COGS at the moment of
-- sale, and two new document types that finish the transaction-cycle split:
--
--   purchase  "Purchases / receipts" — goods arriving. Item lines create FIFO
--             cost layers and post DR 1200 Inventory (+ input VAT) against AP,
--             or against cash when settled immediately.
--   expense   Directly-paid operating costs — DR expense lines (+ input VAT),
--             CR cash. Distinct from a Payment, which settles a payable.
--
-- Invoice lines may now carry an item + quantity: the engine consumes FIFO
-- layers and posts DR 5000 Cost of sales / CR 1200 Inventory alongside the
-- revenue lines, in the same entry.
--
-- The FIFO invariant this migration is built around: the sum of remaining
-- layer values ALWAYS equals the 1200 GL balance. Two rules make it hold:
--   * a layer's value is the exact 2dp amount posted to 1200 at receipt;
--   * the consumption that exhausts a layer takes the layer's full residual
--     value, so per-consumption rounding can never strand a centavo.
-- Direct document lines on 1200 are blocked (inventory moves through items),
-- and stock adjustments post through their own RPC.

-- ------------------------------------------------------------------ items
create table if not exists public.items (
  id                uuid primary key default gen_random_uuid(),
  client_id         uuid not null references public.clients(id),
  sku               text not null check (length(btrim(sku)) between 1 and 40),
  name              text not null check (length(btrim(name)) between 1 and 160),
  uom               text not null default 'pc' check (length(uom) between 1 and 16),
  income_account_id uuid,
  sales_price       numeric(18,2) check (sales_price is null or sales_price >= 0),
  purchase_cost     numeric(18,2) check (purchase_cost is null or purchase_cost >= 0),
  archived_at       timestamptz,
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (client_id, sku),
  unique (id, client_id),
  foreign key (income_account_id, client_id) references public.accounts (id, client_id)
);
create index if not exists items_client_idx on public.items (client_id);

drop trigger if exists trg_items_updated_at on public.items;
create trigger trg_items_updated_at
  before update on public.items
  for each row execute function app.set_updated_at();

drop trigger if exists trg_items_created_by on public.items;
create trigger trg_items_created_by
  before insert on public.items
  for each row execute function app.force_created_by();

alter table public.items enable row level security;

drop policy if exists items_select on public.items;
create policy items_select on public.items
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

drop policy if exists items_insert on public.items;
create policy items_insert on public.items
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));

drop policy if exists items_update on public.items;
create policy items_update on public.items
  for update to authenticated
  using ((select app.can_write_client(client_id)))
  with check ((select app.can_write_client(client_id)));

grant select on public.items to authenticated;
grant insert (client_id, sku, name, uom, income_account_id, sales_price, purchase_cost)
  on public.items to authenticated;
grant update (sku, name, uom, income_account_id, sales_price, purchase_cost, archived_at)
  on public.items to authenticated;

-- ------------------------------------------------------- FIFO cost layers
-- One layer per receiving event (purchase line or positive adjustment).
-- cost_total is the exact money posted to 1200 for the layer; unit_cost is
-- informational precision for mid-layer consumption pricing.
create table if not exists public.inventory_layers (
  id                   uuid primary key default gen_random_uuid(),
  client_id            uuid not null,
  item_id              uuid not null,
  acquired_date        date not null,
  qty_in               numeric(18,4) not null check (qty_in > 0),
  qty_remaining        numeric(18,4) not null check (qty_remaining >= 0),
  unit_cost            numeric(18,6) not null check (unit_cost >= 0),
  cost_total           numeric(18,2) not null check (cost_total >= 0),
  source_document_id   uuid,
  source_adjustment_id uuid,
  created_at           timestamptz not null default now(),
  check (qty_remaining <= qty_in),
  foreign key (item_id, client_id) references public.items (id, client_id),
  foreign key (source_document_id, client_id) references public.documents (id, client_id)
);
create index if not exists inventory_layers_item_idx
  on public.inventory_layers (item_id, acquired_date, created_at);
create index if not exists inventory_layers_document_idx
  on public.inventory_layers (source_document_id);

alter table public.inventory_layers enable row level security;

drop policy if exists inventory_layers_select on public.inventory_layers;
create policy inventory_layers_select on public.inventory_layers
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

-- Engine-written only.
grant select on public.inventory_layers to authenticated;

create table if not exists public.layer_consumptions (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null,
  layer_id      uuid not null references public.inventory_layers(id),
  document_id   uuid,
  adjustment_id uuid,
  move_date     date not null,
  qty           numeric(18,4) not null check (qty > 0),
  cost          numeric(18,2) not null check (cost >= 0),
  created_at    timestamptz not null default now(),
  foreign key (document_id, client_id) references public.documents (id, client_id)
);
create index if not exists layer_consumptions_layer_idx on public.layer_consumptions (layer_id);
create index if not exists layer_consumptions_document_idx on public.layer_consumptions (document_id);

alter table public.layer_consumptions enable row level security;

drop policy if exists layer_consumptions_select on public.layer_consumptions;
create policy layer_consumptions_select on public.layer_consumptions
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

grant select on public.layer_consumptions to authenticated;

-- ------------------------------------------------------ stock adjustments
create table if not exists public.stock_adjustments (
  id         uuid primary key default gen_random_uuid(),
  client_id  uuid not null,
  item_id    uuid not null,
  adj_date   date not null,
  qty_delta  numeric(18,4) not null check (qty_delta <> 0),
  unit_cost  numeric(18,6) check (qty_delta < 0 or unit_cost is not null),
  account_id uuid not null,
  memo       text not null default '',
  entry_id   uuid,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key (item_id, client_id) references public.items (id, client_id),
  foreign key (account_id, client_id) references public.accounts (id, client_id),
  foreign key (entry_id, client_id) references public.journal_entries (id, client_id)
);
create index if not exists stock_adjustments_item_idx on public.stock_adjustments (item_id);

alter table public.stock_adjustments enable row level security;

drop policy if exists stock_adjustments_select on public.stock_adjustments;
create policy stock_adjustments_select on public.stock_adjustments
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

-- RPC-written only.
grant select on public.stock_adjustments to authenticated;

-- --------------------------------------------- document shape extensions
alter table public.documents drop constraint if exists documents_doc_type_check;
alter table public.documents add constraint documents_doc_type_check
  check (doc_type in ('invoice', 'bill', 'receipt', 'disbursement', 'purchase', 'expense'));

alter table public.journal_entries drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries add constraint journal_entries_source_type_check
  check (source_type in ('manual', 'opening_balance', 'reversal',
                         'invoice', 'bill', 'receipt', 'disbursement',
                         'purchase', 'expense'));

alter table public.document_lines add column if not exists item_id uuid;
alter table public.document_lines add column if not exists qty numeric(18,4);
do $$ begin
  alter table public.document_lines add constraint document_lines_item_fk
    foreign key (item_id, client_id) references public.items (id, client_id);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.document_lines add constraint document_lines_item_qty_check
    check ((item_id is null and qty is null) or (item_id is not null and qty > 0));
exception when duplicate_object then null; end $$;

grant insert (item_id, qty) on public.document_lines to authenticated;
grant update (item_id, qty) on public.document_lines to authenticated;

-- ------------------------------------------------- line-account guard v3
-- 1200 joins the blocked list for NON-item lines: hand-posting the inventory
-- control account would break "valuation == GL 1200". Item lines are the
-- sanctioned path (the engine posts 1200 itself).
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
  if exists (
    select 1
    from public.document_lines l
    join public.accounts a on a.id = l.account_id
    where l.document_id = p_document_id
      and l.item_id is null
      and a.code = '1200'
  ) then
    raise exception 'inventory moves through item lines — pick an item instead of posting to 1200 directly';
  end if;
  if exists (
    select 1
    from public.document_lines l
    join public.accounts a on a.id = l.account_id
    where l.document_id = p_document_id
      and a.code in (select tc.account_code from public.tax_codes tc where tc.client_id = p_client_id)
  ) then
    raise exception 'document lines cannot post directly to a tax account — pick a tax code on the line and the engine posts the tax';
  end if;
end $$;

-- ------------------------------------------------------ FIFO consumption
-- Consumes p_qty of an item oldest-layer-first. Returns the exact COGS.
-- Callers hold the client's document advisory lock, so layer math is
-- serialized per client. The exhausting consumption takes the layer's full
-- residual value — rounding can never strand value in an empty layer.
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
  v_consumed_so_far numeric(18,2);
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
    if v_take = r.qty_remaining then
      -- exhausting: take the layer's entire residual value
      select coalesce(sum(c.cost), 0) into v_consumed_so_far
      from public.layer_consumptions c where c.layer_id = r.id;
      v_cost := r.cost_total - v_consumed_so_far;
    else
      v_cost := round(v_take * r.unit_cost, 2);
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

-- ------------------------------------------------------- the issuing gate
-- Adds: purchase and expense shapes; item lines on invoices consume FIFO and
-- post the COGS pair; item lines on purchases create layers and post to the
-- 1200 control account. Everything else unchanged from 20260812001600.
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
  if v_doc.status <> 'draft' then
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

-- ---------------------------------------------------- voiding with stock
-- Voiding an invoice puts the consumed quantities back on their layers.
-- Voiding a purchase retracts its layers — only while nothing has been sold
-- from them.
create or replace function public.void_document(p_document_id uuid, p_date date default null) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_doc record;
  r record;
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

  perform pg_advisory_xact_lock(hashtextextended(v_doc.client_id::text, 2));

  if v_doc.doc_type = 'invoice' then
    for r in
      select c.id, c.layer_id, c.qty
      from public.layer_consumptions c
      where c.document_id = p_document_id
    loop
      update public.inventory_layers
         set qty_remaining = qty_remaining + r.qty
       where id = r.layer_id;
      delete from public.layer_consumptions where id = r.id;
    end loop;
  elsif v_doc.doc_type = 'purchase' then
    if exists (
      select 1 from public.inventory_layers l
      where l.source_document_id = p_document_id
        and (l.qty_remaining < l.qty_in
             or exists (select 1 from public.layer_consumptions c where c.layer_id = l.id))
    ) then
      raise exception 'stock received on this purchase has already been sold — void those sales first';
    end if;
    delete from public.inventory_layers where source_document_id = p_document_id;
  end if;

  perform public.reverse_entry(v_doc.entry_id, p_date,
    'Void ' || v_doc.doc_type || ' #' || v_doc.doc_no);

  update public.documents
     set status = 'voided', voided_at = now()
   where id = p_document_id;
end $$;

revoke all on function public.void_document(uuid, date) from public, anon, authenticated;
grant execute on function public.void_document(uuid, date) to authenticated;

-- --------------------------------------------------- stock adjustment RPC
-- Positive delta: new layer at the given unit cost, DR 1200 / CR offset.
-- Negative delta: FIFO consumption, DR offset / CR 1200. Opening stock is a
-- positive adjustment against an equity account. Corrections are further
-- adjustments — adjustments have no void.
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
  values (p_client_id, p_date, 'manual',
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

revoke all on function public.post_stock_adjustment(uuid, uuid, date, numeric, numeric, uuid, text)
  from public, anon, authenticated;
grant execute on function public.post_stock_adjustment(uuid, uuid, date, numeric, numeric, uuid, text)
  to authenticated;

-- ---------------------------------------------- open items: sides, types
-- 'receivable' = invoices; 'payable' = bills + purchases. The legacy exact
-- doc_type values keep working. Adds the target's doc_type so payment screens
-- can label BILL-n vs PR-n. Return type changes, so drop and recreate the
-- reader chain.
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
  days_overdue int
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

-- Dashboard: AP now includes purchases on account.
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
    from public.open_items(p_client_id, 'receivable', current_date)
  ),
  ap as (
    select coalesce(sum(balance), 0)::numeric(18,2) as open_total
    from public.open_items(p_client_id, 'payable', current_date)
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

-- Documents with their own subsidiary book stay out of the general journal.
create or replace function public.general_journal_book(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (
  entry_date date,
  entry_no bigint,
  source_type text,
  memo text,
  line_no smallint,
  code text,
  account text,
  debit numeric(18,2),
  credit numeric(18,2)
)
language sql stable
set search_path = ''
as $$
  select e.entry_date, e.entry_no, e.source_type, e.memo,
         l.line_no, a.code, a.name, l.debit, l.credit
  from public.journal_entries e
  join public.journal_lines l on l.entry_id = e.id
  join public.accounts a on a.id = l.account_id
  where e.client_id = p_client_id
    and e.status = 'posted'
    and e.entry_date between p_date_from and p_date_to
    and coalesce(e.source_type, 'manual') not in ('invoice', 'bill', 'purchase', 'expense')
    and not exists (
      select 1 from public.journal_lines cl
      join public.accounts ca on ca.id = cl.account_id
      where cl.entry_id = e.id and ca.code like '1000%'
    )
  order by e.entry_date, e.entry_no, l.line_no
$$;

-- Purchases book: bills, purchases, and directly-paid expenses — the complete
-- input-VAT record. Return gains a ref column (BILL-/PR-/EXP-), so the old
-- signature is dropped first.
drop function if exists public.purchases_book(uuid, date, date);
create function public.purchases_book(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (
  doc_date date,
  ref text,
  supplier text,
  tin text,
  status text,
  gross numeric(18,2),
  exempt numeric(18,2),
  taxable numeric(18,2),
  input_vat numeric(18,2)
)
language sql stable
set search_path = ''
as $$
  select d.doc_date,
         case d.doc_type when 'purchase' then 'PR-' when 'expense' then 'EXP-' else 'BILL-' end || d.doc_no,
         c.name, coalesce(c.tin, ''), d.status,
         (z.live * (coalesce(u.untagged, 0) + coalesce(t.exempt, 0)
          + coalesce(t.taxable, 0) + coalesce(t.vat, 0)))::numeric(18,2),
         (z.live * (coalesce(u.untagged, 0) + coalesce(t.exempt, 0)))::numeric(18,2),
         (z.live * coalesce(t.taxable, 0))::numeric(18,2),
         (z.live * coalesce(t.vat, 0))::numeric(18,2)
  from public.documents d
  join public.contacts c on c.id = d.contact_id
  cross join lateral (select case when d.status = 'voided' then 0 else 1 end as live) z
  left join lateral (
    select sum(l.amount) as untagged
    from public.document_lines l
    where l.document_id = d.id and l.tax_code_id is null
  ) u on true
  left join lateral (
    select sum(t.base) filter (where tc.vat_class = 'exempt')  as exempt,
           sum(t.base) filter (where tc.vat_class = 'taxable') as taxable,
           sum(t.amount)                                       as vat
    from public.document_taxes t
    join public.tax_codes tc on tc.id = t.tax_code_id
    where t.document_id = d.id and tc.kind = 'input_vat'
  ) t on true
  where d.client_id = p_client_id
    and d.doc_type in ('bill', 'purchase', 'expense')
    and d.status in ('issued', 'voided')
    and d.doc_date between p_date_from and p_date_to
  order by d.doc_date, d.doc_no
$$;

-- --------------------------------------------------- valuation & stock card
-- The invariant: sum(value) over this function == the 1200 GL balance.
create or replace function public.inventory_valuation(p_client_id uuid) returns table (
  item_id uuid,
  sku text,
  name text,
  uom text,
  qty_on_hand numeric(18,4),
  value numeric(18,2),
  avg_cost numeric(18,6)
)
language sql stable
set search_path = ''
as $$
  select i.id, i.sku, i.name, i.uom,
         coalesce(sum(l.qty_remaining), 0)::numeric(18,4),
         coalesce(sum(l.cost_total - consumed.cost), 0)::numeric(18,2),
         case when coalesce(sum(l.qty_remaining), 0) > 0
              then (coalesce(sum(l.cost_total - consumed.cost), 0)
                    / sum(l.qty_remaining))::numeric(18,6)
              else 0 end
  from public.items i
  left join public.inventory_layers l on l.item_id = i.id
  left join lateral (
    select coalesce(sum(c.cost), 0) as cost
    from public.layer_consumptions c where c.layer_id = l.id
  ) consumed on true
  where i.client_id = p_client_id
  group by i.id, i.sku, i.name, i.uom
  order by i.sku
$$;

-- Per-item movement history with running quantity and value.
create or replace function public.stock_card(
  p_client_id uuid,
  p_item_id uuid,
  p_date_from date,
  p_date_to date
) returns table (
  move_date date,
  ref text,
  memo text,
  qty_in numeric(18,4),
  qty_out numeric(18,4),
  cost numeric(18,2),
  running_qty numeric(18,4),
  running_value numeric(18,2)
)
language sql stable
set search_path = ''
as $$
  with moves as (
    select l.acquired_date as move_date, l.created_at,
           case
             when l.source_document_id is not null then
               (select 'PR-' || d.doc_no from public.documents d where d.id = l.source_document_id)
             else 'ADJ'
           end as ref,
           coalesce((select d.memo from public.documents d where d.id = l.source_document_id),
                    (select a.memo from public.stock_adjustments a where a.id = l.source_adjustment_id),
                    '') as memo,
           l.qty_in as qty_in, 0::numeric as qty_out, l.cost_total as cost
    from public.inventory_layers l
    where l.client_id = p_client_id and l.item_id = p_item_id
    union all
    select c.move_date, c.created_at,
           case
             when c.document_id is not null then
               (select case d.doc_type when 'invoice' then 'INV-' else '' end || d.doc_no
                from public.documents d where d.id = c.document_id)
             else 'ADJ'
           end,
           coalesce((select d.memo from public.documents d where d.id = c.document_id),
                    (select a.memo from public.stock_adjustments a where a.id = c.adjustment_id),
                    ''),
           0::numeric, c.qty, c.cost
    from public.layer_consumptions c
    join public.inventory_layers l on l.id = c.layer_id
    where c.client_id = p_client_id and l.item_id = p_item_id
  ),
  ordered as (
    select m.*,
           sum(m.qty_in - m.qty_out) over w as run_qty,
           sum(case when m.qty_in > 0 then m.cost else -m.cost end) over w as run_value
    from moves m
    window w as (order by m.move_date, m.created_at rows between unbounded preceding and current row)
  )
  select o.move_date, o.ref, o.memo, o.qty_in, o.qty_out, o.cost,
         o.run_qty::numeric(18,4), o.run_value::numeric(18,2)
  from ordered o
  where o.move_date between p_date_from and p_date_to
  order by o.move_date, o.created_at
$$;

revoke all on function
  public.inventory_valuation(uuid),
  public.stock_card(uuid, uuid, date, date)
from public, anon, authenticated;
grant execute on function
  public.inventory_valuation(uuid),
  public.stock_card(uuid, uuid, date, date)
to authenticated;
