-- Audit hardening: four holes found by an adversarial probe of Phases 1–5.
--
--   1. A payment document (or cash-settled invoice) could name ANY account as
--      its "cash/bank" account — a receipt through 6100 Rent posted an
--      expense debit instead of cash and fell outside the cash books. The
--      cash side of a payment must be a 1000-series account.
--   2. Voided invoices/bills kept their amounts in the sales and purchases
--      books, overstating the column totals a return is prepared from. The
--      row stays (loose-leaf style) but its amounts read zero.
--   3. An account's CODE could be renamed after it had postings. Books,
--      control-account resolution, and the cash books all key on codes —
--      renaming 1100 or a 1000-series account rewrites history's meaning.
--      Codes freeze once an account has journal lines or is a document's
--      settlement account.
--   4. A tax code's posting account could be re-pointed at 1100/2000/1000%
--      — issuing would then post VAT straight into AR/AP/cash, corrupting
--      the subledgers. Control and cash codes are now unrepresentable as
--      tax posting accounts.

-- ------------------------------------------------ 1. cash side must be cash
create or replace function app.assert_bank_is_cash() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_code text;
begin
  if new.bank_account_id is not null then
    select a.code into v_code
    from public.accounts a
    where a.id = new.bank_account_id and a.archived_at is null;
    if v_code is null or v_code not like '1000%' then
      raise exception 'the cash/bank side of a document must be an active 1000-series cash account';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_documents_bank_is_cash on public.documents;
create trigger trg_documents_bank_is_cash
  before insert or update of bank_account_id on public.documents
  for each row execute function app.assert_bank_is_cash();

-- ------------------------------------- 2. voided rows read zero in the books
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
         (z.live * (coalesce(u.untagged, 0) + coalesce(t.exempt, 0) + coalesce(t.zero_rated, 0)
          + coalesce(t.taxable, 0) + coalesce(t.vat, 0)))::numeric(18,2),
         (z.live * (coalesce(u.untagged, 0) + coalesce(t.exempt, 0)))::numeric(18,2),
         (z.live * coalesce(t.zero_rated, 0))::numeric(18,2),
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
    and d.doc_type = 'bill'
    and d.status in ('issued', 'voided')
    and d.doc_date between p_date_from and p_date_to
  order by d.doc_date, d.doc_no
$$;

-- ------------------------------------------- 3. codes freeze with history
create or replace function app.assert_account_code_stable() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.code is distinct from old.code then
    if exists (select 1 from public.journal_lines l where l.account_id = old.id)
       or exists (select 1 from public.documents d where d.bank_account_id = old.id) then
      raise exception 'this account has postings — its code is part of the books. Archive it and create a new account instead of renaming.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_accounts_code_stable on public.accounts;
create trigger trg_accounts_code_stable
  before update of code on public.accounts
  for each row execute function app.assert_account_code_stable();

-- ----------------------- 4. tax codes cannot post to control/cash accounts
do $$ begin
  alter table public.tax_codes add constraint tax_codes_account_not_control_check
    check (account_code not in ('1100', '2000') and account_code not like '1000%');
exception when duplicate_object then null; end $$;

-- ------------------- regime switches toggle the VAT codes' availability
-- Re-running setup as non_vat used to leave the VAT codes active (offering
-- VAT on a non-VAT client's invoices). The switch now deactivates them, and
-- switching back to vat reactivates them. Withholding codes apply to both
-- regimes and are untouched.
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

  update public.tax_codes
     set active = (p_regime = 'vat')
   where client_id = p_client_id
     and kind in ('output_vat', 'input_vat');

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
