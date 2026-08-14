-- Phase 3 remediation — accounting integrity (batch 3).
-- Fixes audit finding P3-09.
--
-- Business decision (confirmed by the practice CPA, 2026-08-14): the 8% flat
-- income-tax option is IN LIEU of the Sec. 116 percentage tax (TRAIN), so an
-- 8%-option client owes no 2551Q. Previously seed_client_compliance seeded the
-- 2551Q rule for every non-VAT client and wp_percentage_tax computed a positive
-- 3% liability regardless of the income-tax option → false quarterly deadlines
-- and a spurious liability.

-- ---------------------------------------------------------------------------
-- Seed: only non-VAT clients that are NOT on the 8% option get the 2551Q rule.
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
  elsif v_profile.income_tax_option <> 'eight_percent' then
    -- P3-09: 8%-option clients owe no percentage tax; do not seed 2551Q for them.
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

-- ---------------------------------------------------------------------------
-- Working paper: an 8%-option client shows a 0% rate and 0 tax due, with a note.
-- (The CASE skips app.compliance_rate for 8% clients, so it also never errors on
-- a missing percentage_tax_rate for them.)
create or replace function public.wp_percentage_tax(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (line_no int, label text, amount numeric(18,2), note text)
language sql stable
set search_path = ''
as $$
  with prof as (
    select income_tax_option from public.client_tax_profiles where client_id = p_client_id
  ),
  gross as (
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
    select case
             when (select income_tax_option from prof) = 'eight_percent' then 0::numeric
             else app.compliance_rate(p_client_id, 'percentage_tax_rate', p_date_to)
           end as r
  )
  select * from (values
    (1, 'Gross sales / receipts', (select amount from gross)::numeric(18,2),
        'Issued invoices in the period'),
    (2, 'Percentage tax rate (%)', ((select r from rate) * 100)::numeric(18,2),
        case when (select income_tax_option from prof) = 'eight_percent'
             then '8% income-tax option is in lieu of the percentage tax — none due'
             else 'From compliance settings, effective ' || p_date_to end),
    (3, 'Percentage tax due',
        round((select amount from gross) * (select r from rate), 2)::numeric(18,2),
        'Line 1 x line 2')
  ) as v (line_no, label, amount, note)
$$;
