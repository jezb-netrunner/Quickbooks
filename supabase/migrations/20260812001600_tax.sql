-- Phase 5: tax profile, VAT/EWT automation, BIR books of accounts.
--
-- Principles (spec non-negotiable #4):
--   * No tax RATE lives in code. Rates are rows in tax_code_rates, an
--     append-friendly, effective-dated reference table per client. The seed
--     values are provisional and editable — the CPA verifies them.
--   * The posting function generates every VAT/EWT journal line; the browser
--     never types tax lines by hand.
--   * Amounts entered on document lines can be tax-INCLUSIVE (net extracted
--     by amount / (1 + rate)) or tax-EXCLUSIVE (tax added on top), chosen per
--     document. Computed bases and tax are frozen into document_taxes at
--     issue, so later rate changes never alter posted documents.
--   * Withholding follows PH practice: recognized at the payment document.
--     A customer withholding from our collection posts to Creditable
--     withholding tax (asset 1320, supported by their 2307); withholding we
--     retain from a vendor payment posts to EWT payable (2230, remitted via
--     0619-E/1601-EQ).
--   * Under the EOPT Act (RA 11976) the invoice is the primary document for
--     BOTH cash and credit sales, so an invoice may settle straight to a
--     cash/bank account at issue: debit cash instead of AR, born settled,
--     never an open item.

-- ------------------------------------------------------ client tax profile
create table if not exists public.client_tax_profiles (
  client_id  uuid primary key references public.clients(id),
  regime     text not null default 'non_vat' check (regime in ('vat', 'non_vat')),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_client_tax_profiles_updated_at on public.client_tax_profiles;
create trigger trg_client_tax_profiles_updated_at
  before update on public.client_tax_profiles
  for each row execute function app.set_updated_at();

alter table public.client_tax_profiles enable row level security;

drop policy if exists client_tax_profiles_select on public.client_tax_profiles;
create policy client_tax_profiles_select on public.client_tax_profiles
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

drop policy if exists client_tax_profiles_insert on public.client_tax_profiles;
create policy client_tax_profiles_insert on public.client_tax_profiles
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));

drop policy if exists client_tax_profiles_update on public.client_tax_profiles;
create policy client_tax_profiles_update on public.client_tax_profiles
  for update to authenticated
  using ((select app.can_write_client(client_id)))
  with check ((select app.can_write_client(client_id)));

grant select on public.client_tax_profiles to authenticated;
grant insert (client_id, regime) on public.client_tax_profiles to authenticated;
grant update (regime) on public.client_tax_profiles to authenticated;

-- -------------------------------------------------------------- tax codes
-- kind decides where the engine uses the code and which side it posts:
--   output_vat            invoice lines            -> credit account_code
--   input_vat             bill/disbursement lines  -> debit  account_code
--   withholding_sales     receipts  (customer withheld from us) -> debit
--   withholding_purchases disbursements (we withhold from vendor) -> credit
-- vat_class feeds the BIR sales/purchases book columns.
create table if not exists public.tax_codes (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references public.clients(id),
  code         text not null check (length(btrim(code)) between 1 and 24),
  name         text not null check (length(btrim(name)) between 1 and 120),
  kind         text not null check (kind in
                 ('output_vat', 'input_vat', 'withholding_sales', 'withholding_purchases')),
  vat_class    text check (vat_class in ('taxable', 'zero_rated', 'exempt')),
  account_code text not null,   -- chart code the engine posts this tax to
  atc          text not null default '',   -- BIR alphanumeric tax code label
  active       boolean not null default true,
  created_by   uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (client_id, code),
  unique (id, client_id),
  check ((kind in ('output_vat', 'input_vat')) = (vat_class is not null))
);
create index if not exists tax_codes_client_idx on public.tax_codes (client_id);

drop trigger if exists trg_tax_codes_updated_at on public.tax_codes;
create trigger trg_tax_codes_updated_at
  before update on public.tax_codes
  for each row execute function app.set_updated_at();

drop trigger if exists trg_tax_codes_created_by on public.tax_codes;
create trigger trg_tax_codes_created_by
  before insert on public.tax_codes
  for each row execute function app.force_created_by();

alter table public.tax_codes enable row level security;

drop policy if exists tax_codes_select on public.tax_codes;
create policy tax_codes_select on public.tax_codes
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

drop policy if exists tax_codes_insert on public.tax_codes;
create policy tax_codes_insert on public.tax_codes
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));

drop policy if exists tax_codes_update on public.tax_codes;
create policy tax_codes_update on public.tax_codes
  for update to authenticated
  using ((select app.can_write_client(client_id)))
  with check ((select app.can_write_client(client_id)));

grant select on public.tax_codes to authenticated;
grant insert (client_id, code, name, kind, vat_class, account_code, atc, active)
  on public.tax_codes to authenticated;
grant update (name, vat_class, account_code, atc, active) on public.tax_codes to authenticated;

-- Effective-dated rates: the versioned reference table. Changing a rate means
-- INSERTING a new row effective from a date; history stays. Posted documents
-- are additionally insulated by document_taxes snapshots.
create table if not exists public.tax_code_rates (
  id             uuid primary key default gen_random_uuid(),
  tax_code_id    uuid not null,
  client_id      uuid not null,
  effective_from date not null,
  rate           numeric(7,4) not null check (rate >= 0 and rate <= 1),
  created_at     timestamptz not null default now(),
  unique (tax_code_id, effective_from),
  foreign key (tax_code_id, client_id) references public.tax_codes (id, client_id) on delete cascade
);
create index if not exists tax_code_rates_code_idx on public.tax_code_rates (tax_code_id);

alter table public.tax_code_rates enable row level security;

drop policy if exists tax_code_rates_select on public.tax_code_rates;
create policy tax_code_rates_select on public.tax_code_rates
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

drop policy if exists tax_code_rates_insert on public.tax_code_rates;
create policy tax_code_rates_insert on public.tax_code_rates
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));

drop policy if exists tax_code_rates_update on public.tax_code_rates;
create policy tax_code_rates_update on public.tax_code_rates
  for update to authenticated
  using ((select app.can_write_client(client_id)))
  with check ((select app.can_write_client(client_id)));

grant select on public.tax_code_rates to authenticated;
grant insert (tax_code_id, client_id, effective_from, rate) on public.tax_code_rates to authenticated;
grant update (effective_from, rate) on public.tax_code_rates to authenticated;

-- The rate in force on a date. Raises when a code has no rate yet — a tax
-- code without an effective rate must never silently compute zero.
create or replace function app.tax_rate(p_tax_code_id uuid, p_on date) returns numeric
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_rate numeric;
begin
  select r.rate into v_rate
  from public.tax_code_rates r
  where r.tax_code_id = p_tax_code_id and r.effective_from <= p_on
  order by r.effective_from desc
  limit 1;
  if v_rate is null then
    raise exception 'tax code has no rate effective on % — add one on the tax codes screen', p_on;
  end if;
  return v_rate;
end $$;

-- ---------------------------------------------- document columns for taxes
alter table public.documents add column if not exists amounts_include_tax boolean not null default false;
alter table public.documents add column if not exists wht_tax_code_id uuid;
alter table public.documents add column if not exists wht_base numeric(18,2);
do $$ begin
  alter table public.documents add constraint documents_wht_pair_check
    check ((wht_tax_code_id is null) = (wht_base is null));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.documents add constraint documents_wht_base_check
    check (wht_base is null or wht_base > 0);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.documents add constraint documents_wht_fk
    foreign key (wht_tax_code_id, client_id) references public.tax_codes (id, client_id);
exception when duplicate_object then null; end $$;

grant insert (amounts_include_tax, wht_tax_code_id, wht_base) on public.documents to authenticated;
grant update (amounts_include_tax, wht_tax_code_id, wht_base) on public.documents to authenticated;

alter table public.document_lines add column if not exists tax_code_id uuid;
do $$ begin
  alter table public.document_lines add constraint document_lines_tax_fk
    foreign key (tax_code_id, client_id) references public.tax_codes (id, client_id);
exception when duplicate_object then null; end $$;

grant insert (tax_code_id) on public.document_lines to authenticated;
grant update (tax_code_id) on public.document_lines to authenticated;

-- ------------------------------------------------- frozen tax computations
-- Written by issue_document only; the columns the BIR books and totals read.
-- One row per (document, tax code): base is the tax-exclusive amount the tax
-- was computed on, amount the computed tax. Rate-zero classes (exempt,
-- zero-rated) still record their base so the books can classify columns.
create table if not exists public.document_taxes (
  id          uuid primary key default gen_random_uuid(),
  document_id uuid not null,
  client_id   uuid not null,
  tax_code_id uuid not null,
  base        numeric(18,2) not null,
  amount      numeric(18,2) not null,
  unique (document_id, tax_code_id),
  foreign key (document_id, client_id) references public.documents (id, client_id) on delete cascade,
  foreign key (tax_code_id, client_id) references public.tax_codes (id, client_id)
);
create index if not exists document_taxes_document_idx on public.document_taxes (document_id);

-- Generalize the child-freeze guard to cover document_taxes as well.
create or replace function app.assert_document_children_mutable() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_parent uuid;
  v_status text;
begin
  -- Each child table names its parent differently; only the taken branch is
  -- evaluated, so the record field access stays valid per table.
  if tg_table_name = 'document_applications' then
    v_parent := coalesce(new.paying_document_id, old.paying_document_id);
  else
    v_parent := coalesce(new.document_id, old.document_id);
  end if;
  select d.status into v_status from public.documents d where d.id = v_parent;
  if v_status is distinct from 'draft' and v_status is not null then
    raise exception 'lines and applications are frozen once the document is issued';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_document_taxes_frozen on public.document_taxes;
create trigger trg_document_taxes_frozen
  before insert or update or delete on public.document_taxes
  for each row execute function app.assert_document_children_mutable();

alter table public.document_taxes enable row level security;

drop policy if exists document_taxes_select on public.document_taxes;
create policy document_taxes_select on public.document_taxes
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

-- No insert/update/delete policies: only the SECURITY DEFINER engine writes.
grant select on public.document_taxes to authenticated;

-- --------------------------------------------------------------- seeding
-- Starter codes per regime. RATES ARE PROVISIONAL SEEDS the CPA verifies and
-- maintains on the tax codes screen — the engine only ever reads
-- tax_code_rates. Idempotent: existing codes are left untouched.
create or replace function public.seed_client_tax_codes(p_client_id uuid, p_regime text) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not (select app.can_write_client(p_client_id)) then
    raise exception 'not authorized';
  end if;
  if p_regime not in ('vat', 'non_vat') then
    raise exception 'regime must be vat or non_vat';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_client_id::text, 3));

  insert into public.client_tax_profiles (client_id, regime)
  values (p_client_id, p_regime)
  on conflict (client_id) do update set regime = excluded.regime;

  insert into public.tax_codes (client_id, code, name, kind, vat_class, account_code, atc)
  select p_client_id, s.code, s.name, s.kind, s.vat_class, s.account_code, s.atc
  from (values
    -- VAT codes only for VAT-registered clients
    ('VAT12-OUT', 'Output VAT 12%',                    'output_vat', 'taxable',    '2200', ''),
    ('VAT0-OUT',  'Zero-rated sales',                  'output_vat', 'zero_rated', '2200', ''),
    ('VATX-OUT',  'VAT-exempt sales',                  'output_vat', 'exempt',     '2200', ''),
    ('VAT12-IN',  'Input VAT 12%',                     'input_vat',  'taxable',    '1310', '')
  ) as s (code, name, kind, vat_class, account_code, atc)
  where p_regime = 'vat'
  on conflict (client_id, code) do nothing;

  insert into public.tax_codes (client_id, code, name, kind, vat_class, account_code, atc)
  select p_client_id, s.code, s.name, s.kind, null, s.account_code, s.atc
  from (values
    -- Customer withheld from our collection (their 2307 to us) -> asset 1320
    ('CWT-GDS',   'Customer withheld — goods 1%',        'withholding_sales',     '1320', 'WC158'),
    ('CWT-SVC',   'Customer withheld — services 2%',     'withholding_sales',     '1320', 'WC160'),
    ('CWT-PRO10', 'Customer withheld — professional 10%','withholding_sales',     '1320', 'WI011'),
    -- We withhold from vendor payments (our 2307 to them) -> liability 2230
    ('EWT-GDS',   'EWT — purchase of goods 1%',          'withholding_purchases', '2230', 'WC158'),
    ('EWT-SVC',   'EWT — purchase of services 2%',       'withholding_purchases', '2230', 'WC160'),
    ('EWT-RENT',  'EWT — rentals 5%',                    'withholding_purchases', '2230', 'WC100'),
    ('EWT-PRO5',  'EWT — professional fees 5%',          'withholding_purchases', '2230', 'WI010'),
    ('EWT-PRO10', 'EWT — professional fees 10%',         'withholding_purchases', '2230', 'WI011')
  ) as s (code, name, kind, account_code, atc)
  on conflict (client_id, code) do nothing;

  -- One opening rate per code that has none yet, effective since always.
  insert into public.tax_code_rates (tax_code_id, client_id, effective_from, rate)
  select tc.id, tc.client_id, date '1900-01-01',
         case tc.code
           when 'VAT12-OUT' then 0.12
           when 'VAT12-IN'  then 0.12
           when 'CWT-GDS'   then 0.01
           when 'CWT-SVC'   then 0.02
           when 'CWT-PRO10' then 0.10
           when 'EWT-GDS'   then 0.01
           when 'EWT-SVC'   then 0.02
           when 'EWT-RENT'  then 0.05
           when 'EWT-PRO5'  then 0.05
           when 'EWT-PRO10' then 0.10
           else 0
         end
  from public.tax_codes tc
  where tc.client_id = p_client_id
    and not exists (select 1 from public.tax_code_rates r where r.tax_code_id = tc.id)
  on conflict (tax_code_id, effective_from) do nothing;
end $$;

revoke all on function public.seed_client_tax_codes(uuid, text) from public, anon, authenticated;
grant execute on function public.seed_client_tax_codes(uuid, text) to authenticated;

-- -------------------------------------------- line account guard, extended
-- Document lines must not point at the AR/AP control accounts (those sides
-- post automatically) nor at any account a tax code posts to (the engine
-- generates tax lines; typing them by hand would double-post).
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
      and a.code in (select tc.account_code from public.tax_codes tc where tc.client_id = p_client_id)
  ) then
    raise exception 'document lines cannot post directly to a tax account — pick a tax code on the line and the engine posts the tax';
  end if;
end $$;

-- ------------------------------------------------------- document totals
-- Gross value of an invoice/bill for settlement purposes: line amounts plus
-- computed tax when amounts were entered tax-EXCLUSIVE (inclusive lines are
-- already gross). Reads the frozen document_taxes, so it is stable however
-- rates change later.
create or replace function app.document_total(p_document_id uuid) returns numeric
language sql stable security definer
set search_path = ''
as $$
  select (coalesce((select sum(l.amount) from public.document_lines l
                    where l.document_id = d.id), 0)
        + case when d.amounts_include_tax then 0
               else coalesce((select sum(t.amount)
                              from public.document_taxes t
                              join public.tax_codes tc on tc.id = t.tax_code_id
                              where t.document_id = d.id
                                and tc.kind in ('output_vat', 'input_vat')), 0)
          end)::numeric(18,2)
  from public.documents d
  where d.id = p_document_id
$$;

-- ------------------------------------------------------- the issuing gate
-- Full rewrite for the tax layer. Same skeleton as 20260812001400: assign the
-- per-type number, build the entry for the document's shape, post through
-- post_entry. New here:
--   * per-line VAT (inclusive or exclusive), lines grouped per tax code and
--     frozen into document_taxes
--   * invoices may settle straight to cash (bank_account_id set): debit the
--     bank account instead of AR
--   * withholding on payments: receipts debit CWT (customer withheld),
--     disbursements credit EWT payable (we withheld)
-- Balance is by construction: gross totals are derived from the same rounded
-- per-line nets and taxes the credit/debit lines use.
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
  v_wht_amt numeric(18,2) := 0;
  v_wht_kind text;
  v_wht_account text;
  v_ar uuid;
  v_ap uuid;
  v_entry uuid;
  v_no bigint;
  v_line_no smallint := 0;
  v_net numeric(18,2);
  v_rate numeric;
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

  -- Which tax kind may appear on this document's lines.
  v_line_kind := case v_doc.doc_type
    when 'invoice' then 'output_vat'
    when 'bill' then 'input_vat'
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
  -- carry vendor EWT; invoices and bills carry none.
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
    if v_doc.doc_type in ('invoice', 'bill') then
      raise exception 'withholding is recorded on the payment document, not the invoice or bill';
    end if;
    v_wht_amt := round(v_doc.wht_base * app.tax_rate(v_doc.wht_tax_code_id, v_doc.doc_date), 2);
    if v_wht_amt <= 0 then
      raise exception 'the withholding base and rate compute to zero — remove the code or fix the base';
    end if;
  end if;

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

  -- Per-line net/tax for the docs that carry lines, journaled line by line so
  -- the grouped tax insert below reuses the exact same rounding.
  if v_doc.doc_type = 'invoice' then
    v_line_no := 1;   -- slot 1 reserved for the AR/cash debit inserted after totals
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
      values (v_entry, v_doc.client_id, v_line_no, r.account_id, 0, v_net);
    end loop;
    -- Output VAT credit per tax code, and the frozen snapshot.
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
    -- The gross debit: straight to cash for a cash sale, else AR.
    insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
    values (v_entry, v_doc.client_id, 1,
            coalesce(v_doc.bank_account_id, app.control_account(v_doc.client_id, '1100')),
            v_net_total + v_vat_total, 0);

  elsif v_doc.doc_type = 'bill' then
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
    v_ap := app.control_account(v_doc.client_id, '2000');
    insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
    values (v_entry, v_doc.client_id, v_line_no + 1, v_ap, 0, v_net_total + v_vat_total);

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

-- ------------------------------------------------ open items, tax-aware
-- Totals include exclusive-entry VAT (from the frozen snapshot), and
-- cash-settled invoices (bank_account_id set) are born settled — they never
-- appear as receivables. aging() reads through open_items and needs no change.
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
      and d.doc_type = p_doc_type
      and d.status = 'issued'
      and d.doc_date <= p_as_of
      and d.bank_account_id is null
  )
  select t.id, t.doc_no, t.doc_date, t.due_date, t.contact_id, t.contact_name,
         t.total, t.applied, (t.total - t.applied)::numeric(18,2),
         case when t.due_date is null or t.due_date >= p_as_of then 0
              else (p_as_of - t.due_date) end
  from totals t
  where t.total - t.applied > 0
  order by t.contact_name, t.doc_date
$$;

-- ----------------------------------------------------- BIR books of accounts
-- All SECURITY INVOKER (caller's RLS), all date-ranged, all exportable.
-- Column mappings follow the chart template's control codes (1100 AR, 2000
-- AP, 1000% cash, plus the tax accounts the seeds reference) — that is
-- structural layout, not a tax rate.

-- Subsidiary sales journal: one row per issued invoice, VAT columns split by
-- the tax codes' vat_class. Untagged lines count as exempt.
create or replace function public.sales_book(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (
  doc_date date,
  doc_no bigint,
  customer text,
  tin text,
  status text,
  gross numeric(18,2),
  exempt numeric(18,2),
  zero_rated numeric(18,2),
  taxable numeric(18,2),
  output_vat numeric(18,2)
)
language sql stable
set search_path = ''
as $$
  select d.doc_date, d.doc_no, c.name, coalesce(c.tin, ''), d.status,
         (coalesce(u.untagged, 0) + coalesce(t.exempt, 0) + coalesce(t.zero_rated, 0)
          + coalesce(t.taxable, 0) + coalesce(t.vat, 0))::numeric(18,2),
         (coalesce(u.untagged, 0) + coalesce(t.exempt, 0))::numeric(18,2),
         coalesce(t.zero_rated, 0)::numeric(18,2),
         coalesce(t.taxable, 0)::numeric(18,2),
         coalesce(t.vat, 0)::numeric(18,2)
  from public.documents d
  join public.contacts c on c.id = d.contact_id
  left join lateral (
    select sum(l.amount) as untagged
    from public.document_lines l
    where l.document_id = d.id and l.tax_code_id is null
  ) u on true
  left join lateral (
    select sum(t.base) filter (where tc.vat_class = 'exempt')     as exempt,
           sum(t.base) filter (where tc.vat_class = 'zero_rated') as zero_rated,
           sum(t.base) filter (where tc.vat_class = 'taxable')    as taxable,
           sum(t.amount) filter (where tc.kind = 'output_vat')    as vat
    from public.document_taxes t
    join public.tax_codes tc on tc.id = t.tax_code_id
    where t.document_id = d.id and tc.kind = 'output_vat'
  ) t on true
  where d.client_id = p_client_id
    and d.doc_type = 'invoice'
    and d.status in ('issued', 'voided')
    and d.doc_date between p_date_from and p_date_to
  order by d.doc_date, d.doc_no
$$;

-- Subsidiary purchases journal: one row per bill.
create or replace function public.purchases_book(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (
  doc_date date,
  doc_no bigint,
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
  select d.doc_date, d.doc_no, c.name, coalesce(c.tin, ''), d.status,
         (coalesce(u.untagged, 0) + coalesce(t.exempt, 0)
          + coalesce(t.taxable, 0) + coalesce(t.vat, 0))::numeric(18,2),
         (coalesce(u.untagged, 0) + coalesce(t.exempt, 0))::numeric(18,2),
         coalesce(t.taxable, 0)::numeric(18,2),
         coalesce(t.vat, 0)::numeric(18,2)
  from public.documents d
  join public.contacts c on c.id = d.contact_id
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
    and d.doc_type = 'bill'
    and d.status in ('issued', 'voided')
    and d.doc_date between p_date_from and p_date_to
  order by d.doc_date, d.doc_no
$$;

-- Cash receipts book: journal-derived — every posted entry that debits a
-- 1000-series cash account, in the classic columnar split. Sundry columns
-- absorb anything outside the named columns, so each row stays balanced:
-- cash + cwt + sundry_debit = ar + sales + output_vat + sundry_credit.
create or replace function public.cash_receipts_book(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (
  entry_date date,
  entry_no bigint,
  source_type text,
  memo text,
  cash numeric(18,2),
  cwt numeric(18,2),
  ar_credit numeric(18,2),
  sales numeric(18,2),
  output_vat numeric(18,2),
  sundry_debit numeric(18,2),
  sundry_credit numeric(18,2)
)
language sql stable
set search_path = ''
as $$
  with entry_lines as (
    select e.id, e.entry_date, e.entry_no, e.source_type, e.memo,
           l.debit, l.credit, a.code, a.account_type
    from public.journal_entries e
    join public.journal_lines l on l.entry_id = e.id
    join public.accounts a on a.id = l.account_id
    where e.client_id = p_client_id
      and e.status = 'posted'
      and e.entry_date between p_date_from and p_date_to
  )
  select x.entry_date, x.entry_no, x.source_type, x.memo,
         sum(x.debit) filter (where x.code like '1000%')::numeric(18,2) as cash,
         coalesce(sum(x.debit) filter (where x.code = '1320'), 0)::numeric(18,2) as cwt,
         coalesce(sum(x.credit) filter (where x.code = '1100'), 0)::numeric(18,2) as ar_credit,
         coalesce(sum(x.credit) filter (where x.account_type = 'income'), 0)::numeric(18,2) as sales,
         coalesce(sum(x.credit) filter (where x.code = '2200'), 0)::numeric(18,2) as output_vat,
         (coalesce(sum(x.debit), 0)
          - coalesce(sum(x.debit) filter (where x.code like '1000%'), 0)
          - coalesce(sum(x.debit) filter (where x.code = '1320'), 0))::numeric(18,2) as sundry_debit,
         (coalesce(sum(x.credit), 0)
          - coalesce(sum(x.credit) filter (where x.code = '1100'), 0)
          - coalesce(sum(x.credit) filter (where x.account_type = 'income'), 0)
          - coalesce(sum(x.credit) filter (where x.code = '2200'), 0))::numeric(18,2) as sundry_credit
  from entry_lines x
  group by x.id, x.entry_date, x.entry_no, x.source_type, x.memo
  having coalesce(sum(x.debit) filter (where x.code like '1000%'), 0) > 0
  order by x.entry_date, x.entry_no
$$;

-- Cash disbursements book: every posted entry that credits cash.
create or replace function public.cash_disbursements_book(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (
  entry_date date,
  entry_no bigint,
  source_type text,
  memo text,
  cash numeric(18,2),
  ap_debit numeric(18,2),
  purchases numeric(18,2),
  input_vat numeric(18,2),
  ewt numeric(18,2),
  sundry_debit numeric(18,2),
  sundry_credit numeric(18,2)
)
language sql stable
set search_path = ''
as $$
  with entry_lines as (
    select e.id, e.entry_date, e.entry_no, e.source_type, e.memo,
           l.debit, l.credit, a.code, a.account_type
    from public.journal_entries e
    join public.journal_lines l on l.entry_id = e.id
    join public.accounts a on a.id = l.account_id
    where e.client_id = p_client_id
      and e.status = 'posted'
      and e.entry_date between p_date_from and p_date_to
  )
  select x.entry_date, x.entry_no, x.source_type, x.memo,
         sum(x.credit) filter (where x.code like '1000%')::numeric(18,2) as cash,
         coalesce(sum(x.debit) filter (where x.code = '2000'), 0)::numeric(18,2) as ap_debit,
         coalesce(sum(x.debit) filter (where x.account_type = 'expense'), 0)::numeric(18,2) as purchases,
         coalesce(sum(x.debit) filter (where x.code = '1310'), 0)::numeric(18,2) as input_vat,
         coalesce(sum(x.credit) filter (where x.code = '2230'), 0)::numeric(18,2) as ewt,
         (coalesce(sum(x.debit), 0)
          - coalesce(sum(x.debit) filter (where x.code = '2000'), 0)
          - coalesce(sum(x.debit) filter (where x.account_type = 'expense'), 0)
          - coalesce(sum(x.debit) filter (where x.code = '1310'), 0))::numeric(18,2) as sundry_debit,
         (coalesce(sum(x.credit), 0)
          - coalesce(sum(x.credit) filter (where x.code like '1000%'), 0)
          - coalesce(sum(x.credit) filter (where x.code = '2230'), 0))::numeric(18,2) as sundry_credit
  from entry_lines x
  group by x.id, x.entry_date, x.entry_no, x.source_type, x.memo
  having coalesce(sum(x.credit) filter (where x.code like '1000%'), 0) > 0
  order by x.entry_date, x.entry_no
$$;

-- General journal book: the classic residual book — posted entries that
-- neither touch cash (those live in the receipts/disbursements books) nor
-- come from invoices/bills (those live in the subsidiary journals). One row
-- per journal line, so the export matches the columnar format.
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
    and coalesce(e.source_type, 'manual') not in ('invoice', 'bill')
    and not exists (
      select 1 from public.journal_lines cl
      join public.accounts ca on ca.id = cl.account_id
      where cl.entry_id = e.id and ca.code like '1000%'
    )
  order by e.entry_date, e.entry_no, l.line_no
$$;

revoke all on function
  public.sales_book(uuid, date, date),
  public.purchases_book(uuid, date, date),
  public.cash_receipts_book(uuid, date, date),
  public.cash_disbursements_book(uuid, date, date),
  public.general_journal_book(uuid, date, date)
from public, anon, authenticated;
grant execute on function
  public.sales_book(uuid, date, date),
  public.purchases_book(uuid, date, date),
  public.cash_receipts_book(uuid, date, date),
  public.cash_disbursements_book(uuid, date, date),
  public.general_journal_book(uuid, date, date)
to authenticated;
