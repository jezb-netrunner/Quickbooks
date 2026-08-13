-- Audit hardening regressions: the cash side of payments must be cash,
-- voided documents read zero in the subsidiary books, account codes freeze
-- with history, and tax codes can never post into control or cash accounts.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(11);

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
insert into tap.ctx select 'tc_vat_out', id from public.tax_codes where client_id = tap.v('a1') and code = 'VAT12-OUT';
with c as (
  insert into public.contacts (client_id, name, contact_type) values (tap.v('a1'), 'Hard Cust', 'customer') returning id
) insert into tap.ctx select 'cust', id from c;
with c as (
  insert into public.contacts (client_id, name, contact_type) values (tap.v('a1'), 'Hard Vend', 'vendor') returning id
) insert into tap.ctx select 'vend', id from c;

-- 1/2: the cash side of a document must be an active 1000-series account
select throws_like(
  $$ insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id)
     values (tap.v('a1'), 'receipt', date '2026-08-01', tap.v('cust'), tap.v('acc_rent')) $$,
  '%must be an active 1000-series cash account%',
  'a receipt cannot move money through a non-cash account'
);
select throws_like(
  $$ insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id)
     values (tap.v('a1'), 'invoice', date '2026-08-01', tap.v('cust'), tap.v('acc_sales')) $$,
  '%must be an active 1000-series cash account%',
  'a cash invoice cannot settle into a non-cash account'
);

-- 3: voided invoices keep their row but read zero in the sales book
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-08-02', tap.v('cust'), 'To void') returning id
) insert into tap.ctx select 'inv1', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, tax_code_id)
values (tap.v('inv1'), tap.v('a1'), 1, tap.v('acc_sales'), '', 1000, tap.v('tc_vat_out'));
select public.issue_document(tap.v('inv1'));
select public.void_document(tap.v('inv1'));
select ok(
  (select status = 'voided' and gross = 0.00 and taxable = 0.00 and output_vat = 0.00
   from public.sales_book(tap.v('a1'), date '2026-08-02', date '2026-08-02')),
  'a voided invoice stays listed in the sales book with zero amounts'
);

-- 4: same for bills in the purchases book
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
  values (tap.v('a1'), 'bill', date '2026-08-03', tap.v('vend'), 'To void') returning id
) insert into tap.ctx select 'bill1', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount)
values (tap.v('bill1'), tap.v('a1'), 1, tap.v('acc_rent'), '', 400);
select public.issue_document(tap.v('bill1'));
select public.void_document(tap.v('bill1'));
select ok(
  (select status = 'voided' and gross = 0.00
   from public.purchases_book(tap.v('a1'), date '2026-08-03', date '2026-08-03')),
  'a voided bill stays listed in the purchases book with zero amounts'
);

-- 5/6: account codes freeze once postings exist
select throws_like(
  $$ update public.accounts set code = '4999' where id = tap.v('acc_sales') $$,
  '%code is part of the books%',
  'an account with postings cannot change its code'
);
with a as (
  insert into public.accounts (client_id, code, name, account_type, normal_balance)
  values (tap.v('a1'), '6905', 'Probe expense', 'expense', 'debit') returning id
) insert into tap.ctx select 'acc_new', id from a;
select lives_ok(
  $$ update public.accounts set code = '6906' where id = tap.v('acc_new') $$,
  'an unposted account can still be renamed'
);

-- 7/8: tax codes can never post into control or cash accounts
select throws_ok(
  $$ insert into public.tax_codes (client_id, code, name, kind, vat_class, account_code)
     values (tap.v('a1'), 'EVIL', 'VAT into AR', 'output_vat', 'taxable', '1100') $$,
  '23514', null,
  'a tax code cannot post to the AR control account'
);
select throws_ok(
  $$ update public.tax_codes set account_code = '2000' where id = tap.v('tc_vat_out') $$,
  '23514', null,
  'a tax code cannot be re-pointed at the AP control account'
);

-- 9/10: regime switches toggle VAT code availability
select public.seed_client_tax_codes(tap.v('a1'), 'non_vat');
select is(
  (select count(*) from public.tax_codes
   where client_id = tap.v('a1') and kind in ('output_vat', 'input_vat') and active),
  0::bigint,
  'switching to non_vat deactivates the VAT codes'
);
select public.seed_client_tax_codes(tap.v('a1'), 'vat');
select is(
  (select count(*) from public.tax_codes
   where client_id = tap.v('a1') and kind in ('output_vat', 'input_vat') and active),
  4::bigint,
  'switching back to vat reactivates them'
);

-- 11: a tax code from another client is unrepresentable on a line
select tap.logout();
select tap.login('22222222-2222-4222-8222-222222222201');
select public.seed_client_coa(tap.v('a2'));
with c as (
  insert into public.contacts (client_id, name, contact_type) values (tap.v('a2'), 'A2 Cust', 'customer') returning id
) insert into tap.ctx select 'cust2', id from c;
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id)
  values (tap.v('a2'), 'invoice', date '2026-08-04', tap.v('cust2')) returning id
) insert into tap.ctx select 'inv2', id from d;
insert into tap.ctx select 'a2_sales', id from public.accounts where client_id = tap.v('a2') and code = '4000';
select throws_ok(
  $$ insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, tax_code_id)
     values (tap.v('inv2'), tap.v('a2'), 1, tap.v('a2_sales'), '', 100, tap.v('tc_vat_out')) $$,
  '23503', null,
  'a line cannot reference a tax code belonging to another client'
);
select tap.logout();

select * from finish();
rollback;
