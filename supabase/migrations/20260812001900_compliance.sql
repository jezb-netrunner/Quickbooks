-- Phase 6: return-preparation working papers, compliance calendar, and 2307
-- tracking.
--
-- Every figure a form needs is ASSEMBLED from the books (document_taxes, the
-- journal, the subsidiary books) — never re-typed. Every rate, threshold,
-- bracket, and deadline is CONFIGURATION:
--   * compliance_settings   effective-dated key/rate pairs (percentage tax,
--                           RCIT, MCIT, the 8% option and its exemption)
--   * income_tax_brackets   effective-dated graduated table (TRAIN 2023 seed)
--   * compliance_rules      which forms this client files and when they fall
--                           due (relative rules, not hardcoded dates)
-- Seeds are provisional — the CPA verifies the values; the structure is the
-- product. No eFPS/eBIRForms submission is attempted: the output is a
-- reviewable, exportable working paper per form.

-- ------------------------------------------- tax profile: income tax shape
alter table public.client_tax_profiles
  add column if not exists taxpayer_kind text not null default 'individual';
alter table public.client_tax_profiles
  add column if not exists income_tax_option text not null default 'graduated';
do $$ begin
  alter table public.client_tax_profiles add constraint client_tax_profiles_kind_check
    check (taxpayer_kind in ('individual', 'corporate'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.client_tax_profiles add constraint client_tax_profiles_option_check
    check (income_tax_option in ('graduated', 'eight_percent', 'rcit'));
exception when duplicate_object then null; end $$;
grant update (taxpayer_kind, income_tax_option) on public.client_tax_profiles to authenticated;

-- --------------------------------------- effective-dated compliance rates
create table if not exists public.compliance_settings (
  id             uuid primary key default gen_random_uuid(),
  client_id      uuid not null references public.clients(id),
  key            text not null check (length(btrim(key)) between 1 and 48),
  effective_from date not null,
  rate           numeric(18,6) not null check (rate >= 0),
  created_at     timestamptz not null default now(),
  unique (client_id, key, effective_from)
);

alter table public.compliance_settings enable row level security;
drop policy if exists compliance_settings_select on public.compliance_settings;
create policy compliance_settings_select on public.compliance_settings
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));
drop policy if exists compliance_settings_insert on public.compliance_settings;
create policy compliance_settings_insert on public.compliance_settings
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));
drop policy if exists compliance_settings_update on public.compliance_settings;
create policy compliance_settings_update on public.compliance_settings
  for update to authenticated
  using ((select app.can_write_client(client_id)))
  with check ((select app.can_write_client(client_id)));
grant select on public.compliance_settings to authenticated;
grant insert (client_id, key, effective_from, rate) on public.compliance_settings to authenticated;
grant update (effective_from, rate) on public.compliance_settings to authenticated;

create or replace function app.compliance_rate(p_client_id uuid, p_key text, p_on date) returns numeric
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v numeric;
begin
  select s.rate into v
  from public.compliance_settings s
  where s.client_id = p_client_id and s.key = p_key and s.effective_from <= p_on
  order by s.effective_from desc
  limit 1;
  if v is null then
    raise exception 'no % rate is configured as of % — run compliance setup or add one', p_key, p_on;
  end if;
  return v;
end $$;

-- ------------------------------------------------ graduated income tax
create table if not exists public.income_tax_brackets (
  id             uuid primary key default gen_random_uuid(),
  client_id      uuid not null references public.clients(id),
  effective_from date not null,
  lower_bound    numeric(18,2) not null check (lower_bound >= 0),
  base_tax       numeric(18,2) not null check (base_tax >= 0),
  marginal_rate  numeric(7,4) not null check (marginal_rate >= 0 and marginal_rate <= 1),
  created_at     timestamptz not null default now(),
  unique (client_id, effective_from, lower_bound)
);

alter table public.income_tax_brackets enable row level security;
drop policy if exists income_tax_brackets_select on public.income_tax_brackets;
create policy income_tax_brackets_select on public.income_tax_brackets
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));
drop policy if exists income_tax_brackets_insert on public.income_tax_brackets;
create policy income_tax_brackets_insert on public.income_tax_brackets
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));
drop policy if exists income_tax_brackets_update on public.income_tax_brackets;
create policy income_tax_brackets_update on public.income_tax_brackets
  for update to authenticated
  using ((select app.can_write_client(client_id)))
  with check ((select app.can_write_client(client_id)));
grant select on public.income_tax_brackets to authenticated;
grant insert (client_id, effective_from, lower_bound, base_tax, marginal_rate)
  on public.income_tax_brackets to authenticated;
grant update (effective_from, lower_bound, base_tax, marginal_rate)
  on public.income_tax_brackets to authenticated;

-- Graduated tax on an amount, using the bracket set in force on a date.
create or replace function app.graduated_tax(p_client_id uuid, p_amount numeric, p_on date) returns numeric
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_effective date;
  r record;
begin
  if p_amount is null or p_amount <= 0 then return 0; end if;
  select max(b.effective_from) into v_effective
  from public.income_tax_brackets b
  where b.client_id = p_client_id and b.effective_from <= p_on;
  if v_effective is null then
    raise exception 'no graduated tax table is configured as of % — run compliance setup', p_on;
  end if;
  select b.base_tax, b.marginal_rate, b.lower_bound into r
  from public.income_tax_brackets b
  where b.client_id = p_client_id and b.effective_from = v_effective
    and b.lower_bound <= p_amount
  order by b.lower_bound desc
  limit 1;
  return round(r.base_tax + (p_amount - r.lower_bound) * r.marginal_rate, 2);
end $$;

-- ---------------------------------------------------- filing deadline rules
-- Relative rules, one row per form. due date per period:
--   due_days set             -> period_end + due_days
--   due_months_after + day   -> that day, N months after the period-end month
--   due_months_after, no day -> end of that month
-- skip_q4: quarterly income tax has no Q4 filing (the annual return covers it).
create table if not exists public.compliance_rules (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid not null references public.clients(id),
  form             text not null check (length(btrim(form)) between 1 and 24),
  label            text not null,
  frequency        text not null check (frequency in ('monthly', 'quarterly', 'annual')),
  due_days         int check (due_days is null or due_days between 1 and 365),
  due_months_after int check (due_months_after is null or due_months_after between 1 and 12),
  due_day          int check (due_day is null or due_day between 1 and 31),
  skip_q4          boolean not null default false,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  unique (client_id, form),
  check (due_days is not null or due_months_after is not null)
);

alter table public.compliance_rules enable row level security;
drop policy if exists compliance_rules_select on public.compliance_rules;
create policy compliance_rules_select on public.compliance_rules
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));
drop policy if exists compliance_rules_insert on public.compliance_rules;
create policy compliance_rules_insert on public.compliance_rules
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));
drop policy if exists compliance_rules_update on public.compliance_rules;
create policy compliance_rules_update on public.compliance_rules
  for update to authenticated
  using ((select app.can_write_client(client_id)))
  with check ((select app.can_write_client(client_id)));
grant select on public.compliance_rules to authenticated;
grant insert (client_id, form, label, frequency, due_days, due_months_after, due_day, skip_q4, active)
  on public.compliance_rules to authenticated;
grant update (label, frequency, due_days, due_months_after, due_day, skip_q4, active)
  on public.compliance_rules to authenticated;

-- --------------------------------------------------- filing status per period
create table if not exists public.compliance_filings (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references public.clients(id),
  form         text not null,
  period_start date not null,
  period_end   date not null,
  due_date     date not null,
  status       text not null check (status in ('prepared', 'filed')),
  reference    text not null default '',
  filed_at     timestamptz,
  created_by   uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (client_id, form, period_end)
);

drop trigger if exists trg_compliance_filings_updated_at on public.compliance_filings;
create trigger trg_compliance_filings_updated_at
  before update on public.compliance_filings
  for each row execute function app.set_updated_at();

alter table public.compliance_filings enable row level security;
drop policy if exists compliance_filings_select on public.compliance_filings;
create policy compliance_filings_select on public.compliance_filings
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));
-- Writes go through the set_filing_status RPC only.
grant select on public.compliance_filings to authenticated;

create or replace function public.set_filing_status(
  p_client_id uuid,
  p_form text,
  p_period_start date,
  p_period_end date,
  p_due_date date,
  p_status text,          -- 'prepared' | 'filed' | 'pending' (pending clears)
  p_reference text default ''
) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not (select app.can_write_client(p_client_id)) then
    raise exception 'not authorized';
  end if;
  if p_status = 'pending' then
    delete from public.compliance_filings
     where client_id = p_client_id and form = p_form and period_end = p_period_end;
    return;
  end if;
  if p_status not in ('prepared', 'filed') then
    raise exception 'status must be pending, prepared, or filed';
  end if;
  insert into public.compliance_filings
    (client_id, form, period_start, period_end, due_date, status, reference, filed_at, created_by)
  values (p_client_id, p_form, p_period_start, p_period_end, p_due_date, p_status,
          coalesce(p_reference, ''),
          case when p_status = 'filed' then now() end,
          (select auth.uid()))
  on conflict (client_id, form, period_end) do update
    set status = excluded.status,
        reference = excluded.reference,
        due_date = excluded.due_date,
        filed_at = case when excluded.status = 'filed'
                        then coalesce(public.compliance_filings.filed_at, now()) end;
end $$;

revoke all on function public.set_filing_status(uuid, text, date, date, date, text, text)
  from public, anon, authenticated;
grant execute on function public.set_filing_status(uuid, text, date, date, date, text, text)
  to authenticated;

-- ------------------------------------------------------- 2307 certificates
-- The paper trail: certificates received from customers (creditable against
-- income tax) and issued to vendors. The system-derived figures live in
-- cwt_by_customer / ewt_by_vendor; this log tracks the physical documents.
create table if not exists public.wht_certificates (
  id             uuid primary key default gen_random_uuid(),
  client_id      uuid not null references public.clients(id),
  direction      text not null check (direction in ('received', 'issued')),
  contact_id     uuid not null,
  cert_no        text not null default '',
  cert_date      date not null,
  period_from    date not null,
  period_to      date not null,
  atc            text not null default '',
  income_payment numeric(18,2) not null check (income_payment >= 0),
  tax_withheld   numeric(18,2) not null check (tax_withheld >= 0),
  notes          text not null default '',
  created_by     uuid references auth.users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  foreign key (contact_id, client_id) references public.contacts (id, client_id)
);
create index if not exists wht_certificates_client_idx on public.wht_certificates (client_id, direction);

drop trigger if exists trg_wht_certificates_updated_at on public.wht_certificates;
create trigger trg_wht_certificates_updated_at
  before update on public.wht_certificates
  for each row execute function app.set_updated_at();

drop trigger if exists trg_wht_certificates_created_by on public.wht_certificates;
create trigger trg_wht_certificates_created_by
  before insert on public.wht_certificates
  for each row execute function app.force_created_by();

alter table public.wht_certificates enable row level security;
drop policy if exists wht_certificates_select on public.wht_certificates;
create policy wht_certificates_select on public.wht_certificates
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));
drop policy if exists wht_certificates_insert on public.wht_certificates;
create policy wht_certificates_insert on public.wht_certificates
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));
drop policy if exists wht_certificates_update on public.wht_certificates;
create policy wht_certificates_update on public.wht_certificates
  for update to authenticated
  using ((select app.can_write_client(client_id)))
  with check ((select app.can_write_client(client_id)));
drop policy if exists wht_certificates_delete on public.wht_certificates;
create policy wht_certificates_delete on public.wht_certificates
  for delete to authenticated
  using ((select app.can_write_client(client_id)));
grant select on public.wht_certificates to authenticated;
grant insert (client_id, direction, contact_id, cert_no, cert_date, period_from, period_to,
              atc, income_payment, tax_withheld, notes) on public.wht_certificates to authenticated;
grant update (direction, contact_id, cert_no, cert_date, period_from, period_to,
              atc, income_payment, tax_withheld, notes) on public.wht_certificates to authenticated;
grant delete on public.wht_certificates to authenticated;

-- --------------------------------------------------------------- seeding
-- PROVISIONAL VALUES the CPA verifies: 3% percentage tax, 25%/20% RCIT, 2%
-- MCIT, the 8% option with its 250,000 exemption, and the TRAIN graduated
-- table effective 2023. Deadline rules follow the profile. Idempotent.
create or replace function public.seed_client_compliance(p_client_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_profile record;
begin
  if not (select app.can_write_client(p_client_id)) then
    raise exception 'not authorized';
  end if;
  select * into v_profile from public.client_tax_profiles where client_id = p_client_id;
  if v_profile.client_id is null then
    raise exception 'run tax setup first — compliance rules follow the tax profile';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_client_id::text, 3));

  insert into public.compliance_settings (client_id, key, effective_from, rate)
  select p_client_id, s.key, date '1900-01-01', s.rate
  from (values
    ('percentage_tax_rate',    0.03),
    ('rcit_rate',              0.25),
    ('rcit_msme_rate',         0.20),
    ('mcit_rate',              0.02),
    ('eight_percent_rate',     0.08),
    ('eight_percent_exemption', 250000)
  ) as s (key, rate)
  on conflict (client_id, key, effective_from) do nothing;

  insert into public.income_tax_brackets (client_id, effective_from, lower_bound, base_tax, marginal_rate)
  select p_client_id, date '2023-01-01', b.lower_bound, b.base_tax, b.marginal_rate
  from (values
    (0::numeric,       0::numeric,       0::numeric),
    (250000::numeric,  0::numeric,       0.15::numeric),
    (400000::numeric,  22500::numeric,   0.20::numeric),
    (800000::numeric,  102500::numeric,  0.25::numeric),
    (2000000::numeric, 402500::numeric,  0.30::numeric),
    (8000000::numeric, 2202500::numeric, 0.35::numeric)
  ) as b (lower_bound, base_tax, marginal_rate)
  on conflict (client_id, effective_from, lower_bound) do nothing;

  -- deadline rules by regime and taxpayer kind
  insert into public.compliance_rules
    (client_id, form, label, frequency, due_days, due_months_after, due_day, skip_q4)
  select p_client_id, r.form, r.label, r.frequency, r.due_days, r.due_months_after, r.due_day, r.skip_q4
  from (values
    ('0619-E',  'Monthly EWT remittance',           'monthly',   null::int, 1,         10,        false),
    ('1601-EQ', 'Quarterly EWT return',             'quarterly', null::int, 1,         null::int, false),
    ('1604-E',  'Annual EWT information return',    'annual',    null::int, 1,         31,        false)
  ) as r (form, label, frequency, due_days, due_months_after, due_day, skip_q4)
  on conflict (client_id, form) do nothing;

  if v_profile.regime = 'vat' then
    insert into public.compliance_rules
      (client_id, form, label, frequency, due_days, due_months_after, due_day, skip_q4)
    values (p_client_id, '2550Q', 'Quarterly VAT return', 'quarterly', null, 1, 25, false)
    on conflict (client_id, form) do nothing;
  else
    insert into public.compliance_rules
      (client_id, form, label, frequency, due_days, due_months_after, due_day, skip_q4)
    values (p_client_id, '2551Q', 'Quarterly percentage tax', 'quarterly', null, 1, 25, false)
    on conflict (client_id, form) do nothing;
  end if;

  if v_profile.taxpayer_kind = 'individual' then
    insert into public.compliance_rules
      (client_id, form, label, frequency, due_days, due_months_after, due_day, skip_q4)
    values
      (p_client_id, '1701Q', 'Quarterly income tax (individual)', 'quarterly', null, 2, 15, true),
      (p_client_id, '1701A', 'Annual income tax (individual)',    'annual',    null, 4, 15, false)
    on conflict (client_id, form) do nothing;
  else
    insert into public.compliance_rules
      (client_id, form, label, frequency, due_days, due_months_after, due_day, skip_q4)
    values
      (p_client_id, '1702Q',  'Quarterly income tax (corporate)', 'quarterly', 60,   null, null, true),
      (p_client_id, '1702-RT', 'Annual income tax (corporate)',   'annual',    null, 4,    15,   false)
    on conflict (client_id, form) do nothing;
  end if;
end $$;

revoke all on function public.seed_client_compliance(uuid) from public, anon, authenticated;
grant execute on function public.seed_client_compliance(uuid) to authenticated;

-- ------------------------------------------------------ working papers
-- All SECURITY INVOKER — figures assemble through the caller's RLS.

-- 2550Q: VAT. Sales side from issued invoices' frozen tax snapshots
-- (untagged lines count as exempt, matching the sales book); input VAT from
-- issued bills, purchases, and expenses.
create or replace function public.wp_vat(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (line_no int, label text, amount numeric(18,2), note text)
language sql stable
set search_path = ''
as $$
  with sales as (
    select
      coalesce(sum(t.base) filter (where tc.vat_class = 'taxable'), 0) as taxable,
      coalesce(sum(t.base) filter (where tc.vat_class = 'zero_rated'), 0) as zero_rated,
      coalesce(sum(t.base) filter (where tc.vat_class = 'exempt'), 0) as exempt_tagged,
      coalesce(sum(t.amount) filter (where tc.kind = 'output_vat'), 0) as output_tax
    from public.documents d
    join public.document_taxes t on t.document_id = d.id
    join public.tax_codes tc on tc.id = t.tax_code_id
    where d.client_id = p_client_id and d.doc_type = 'invoice' and d.status = 'issued'
      and d.doc_date between p_date_from and p_date_to
      and tc.kind = 'output_vat'
  ),
  untagged as (
    select coalesce(sum(l.amount), 0) as amount
    from public.documents d
    join public.document_lines l on l.document_id = d.id
    where d.client_id = p_client_id and d.doc_type = 'invoice' and d.status = 'issued'
      and d.doc_date between p_date_from and p_date_to
      and l.tax_code_id is null
  ),
  input_vat as (
    select coalesce(sum(t.amount), 0) as amount
    from public.documents d
    join public.document_taxes t on t.document_id = d.id
    join public.tax_codes tc on tc.id = t.tax_code_id
    where d.client_id = p_client_id
      and d.doc_type in ('bill', 'purchase', 'expense')
      and d.status = 'issued'
      and d.doc_date between p_date_from and p_date_to
      and tc.kind = 'input_vat'
  )
  select * from (values
    (1, 'Vatable sales (net of VAT)', (select taxable from sales)::numeric(18,2),
        'Output-taxable bases from issued invoices'),
    (2, 'Zero-rated sales', (select zero_rated from sales)::numeric(18,2),
        'Zero-rated bases from issued invoices'),
    (3, 'Exempt sales', ((select exempt_tagged from sales) + (select amount from untagged))::numeric(18,2),
        'Exempt bases plus untagged invoice lines'),
    (4, 'Output tax', (select output_tax from sales)::numeric(18,2),
        'VAT the engine computed on issued invoices'),
    (5, 'Less: input tax', (select amount from input_vat)::numeric(18,2),
        'Input VAT on issued bills, purchases, and expenses'),
    (6, 'VAT payable (overpayment)',
        ((select output_tax from sales) - (select amount from input_vat))::numeric(18,2),
        'Line 4 less line 5')
  ) as v (line_no, label, amount, note)
$$;

-- 2551Q: percentage tax for non-VAT registrants. Rate from configuration.
create or replace function public.wp_percentage_tax(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (line_no int, label text, amount numeric(18,2), note text)
language sql stable
set search_path = ''
as $$
  with gross as (
    select coalesce(sum(l.amount), 0)
         + coalesce((
             select sum(t.amount)
             from public.documents d2
             join public.document_taxes t on t.document_id = d2.id
             join public.tax_codes tc on tc.id = t.tax_code_id
             where d2.client_id = p_client_id and d2.doc_type = 'invoice'
               and d2.status = 'issued' and tc.kind = 'output_vat'
               and not d2.amounts_include_tax
               and d2.doc_date between p_date_from and p_date_to
           ), 0) as amount
    from public.documents d
    join public.document_lines l on l.document_id = d.id
    where d.client_id = p_client_id and d.doc_type = 'invoice' and d.status = 'issued'
      and d.doc_date between p_date_from and p_date_to
  ),
  rate as (
    select app.compliance_rate(p_client_id, 'percentage_tax_rate', p_date_to) as r
  )
  select * from (values
    (1, 'Gross sales / receipts', (select amount from gross)::numeric(18,2),
        'Issued invoices in the period'),
    (2, 'Percentage tax rate (%)', ((select r from rate) * 100)::numeric(18,2),
        'From compliance settings, effective ' || p_date_to),
    (3, 'Percentage tax due',
        round((select amount from gross) * (select r from rate), 2)::numeric(18,2),
        'Line 1 x line 2')
  ) as v (line_no, label, amount, note)
$$;

-- EWT withheld from vendor payments, by ATC — the 0619-E/1601-EQ figures.
create or replace function public.wp_ewt(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (atc text, label text, base numeric(18,2), tax numeric(18,2))
language sql stable
set search_path = ''
as $$
  select tc.atc, tc.name,
         sum(t.base)::numeric(18,2), sum(t.amount)::numeric(18,2)
  from public.documents d
  join public.document_taxes t on t.document_id = d.id
  join public.tax_codes tc on tc.id = t.tax_code_id
  where d.client_id = p_client_id
    and d.status = 'issued'
    and d.doc_date between p_date_from and p_date_to
    and tc.kind = 'withholding_purchases'
  group by tc.atc, tc.name
  order by tc.atc
$$;

-- 2307s to ISSUE: EWT by vendor for a period (also the 1604-E detail).
create or replace function public.ewt_by_vendor(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (contact_id uuid, contact_name text, tin text, atc text,
                 base numeric(18,2), tax numeric(18,2))
language sql stable
set search_path = ''
as $$
  select c.id, c.name, coalesce(c.tin, ''), tc.atc,
         sum(t.base)::numeric(18,2), sum(t.amount)::numeric(18,2)
  from public.documents d
  join public.contacts c on c.id = d.contact_id
  join public.document_taxes t on t.document_id = d.id
  join public.tax_codes tc on tc.id = t.tax_code_id
  where d.client_id = p_client_id
    and d.status = 'issued'
    and d.doc_date between p_date_from and p_date_to
    and tc.kind = 'withholding_purchases'
  group by c.id, c.name, c.tin, tc.atc
  order by c.name, tc.atc
$$;

-- 2307s RECEIVED: CWT by customer — creditable against income tax.
create or replace function public.cwt_by_customer(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (contact_id uuid, contact_name text, tin text, atc text,
                 base numeric(18,2), tax numeric(18,2))
language sql stable
set search_path = ''
as $$
  select c.id, c.name, coalesce(c.tin, ''), tc.atc,
         sum(t.base)::numeric(18,2), sum(t.amount)::numeric(18,2)
  from public.documents d
  join public.contacts c on c.id = d.contact_id
  join public.document_taxes t on t.document_id = d.id
  join public.tax_codes tc on tc.id = t.tax_code_id
  where d.client_id = p_client_id
    and d.status = 'issued'
    and d.doc_date between p_date_from and p_date_to
    and tc.kind = 'withholding_sales'
  group by c.id, c.name, c.tin, tc.atc
  order by c.name, tc.atc
$$;

-- Income tax working paper (1701Q/1701A/1702Q/1702-RT). Figures from the
-- posted P&L; the computation follows the profile's option; creditable 2307s
-- (CWT on collections in the period) reduce the amount payable.
create or replace function public.wp_income_tax(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (line_no int, label text, amount numeric(18,2), note text)
language plpgsql stable
set search_path = ''
as $$
declare
  v_profile record;
  v_income numeric(18,2);
  v_cogs numeric(18,2);
  v_opex numeric(18,2);
  v_taxable numeric(18,2);
  v_tax numeric(18,2);
  v_credits numeric(18,2);
  v_note text;
begin
  select * into v_profile from public.client_tax_profiles p where p.client_id = p_client_id;
  if v_profile.client_id is null then
    raise exception 'run tax setup first';
  end if;

  select coalesce(sum(l.credit - l.debit), 0) into v_income
  from public.journal_lines l
  join public.journal_entries e on e.id = l.entry_id
  join public.accounts a on a.id = l.account_id
  where e.client_id = p_client_id and e.status = 'posted'
    and e.entry_date between p_date_from and p_date_to
    and a.account_type = 'income';

  select coalesce(sum(l.debit - l.credit), 0) into v_cogs
  from public.journal_lines l
  join public.journal_entries e on e.id = l.entry_id
  join public.accounts a on a.id = l.account_id
  where e.client_id = p_client_id and e.status = 'posted'
    and e.entry_date between p_date_from and p_date_to
    and a.account_type = 'expense' and a.code like '5%';

  select coalesce(sum(l.debit - l.credit), 0) into v_opex
  from public.journal_lines l
  join public.journal_entries e on e.id = l.entry_id
  join public.accounts a on a.id = l.account_id
  where e.client_id = p_client_id and e.status = 'posted'
    and e.entry_date between p_date_from and p_date_to
    and a.account_type = 'expense' and a.code not like '5%';

  v_taxable := v_income - v_cogs - v_opex;

  if v_profile.income_tax_option = 'eight_percent' then
    v_tax := round(greatest(v_income - app.compliance_rate(p_client_id, 'eight_percent_exemption', p_date_to), 0)
                   * app.compliance_rate(p_client_id, 'eight_percent_rate', p_date_to), 2);
    v_note := '8% of gross less the configured exemption (annual — review for cumulative filings)';
  elsif v_profile.income_tax_option = 'rcit' then
    v_tax := round(greatest(v_taxable, 0) * app.compliance_rate(p_client_id, 'rcit_rate', p_date_to), 2);
    v_note := 'RCIT at the configured rate; compare MCIT below for annual returns';
  else
    v_tax := app.graduated_tax(p_client_id, v_taxable, p_date_to);
    v_note := 'Graduated table effective as configured';
  end if;

  select coalesce(sum(t.amount), 0) into v_credits
  from public.documents d
  join public.document_taxes t on t.document_id = d.id
  join public.tax_codes tc on tc.id = t.tax_code_id
  where d.client_id = p_client_id and d.status = 'issued'
    and d.doc_date between p_date_from and p_date_to
    and tc.kind = 'withholding_sales';

  return query select * from (values
    (1, 'Gross income (sales / receipts)', v_income, 'Posted income accounts'),
    (2, 'Less: cost of sales', v_cogs, 'Expense accounts coded 5xxx'),
    (3, 'Gross profit', (v_income - v_cogs)::numeric(18,2), 'Line 1 less line 2'),
    (4, 'Less: operating expenses', v_opex, 'All other expense accounts'),
    (5, 'Taxable income', v_taxable, 'Line 3 less line 4'),
    (6, 'Income tax due', v_tax, v_note),
    (7, 'MCIT (corporate reference)',
        case when v_profile.taxpayer_kind = 'corporate'
             then round(greatest(v_income - v_cogs, 0)
                        * app.compliance_rate(p_client_id, 'mcit_rate', p_date_to), 2)
             else 0::numeric(18,2) end,
        'Minimum corporate income tax on gross income — annual returns pay the higher of line 6 and 7'),
    (8, 'Less: creditable withholding tax (2307s received)', v_credits,
        'CWT withheld by customers on collections in the period'),
    (9, 'Tax payable (overpayment)',
        (greatest(case when v_profile.taxpayer_kind = 'corporate'
                       then greatest(v_tax, round(greatest(v_income - v_cogs, 0)
                            * app.compliance_rate(p_client_id, 'mcit_rate', p_date_to), 2))
                       else v_tax end, 0) - v_credits)::numeric(18,2),
        'Tax due less creditable withholding')
  ) as v (line_no, label, amount, note);
end $$;

-- --------------------------------------------------- compliance calendar
-- Deadline rows for a year, from the rules, with each period's filing status.
create or replace function public.compliance_calendar(
  p_client_id uuid,
  p_year int
) returns table (
  form text,
  label text,
  frequency text,
  period_start date,
  period_end date,
  due_date date,
  status text,
  filed_at timestamptz,
  reference text
)
language sql stable
set search_path = ''
as $$
  with rules as (
    select * from public.compliance_rules r
    where r.client_id = p_client_id and r.active
  ),
  periods as (
    -- monthly
    select r.form, r.label, r.frequency, r.due_days, r.due_months_after, r.due_day,
           make_date(p_year, m, 1) as period_start,
           (make_date(p_year, m, 1) + interval '1 month' - interval '1 day')::date as period_end
    from rules r cross join generate_series(1, 12) as m
    where r.frequency = 'monthly'
    union all
    -- quarterly
    select r.form, r.label, r.frequency, r.due_days, r.due_months_after, r.due_day,
           make_date(p_year, (q - 1) * 3 + 1, 1),
           (make_date(p_year, (q - 1) * 3 + 1, 1) + interval '3 month' - interval '1 day')::date
    from rules r cross join generate_series(1, 4) as q
    where r.frequency = 'quarterly' and not (r.skip_q4 and q = 4)
    union all
    -- annual
    select r.form, r.label, r.frequency, r.due_days, r.due_months_after, r.due_day,
           make_date(p_year, 1, 1), make_date(p_year, 12, 31)
    from rules r
    where r.frequency = 'annual'
  ),
  dated as (
    select p.form, p.label, p.frequency, p.period_start, p.period_end,
           case
             when p.due_days is not null then (p.period_end + p.due_days)::date
             when p.due_day is not null then
               (date_trunc('month', p.period_end)
                + make_interval(months => p.due_months_after)
                + make_interval(days => p.due_day - 1))::date
             else
               (date_trunc('month', p.period_end)
                + make_interval(months => p.due_months_after + 1)
                - interval '1 day')::date
           end as due_date
    from periods p
  )
  select d.form, d.label, d.frequency, d.period_start, d.period_end, d.due_date,
         coalesce(f.status, 'pending'), f.filed_at, coalesce(f.reference, '')
  from dated d
  left join public.compliance_filings f
    on f.client_id = p_client_id and f.form = d.form and f.period_end = d.period_end
  order by d.due_date, d.form
$$;

revoke all on function
  public.wp_vat(uuid, date, date),
  public.wp_percentage_tax(uuid, date, date),
  public.wp_ewt(uuid, date, date),
  public.ewt_by_vendor(uuid, date, date),
  public.cwt_by_customer(uuid, date, date),
  public.wp_income_tax(uuid, date, date),
  public.compliance_calendar(uuid, int)
from public, anon, authenticated;
grant execute on function
  public.wp_vat(uuid, date, date),
  public.wp_percentage_tax(uuid, date, date),
  public.wp_ewt(uuid, date, date),
  public.ewt_by_vendor(uuid, date, date),
  public.cwt_by_customer(uuid, date, date),
  public.wp_income_tax(uuid, date, date),
  public.compliance_calendar(uuid, int)
to authenticated;
