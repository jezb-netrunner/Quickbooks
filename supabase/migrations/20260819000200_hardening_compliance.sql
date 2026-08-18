-- Hardening pass, batch 2 — compliance, columnar books, bank tax layer.
-- Fixes audit findings T-05 (retroactive calendar), P2-26 (ghost 0619-E
-- months), P2-18 (destructive filing cycle), P3-10 (books keyed on literal
-- account codes), P2-17 (blind close), and P2-22 (bank categorization
-- bypasses the tax layer).

-- ---------------------------------------------------------------------------
-- T-05 — deadlines started at January of every year, so a client onboarded in
-- August showed seven months of "missed" filings that predate the engagement.
-- The tax profile gains compliance_start; the calendar drops any period that
-- ENDS before it. setup_client stamps the first setup's month (Manila time)
-- and never moves it on re-runs; the CPA can adjust it for converted clients
-- whose earlier periods really are theirs to file.
alter table public.client_tax_profiles
  add column if not exists compliance_start date;
grant update (compliance_start) on public.client_tax_profiles to authenticated;

-- ---------------------------------------------------------------------------
-- P2-26 — the 0619-E rule generated all 12 months, but the months that close
-- a quarter (Mar/Jun/Sep/Dec) are folded into the 1601-EQ, so four rows per
-- client could never be filed and sat permanently "Overdue". Rules gain
-- skip_quarter_months; the calendar honors it.
alter table public.compliance_rules
  add column if not exists skip_quarter_months boolean not null default false;
update public.compliance_rules set skip_quarter_months = true where form = '0619-E';

-- ---------------------------------------------------------------------------
-- seed_client_compliance — recreated so the 0619-E rule seeds with
-- skip_quarter_months = true. Everything else unchanged from the P3-09 shape.
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
    (client_id, form, label, frequency, due_days, due_months_after, due_day, skip_q4, skip_quarter_months)
  select p_client_id, r.form, r.label, r.frequency, r.due_days, r.due_months_after, r.due_day, r.skip_q4, r.skip_qm
  from (values
    -- 0619-E only remits months 1-2 of each quarter; month 3 folds into 1601-EQ.
    ('0619-E',  'Monthly EWT remittance',           'monthly',   null::int, 1,         10,        false, true),
    ('1601-EQ', 'Quarterly EWT return',             'quarterly', null::int, 1,         null::int, false, false),
    ('1604-E',  'Annual EWT information return',    'annual',    null::int, 1,         31,        false, false)
  ) as r (form, label, frequency, due_days, due_months_after, due_day, skip_q4, skip_qm)
  on conflict (client_id, form) do nothing;

  if v_profile.regime = 'vat' then
    insert into public.compliance_rules
      (client_id, form, label, frequency, due_days, due_months_after, due_day, skip_q4)
    values (p_client_id, '2550Q', 'Quarterly VAT return', 'quarterly', null, 1, 25, false)
    on conflict (client_id, form) do nothing;
  elsif v_profile.income_tax_option <> 'eight_percent' then
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
-- setup_client — recreated to stamp compliance_start on FIRST setup only
-- (Manila month; coalesce keeps the original on every re-run).
create or replace function public.setup_client(
  p_client_id uuid,
  p_regime text,
  p_taxpayer_kind text,
  p_income_tax_option text
) returns void
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
  if p_taxpayer_kind not in ('individual', 'corporate') then
    raise exception 'taxpayer kind must be individual or corporate';
  end if;
  if p_income_tax_option not in ('graduated', 'eight_percent', 'rcit') then
    raise exception 'income tax option must be graduated, eight_percent, or rcit';
  end if;
  if p_taxpayer_kind = 'corporate' and p_income_tax_option <> 'rcit' then
    raise exception 'a corporate taxpayer files under RCIT — choose rcit';
  end if;
  if p_taxpayer_kind = 'individual' and p_income_tax_option = 'rcit' then
    raise exception 'RCIT applies to corporate taxpayers — choose graduated or eight_percent';
  end if;

  perform public.seed_client_coa(p_client_id);
  perform public.seed_client_tax_codes(p_client_id, p_regime);
  update public.client_tax_profiles
     set taxpayer_kind = p_taxpayer_kind,
         income_tax_option = p_income_tax_option,
         -- T-05: obligations begin with the engagement, not January. First
         -- setup stamps the current Manila month; re-runs never move it.
         compliance_start = coalesce(compliance_start,
                                     date_trunc('month', (now() at time zone 'Asia/Manila'))::date)
   where client_id = p_client_id;
  perform public.seed_client_compliance(p_client_id);

  update public.tax_codes set active = (p_regime = 'vat')
   where client_id = p_client_id and kind in ('output_vat', 'input_vat');
  update public.compliance_rules set active = (p_regime = 'vat')
   where client_id = p_client_id and form = '2550Q';
  update public.compliance_rules
     set active = (p_regime = 'non_vat' and p_income_tax_option <> 'eight_percent')
   where client_id = p_client_id and form = '2551Q';
  update public.compliance_rules set active = (p_taxpayer_kind = 'individual')
   where client_id = p_client_id and form in ('1701Q', '1701A');
  update public.compliance_rules set active = (p_taxpayer_kind = 'corporate')
   where client_id = p_client_id and form in ('1702Q', '1702-RT');
end $$;

-- ---------------------------------------------------------------------------
-- compliance_calendar — recreated with the T-05 start bound and the P2-26
-- quarter-month skip.
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
  with bound as (
    select coalesce((select p.compliance_start
                     from public.client_tax_profiles p
                     where p.client_id = p_client_id), date '0001-01-01') as start_on
  ),
  rules as (
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
      and not (r.skip_quarter_months and m in (3, 6, 9, 12))
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
  where d.period_end >= (select start_on from bound)
  order by d.due_date, d.form
$$;

-- ---------------------------------------------------------------------------
-- P2-18 — set_filing_status deleted a FILED record (filed_at + reference) on
-- a plain status cycle, and an empty reference overwrote a stored one.
-- Un-filing now demands explicit confirmation, and an empty reference keeps
-- the stored value. Old signature dropped (a second overload would make
-- PostgREST calls ambiguous).
drop function if exists public.set_filing_status(uuid, text, date, date, date, text, text);
create function public.set_filing_status(
  p_client_id uuid,
  p_form text,
  p_period_start date,
  p_period_end date,
  p_due_date date,
  p_status text,          -- 'prepared' | 'filed' | 'pending' (pending clears)
  p_reference text default '',
  p_confirm boolean default false
) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_current text;
begin
  if not (select app.can_write_client(p_client_id)) then
    raise exception 'not authorized';
  end if;
  if p_status = 'pending' then
    select f.status into v_current
    from public.compliance_filings f
    where f.client_id = p_client_id and f.form = p_form and f.period_end = p_period_end;
    if v_current = 'filed' and not p_confirm then
      raise exception 'this return is marked filed — un-filing erases its filed date and reference, and needs explicit confirmation';
    end if;
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
        -- an empty reference is "no change", never an erase
        reference = case when excluded.reference = ''
                         then public.compliance_filings.reference
                         else excluded.reference end,
        due_date = excluded.due_date,
        filed_at = case when excluded.status = 'filed'
                        then coalesce(public.compliance_filings.filed_at, now()) end;
end $$;

revoke all on function public.set_filing_status(uuid, text, date, date, date, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.set_filing_status(uuid, text, date, date, date, text, text, boolean)
  to authenticated;

-- ---------------------------------------------------------------------------
-- P3-10 — the columnar cash books mapped their CWT/EWT/VAT columns by literal
-- account codes (1320/2200/1310/2230), but tax_codes.account_code is
-- editable; a re-pointed tax account silently fell into Sundry. The columns
-- now resolve from the client's own tax codes. AR 1100 / AP 2000 stay literal
-- — those control accounts are frozen by design.
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
           l.debit, l.credit, a.code, a.account_type,
           exists (select 1 from public.tax_codes tc
                   where tc.client_id = p_client_id and tc.account_code = a.code
                     and tc.kind = 'withholding_sales') as is_cwt,
           exists (select 1 from public.tax_codes tc
                   where tc.client_id = p_client_id and tc.account_code = a.code
                     and tc.kind = 'output_vat') as is_ovat
    from public.journal_entries e
    join public.journal_lines l on l.entry_id = e.id
    join public.accounts a on a.id = l.account_id
    where e.client_id = p_client_id
      and e.status = 'posted'
      and e.entry_date between p_date_from and p_date_to
  )
  select x.entry_date, x.entry_no, x.source_type, x.memo,
         sum(x.debit) filter (where x.code like '1000%')::numeric(18,2) as cash,
         coalesce(sum(x.debit) filter (where x.is_cwt), 0)::numeric(18,2) as cwt,
         coalesce(sum(x.credit) filter (where x.code = '1100'), 0)::numeric(18,2) as ar_credit,
         coalesce(sum(x.credit) filter (where x.account_type = 'income'), 0)::numeric(18,2) as sales,
         coalesce(sum(x.credit) filter (where x.is_ovat), 0)::numeric(18,2) as output_vat,
         (coalesce(sum(x.debit), 0)
          - coalesce(sum(x.debit) filter (where x.code like '1000%'), 0)
          - coalesce(sum(x.debit) filter (where x.is_cwt), 0))::numeric(18,2) as sundry_debit,
         (coalesce(sum(x.credit), 0)
          - coalesce(sum(x.credit) filter (where x.code = '1100'), 0)
          - coalesce(sum(x.credit) filter (where x.account_type = 'income'), 0)
          - coalesce(sum(x.credit) filter (where x.is_ovat), 0))::numeric(18,2) as sundry_credit
  from entry_lines x
  group by x.id, x.entry_date, x.entry_no, x.source_type, x.memo
  having coalesce(sum(x.debit) filter (where x.code like '1000%'), 0) > 0
  order by x.entry_date, x.entry_no
$$;

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
           l.debit, l.credit, a.code, a.account_type,
           exists (select 1 from public.tax_codes tc
                   where tc.client_id = p_client_id and tc.account_code = a.code
                     and tc.kind = 'input_vat') as is_ivat,
           exists (select 1 from public.tax_codes tc
                   where tc.client_id = p_client_id and tc.account_code = a.code
                     and tc.kind = 'withholding_purchases') as is_ewt
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
         coalesce(sum(x.debit) filter (where x.is_ivat), 0)::numeric(18,2) as input_vat,
         coalesce(sum(x.credit) filter (where x.is_ewt), 0)::numeric(18,2) as ewt,
         (coalesce(sum(x.debit), 0)
          - coalesce(sum(x.debit) filter (where x.code = '2000'), 0)
          - coalesce(sum(x.debit) filter (where x.account_type = 'expense'), 0)
          - coalesce(sum(x.debit) filter (where x.is_ivat), 0))::numeric(18,2) as sundry_debit,
         (coalesce(sum(x.credit), 0)
          - coalesce(sum(x.credit) filter (where x.code like '1000%'), 0)
          - coalesce(sum(x.credit) filter (where x.is_ewt), 0))::numeric(18,2) as sundry_credit
  from entry_lines x
  group by x.id, x.entry_date, x.entry_no, x.source_type, x.memo
  having coalesce(sum(x.credit) filter (where x.code like '1000%'), 0) > 0
  order by x.entry_date, x.entry_no
$$;

-- ---------------------------------------------------------------------------
-- P2-17 — closing was blind. One cheap RPC tells the close dialog what is
-- still in flight inside the period: month-dated drafts, submitted documents,
-- and pending bank lines.
create or replace function public.period_close_check(p_period_id uuid)
returns table (draft_docs int, submitted_docs int, pending_bank int)
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v record;
begin
  select p.client_id, p.period_start, p.period_end into v
  from public.periods p where p.id = p_period_id;
  if v.client_id is null then raise exception 'period not found'; end if;
  if not (select app.can_access_client(v.client_id)) then
    raise exception 'not authorized';
  end if;
  return query select
    (select count(*)::int from public.documents d
      where d.client_id = v.client_id and d.status = 'draft'
        and d.doc_date between v.period_start and v.period_end),
    (select count(*)::int from public.documents d
      where d.client_id = v.client_id and d.status = 'submitted'
        and d.doc_date between v.period_start and v.period_end),
    (select count(*)::int from public.bank_txns b
      where b.client_id = v.client_id and b.status = 'pending'
        and b.txn_date between v.period_start and v.period_end);
end $$;

revoke all on function public.period_close_check(uuid) from public, anon, authenticated;
grant execute on function public.period_close_check(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- P2-22 — bank categorization posted a bare two-line entry, so a bank-captured
-- expense carried no input VAT and vanished from the 2550Q. Categorize now
-- takes an optional input-VAT code: the cash amount is treated as
-- VAT-inclusive, the net hits the chosen account, the VAT leg hits the tax
-- code's account. Old signatures dropped (overloads would be ambiguous).
drop function if exists app.bank_categorize(uuid, uuid, text);
create function app.bank_categorize(
  p_txn_id uuid,
  p_account_id uuid,
  p_memo text,
  p_tax_code_id uuid default null
) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v record;
  v_acct record;
  v_tax record;
  v_entry uuid;
  v_amt numeric(18,2);
  v_rate numeric;
  v_net numeric(18,2);
  v_vat numeric(18,2);
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
  v_net := v_amt;
  v_vat := 0;
  if p_tax_code_id is not null then
    select tc.id, tc.kind, tc.active, tc.account_code into v_tax
    from public.tax_codes tc
    where tc.id = p_tax_code_id and tc.client_id = v.client_id;
    if v_tax.id is null then raise exception 'tax code not found'; end if;
    if not v_tax.active or v_tax.kind <> 'input_vat' then
      raise exception 'bank lines take an active input-VAT code';
    end if;
    if v.amount >= 0 then
      raise exception 'input VAT applies to money going out — categorize deposits without a tax code';
    end if;
    v_rate := app.tax_rate(p_tax_code_id, v.txn_date);
    if v_rate > 0 then
      v_net := round(v_amt / (1 + v_rate), 2);
      v_vat := v_amt - v_net;
    end if;
  end if;

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
      (v_entry, v.client_id, 1, p_account_id, v_net, 0),
      (v_entry, v.client_id, 2, v.bank_account_id, 0, v_amt);
    if v_vat > 0 then
      insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
      values (v_entry, v.client_id, 3,
              app.control_account(v.client_id, v_tax.account_code), v_vat, 0);
    end if;
  end if;
  perform public.post_entry(v_entry);
  update public.bank_txns
     set status = 'categorized', account_id = p_account_id, entry_id = v_entry
   where id = p_txn_id;
end $$;

drop function if exists public.categorize_bank_txn(uuid, uuid, text);
create function public.categorize_bank_txn(
  p_txn_id uuid,
  p_account_id uuid,
  p_memo text default null,
  p_tax_code_id uuid default null
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
  perform app.bank_categorize(p_txn_id, p_account_id, p_memo, p_tax_code_id);
end $$;

revoke all on function public.categorize_bank_txn(uuid, uuid, text, uuid)
  from public, anon, authenticated;
grant execute on function public.categorize_bank_txn(uuid, uuid, text, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- wp_vat — the 2550Q input-tax line now also counts bank-captured input VAT:
-- posted bank_import entries' debits to the client's input-VAT accounts
-- (documents never post with that source_type, so nothing double-counts;
-- reversals of bank entries net out through their reversal_of link).
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
  ),
  bank_input_vat as (
    select coalesce(sum(l.debit) - sum(l.credit), 0) as amount
    from public.journal_entries e
    join public.journal_lines l on l.entry_id = e.id
    join public.accounts a on a.id = l.account_id
    where e.client_id = p_client_id
      and e.status = 'posted'
      and e.entry_date between p_date_from and p_date_to
      and (e.source_type = 'bank_import'
           or (e.source_type = 'reversal' and e.reversal_of in (
                 select e2.id from public.journal_entries e2
                 where e2.client_id = p_client_id and e2.source_type = 'bank_import')))
      and a.code in (select tc.account_code from public.tax_codes tc
                     where tc.client_id = p_client_id and tc.kind = 'input_vat')
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
    (5, 'Less: input tax',
        ((select amount from input_vat) + (select amount from bank_input_vat))::numeric(18,2),
        'Input VAT on issued bills, purchases, expenses, and categorized bank lines'),
    (6, 'VAT payable (overpayment)',
        ((select output_tax from sales) - (select amount from input_vat)
         - (select amount from bank_input_vat))::numeric(18,2),
        'Line 4 less line 5')
  ) as v (line_no, label, amount, note)
$$;
