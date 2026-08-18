-- Phase 3: documents post through the engine; AR/AP are open-item; issued
-- documents freeze; voiding reverses; aging and the dashboard read the truth.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(20);

\ir 000_fixture.sql.inc

-- Fixture: chart + a customer + a vendor on client A1
select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.seed_client_coa(tap.v('a1'));
-- The issue gate (T-01) requires a tax profile; this suite predates the wizard,
-- so arrange the minimal profile directly (regime only, no tax codes).
insert into public.client_tax_profiles (client_id, regime) values (tap.v('a1'), 'non_vat');
select set_config('request.jwt.claims', '', true);
insert into tap.ctx select 'acc_cash',  id from public.accounts where client_id = tap.v('a1') and code = '1000-02';
insert into tap.ctx select 'acc_sales', id from public.accounts where client_id = tap.v('a1') and code = '4000';
insert into tap.ctx select 'acc_rent',  id from public.accounts where client_id = tap.v('a1') and code = '6100';
grant insert on tap.ctx to authenticated;

select tap.login('22222222-2222-4222-8222-222222222202');
with c as (
  insert into public.contacts (client_id, name, contact_type)
  values (tap.v('a1'), 'Mango Grove Cafe', 'customer') returning id
) insert into tap.ctx select 'cust', id from c;
with c as (
  insert into public.contacts (client_id, name, contact_type)
  values (tap.v('a1'), 'Petron Dealer', 'vendor') returning id
) insert into tap.ctx select 'vend', id from c;
select is(
  (select count(*) from public.contacts where client_id = tap.v('a1')),
  2::bigint,
  'staff can add customers and vendors'
);

-- Invoice: draft -> issue -> AR
with d as (
  insert into public.documents (client_id, doc_type, doc_date, due_date, contact_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-08-01', date '2026-08-15', tap.v('cust'), 'August retainer')
  returning id
) insert into tap.ctx select 'inv1', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount)
values (tap.v('inv1'), tap.v('a1'), 1, tap.v('acc_sales'), 'Retainer', 5000.00);
select is(
  (select public.issue_document(tap.v('inv1'))),
  1::bigint,
  'the invoice issues as number 1'
);
select is(
  (select e.status from public.journal_entries e
   join public.documents d on d.entry_id = e.id where d.id = tap.v('inv1')),
  'posted',
  'issuing posted a journal entry through the engine'
);
select ok(
  (select sum(total_debit) = sum(total_credit) and sum(total_debit) = 5000.00
   from public.trial_balance(tap.v('a1'), date '2026-08-01', date '2026-08-31')),
  'the invoice journal is balanced (AR 5000 / Sales 5000)'
);
select is(
  (select balance from public.open_items(tap.v('a1'), 'invoice', date '2026-08-20')
   where document_id = tap.v('inv1')),
  5000.00::numeric(18,2),
  'the invoice sits in AR at its full open balance'
);

-- Issued documents freeze
select throws_like(
  $$ insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount)
     values (tap.v('inv1'), tap.v('a1'), 2, tap.v('acc_sales'), 'Sneak', 1.00) $$,
  '%frozen once the document is issued%',
  'lines cannot be added to an issued document'
);
update public.documents set memo = 'tampered' where id = tap.v('inv1');
select is(
  (select memo from public.documents where id = tap.v('inv1')),
  'August retainer',
  'API edits to an issued document match zero rows'
);

-- Partial payment: receipt applies 2000 of 5000
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id, memo)
  values (tap.v('a1'), 'receipt', date '2026-08-10', tap.v('cust'), tap.v('acc_cash'), 'Partial collection')
  returning id
) insert into tap.ctx select 'rcpt1', id from d;
insert into public.document_applications (client_id, paying_document_id, target_document_id, amount)
values (tap.v('a1'), tap.v('rcpt1'), tap.v('inv1'), 2000.00);
select lives_ok(
  $$ select public.issue_document(tap.v('rcpt1')) $$,
  'a partial payment issues'
);
select is(
  (select balance from public.open_items(tap.v('a1'), 'invoice', date '2026-08-20')
   where document_id = tap.v('inv1')),
  3000.00::numeric(18,2),
  'the invoice open balance drops to 3000 after the partial payment'
);

-- Over-application is rejected
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id)
  values (tap.v('a1'), 'receipt', date '2026-08-12', tap.v('cust'), tap.v('acc_cash'))
  returning id
) insert into tap.ctx select 'rcpt2', id from d;
insert into public.document_applications (client_id, paying_document_id, target_document_id, amount)
values (tap.v('a1'), tap.v('rcpt2'), tap.v('inv1'), 3500.00);
select throws_like(
  $$ select public.issue_document(tap.v('rcpt2')) $$,
  '%exceeds the open balance%',
  'a payment cannot apply more than the open balance'
);

-- Void ordering: settled invoice refuses to void until the payment is voided
select throws_like(
  $$ select public.void_document(tap.v('inv1')) $$,
  '%void those payments first%',
  'an invoice with applied payments cannot be voided directly'
);
select lives_ok(
  $$ select public.void_document(tap.v('rcpt1')) $$,
  'the payment voids (reversing its journal entry)'
);
select is(
  (select balance from public.open_items(tap.v('a1'), 'invoice', date '2026-08-20')
   where document_id = tap.v('inv1')),
  5000.00::numeric(18,2),
  'voiding the payment restores the invoice open balance'
);
select lives_ok(
  $$ select public.void_document(tap.v('inv1')) $$,
  'the invoice voids once unencumbered'
);
select ok(
  (select sum(total_debit) = sum(total_credit) from public.trial_balance(tap.v('a1'), date '2026-08-01', date '2026-08-31')),
  'the ledger stays balanced through issues, payments, and voids'
);

-- Bill + disbursement mirror
with d as (
  insert into public.documents (client_id, doc_type, doc_date, due_date, contact_id, memo)
  values (tap.v('a1'), 'bill', date '2026-06-01', date '2026-06-15', tap.v('vend'), 'June rent')
  returning id
) insert into tap.ctx select 'bill1', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount)
values (tap.v('bill1'), tap.v('a1'), 1, tap.v('acc_rent'), 'Rent', 1400.00);
select lives_ok(
  $$ select public.issue_document(tap.v('bill1')) $$,
  'a bill issues into AP'
);
select is(
  (select days_over_90 from public.aging(tap.v('a1'), 'bill', date '2026-12-31')
   where contact_id = tap.v('vend')),
  1400.00::numeric(18,2),
  'AP aging buckets the old bill as over 90 days'
);

-- Dashboard reads the live truth
select ok(
  (select (public.client_dashboard(tap.v('a1')) ->> 'ap_open')::numeric = 1400.00),
  'the dashboard reports open AP'
);

-- Tenancy: firm B sees nothing; viewer reads, never writes
select tap.login('22222222-2222-4222-8222-222222222205');
select is_empty(
  $$ select * from public.documents where client_id = tap.v('a1') $$,
  'firm B sees none of firm A''s documents'
);
select tap.login('22222222-2222-4222-8222-222222222204');
select throws_ok(
  $$ insert into public.contacts (client_id, name, contact_type)
     values (tap.v('a1'), 'Viewer Co', 'customer') $$,
  '42501', null,
  'the client viewer cannot create contacts'
);
select tap.logout();

select * from finish();
rollback;
