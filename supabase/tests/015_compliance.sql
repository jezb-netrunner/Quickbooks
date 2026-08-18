-- Phase 6: working papers assemble the return figures from the books, rates
-- and brackets and deadlines are effective-dated configuration, the calendar
-- derives from the profile, and 2307 tracking is client-scoped.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(25);

\ir 000_fixture.sql.inc

select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.seed_client_coa(tap.v('a1'));
select set_config('request.jwt.claims', '', true);
insert into tap.ctx select 'acc_cash',  id from public.accounts where client_id = tap.v('a1') and code = '1000-02';
insert into tap.ctx select 'acc_sales', id from public.accounts where client_id = tap.v('a1') and code = '4000';
insert into tap.ctx select 'acc_rent',  id from public.accounts where client_id = tap.v('a1') and code = '6100';
grant insert on tap.ctx to authenticated;

select tap.login('22222222-2222-4222-8222-222222222202');
select public.seed_client_tax_codes(tap.v('a1'), 'vat');
select public.seed_client_compliance(tap.v('a1'));
insert into tap.ctx select 'tc_vat_out', id from public.tax_codes where client_id = tap.v('a1') and code = 'VAT12-OUT';
insert into tap.ctx select 'tc_vat_in',  id from public.tax_codes where client_id = tap.v('a1') and code = 'VAT12-IN';
insert into tap.ctx select 'tc_cwt_svc', id from public.tax_codes where client_id = tap.v('a1') and code = 'CWT-SVC';
insert into tap.ctx select 'tc_ewt_svc', id from public.tax_codes where client_id = tap.v('a1') and code = 'EWT-SVC';

select is(
  (select count(*) from public.compliance_settings where client_id = tap.v('a1')),
  6::bigint,
  'compliance setup seeds the six provisional rates'
);
select is(
  (select count(*) from public.income_tax_brackets where client_id = tap.v('a1')),
  6::bigint,
  'the graduated table seeds six brackets'
);
select ok(
  (select bool_or(form = '2550Q') and not bool_or(form = '2551Q')
   from public.compliance_rules where client_id = tap.v('a1')),
  'a VAT client files 2550Q, never 2551Q'
);
select ok(
  (select bool_or(form = '1701Q') and bool_or(form = '1701A')
   from public.compliance_rules where client_id = tap.v('a1')),
  'an individual taxpayer files 1701Q and 1701A'
);

-- graduated math straight off the bracket table (app schema — superuser call)
select tap.logout();
select is(
  (select app.graduated_tax(tap.v('a1'), 1000000, date '2026-06-30')),
  152500.00::numeric,
  'graduated tax on 1,000,000 is 102,500 base + 25% over 800,000'
);
select is(
  (select app.graduated_tax(tap.v('a1'), 200000, date '2026-06-30')),
  0.00::numeric,
  'income under the first bracket owes nothing'
);
select tap.login('22222222-2222-4222-8222-222222222202');

-- Books fixture: VAT sale 1000+120, VAT bill 500+60, EWT payment, CWT receipt
with c as (
  insert into public.contacts (client_id, name, contact_type, tin) values (tap.v('a1'), 'WP Cust', 'customer', '111-111') returning id
) insert into tap.ctx select 'cust', id from c;
with c as (
  insert into public.contacts (client_id, name, contact_type, tin) values (tap.v('a1'), 'WP Vend', 'vendor', '222-222') returning id
) insert into tap.ctx select 'vend', id from c;
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-02-01', tap.v('cust'), 'Q1 sale') returning id
) insert into tap.ctx select 'inv1', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, tax_code_id)
values (tap.v('inv1'), tap.v('a1'), 1, tap.v('acc_sales'), '', 1000, tap.v('tc_vat_out'));
select public.issue_document(tap.v('inv1'));
with d as (
  insert into public.documents (client_id, doc_type, doc_date, due_date, contact_id, memo)
  values (tap.v('a1'), 'bill', date '2026-02-05', date '2026-02-25', tap.v('vend'), 'Q1 rent') returning id
) insert into tap.ctx select 'bill1', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, tax_code_id)
values (tap.v('bill1'), tap.v('a1'), 1, tap.v('acc_rent'), '', 500, tap.v('tc_vat_in'));
select public.issue_document(tap.v('bill1'));
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id, memo, wht_tax_code_id, wht_base)
  values (tap.v('a1'), 'disbursement', date '2026-02-10', tap.v('vend'), tap.v('acc_cash'), 'Pay rent', tap.v('tc_ewt_svc'), 500)
  returning id
) insert into tap.ctx select 'pay1', id from d;
insert into public.document_applications (client_id, paying_document_id, target_document_id, amount)
values (tap.v('a1'), tap.v('pay1'), tap.v('bill1'), 560);
select public.issue_document(tap.v('pay1'));
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id, memo, wht_tax_code_id, wht_base)
  values (tap.v('a1'), 'receipt', date '2026-02-15', tap.v('cust'), tap.v('acc_cash'), 'Collect', tap.v('tc_cwt_svc'), 1000)
  returning id
) insert into tap.ctx select 'rcpt1', id from d;
insert into public.document_applications (client_id, paying_document_id, target_document_id, amount)
values (tap.v('a1'), tap.v('rcpt1'), tap.v('inv1'), 1120);
select public.issue_document(tap.v('rcpt1'));

-- 2550Q working paper
select is(
  (select amount from public.wp_vat(tap.v('a1'), date '2026-01-01', date '2026-03-31') where line_no = 1),
  1000.00::numeric(18,2), 'wp 2550Q: vatable sales 1000'
);
select is(
  (select amount from public.wp_vat(tap.v('a1'), date '2026-01-01', date '2026-03-31') where line_no = 4),
  120.00::numeric(18,2), 'wp 2550Q: output tax 120'
);
select is(
  (select amount from public.wp_vat(tap.v('a1'), date '2026-01-01', date '2026-03-31') where line_no = 5),
  60.00::numeric(18,2), 'wp 2550Q: input tax 60'
);
select is(
  (select amount from public.wp_vat(tap.v('a1'), date '2026-01-01', date '2026-03-31') where line_no = 6),
  60.00::numeric(18,2), 'wp 2550Q: net VAT payable 60'
);

-- EWT working paper and the 2307 registers
select is(
  (select tax from public.wp_ewt(tap.v('a1'), date '2026-01-01', date '2026-03-31') where atc = 'WC160'),
  10.00::numeric(18,2), 'wp EWT: services 2% withheld 10 under WC160'
);
select ok(
  (select base = 500.00 and tax = 10.00
   from public.ewt_by_vendor(tap.v('a1'), date '2026-01-01', date '2026-03-31')
   where contact_name = 'WP Vend'),
  'the 2307-to-issue register shows the vendor base and tax'
);
select ok(
  (select tax = 20.00
   from public.cwt_by_customer(tap.v('a1'), date '2026-01-01', date '2026-03-31')
   where contact_name = 'WP Cust'),
  'the 2307-received register shows the customer withholding'
);

-- Income tax working paper under each option
select is(
  (select amount from public.wp_income_tax(tap.v('a1'), date '2026-01-01', date '2026-03-31') where line_no = 5),
  500.00::numeric(18,2), 'income tax wp: taxable income 1000 - 500'
);
select is(
  (select amount from public.wp_income_tax(tap.v('a1'), date '2026-01-01', date '2026-03-31') where line_no = 9),
  -20.00::numeric(18,2), 'graduated tax under the first bracket nets to a 20 overpayment from CWT credits'
);
-- 8% is only for non-VAT individuals, so the regime flips with the option.
update public.client_tax_profiles
   set regime = 'non_vat', income_tax_option = 'eight_percent' where client_id = tap.v('a1');
select is(
  (select amount from public.wp_income_tax(tap.v('a1'), date '2026-01-01', date '2026-03-31') where line_no = 6),
  0.00::numeric(18,2), 'the 8% option owes nothing under the exemption'
);
update public.client_tax_profiles
   set taxpayer_kind = 'corporate', income_tax_option = 'rcit' where client_id = tap.v('a1');
select ok(
  (select bool_and(ok) from (
     select (line_no = 6 and amount = 125.00) or (line_no = 9 and amount = 105.00) as ok
     from public.wp_income_tax(tap.v('a1'), date '2026-01-01', date '2026-03-31')
     where line_no in (6, 9)
   ) x),
  'RCIT computes 25% of taxable and nets the CWT credits'
);
update public.client_tax_profiles
   set taxpayer_kind = 'individual', income_tax_option = 'graduated' where client_id = tap.v('a1');

-- Percentage tax with effective-dated rate
select is(
  (select amount from public.wp_percentage_tax(tap.v('a1'), date '2026-01-01', date '2026-03-31') where line_no = 3),
  33.60::numeric(18,2), 'percentage tax: 3% of the 1120 gross'
);
insert into public.compliance_settings (client_id, key, effective_from, rate)
values (tap.v('a1'), 'percentage_tax_rate', date '2027-01-01', 0.01);
select is(
  (select amount from public.wp_percentage_tax(tap.v('a1'), date '2026-01-01', date '2026-03-31') where line_no = 3),
  33.60::numeric(18,2), 'a 2027 rate change leaves the 2026 working paper untouched'
);

-- Calendar
select ok(
  (select count(*) = 4 and bool_or(period_end = date '2026-03-31' and due_date = date '2026-04-25')
   from public.compliance_calendar(tap.v('a1'), 2026) where form = '2550Q'),
  'the calendar generates four 2550Q deadlines, Q1 due April 25'
);
select ok(
  -- P2-26: months 3/6/9/12 fold into the 1601-EQ, so 0619-E runs 8 periods.
  (select count(*) filter (where form = '0619-E') = 8
      and count(*) filter (where form = '0619-E'
                           and extract(month from period_end) in (3, 6, 9, 12)) = 0
      and count(*) filter (where form = '1701Q') = 3
   from public.compliance_calendar(tap.v('a1'), 2026)),
  'monthly EWT runs eight periods (quarter months fold into 1601-EQ); quarterly income tax skips Q4'
);
select is(
  (select due_date from public.compliance_calendar(tap.v('a1'), 2026)
   where form = '1601-EQ' and period_end = date '2026-03-31'),
  date '2026-04-30',
  '1601-EQ falls due at the end of the month after the quarter'
);
select public.set_filing_status(tap.v('a1'), '2550Q', date '2026-01-01', date '2026-03-31',
                                date '2026-04-25', 'filed', 'eFPS ref 123');
select is(
  (select status from public.compliance_calendar(tap.v('a1'), 2026)
   where form = '2550Q' and period_end = date '2026-03-31'),
  'filed',
  'marking a period filed shows on the calendar'
);

-- 2307 certificate log
select lives_ok(
  $$ insert into public.wht_certificates
       (client_id, direction, contact_id, cert_no, cert_date, period_from, period_to, atc, income_payment, tax_withheld)
     values (tap.v('a1'), 'received', tap.v('cust'), '2307-0001', date '2026-04-02',
             date '2026-01-01', date '2026-03-31', 'WC160', 1000, 20) $$,
  'staff can log a received 2307 certificate'
);
select tap.logout();
select tap.login('22222222-2222-4222-8222-222222222204');
select throws_ok(
  $$ insert into public.wht_certificates
       (client_id, direction, contact_id, cert_no, cert_date, period_from, period_to, atc, income_payment, tax_withheld)
     values (tap.v('a1'), 'received', tap.v('cust'), 'HAX', date '2026-04-02',
             date '2026-01-01', date '2026-03-31', '', 1, 1) $$,
  '42501', null,
  'a client viewer cannot write certificates'
);
select tap.logout();

select * from finish();
rollback;
