-- Phase 5: VAT/EWT automation — rates live in effective-dated data, the
-- engine generates every tax line, snapshots freeze at issue, cash invoices
-- never touch AR, and the BIR books read the truth.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(23);

\ir 000_fixture.sql.inc

select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.seed_client_coa(tap.v('a1'));
select set_config('request.jwt.claims', '', true);
insert into tap.ctx select 'acc_cash',   id from public.accounts where client_id = tap.v('a1') and code = '1000-02';
insert into tap.ctx select 'acc_sales',  id from public.accounts where client_id = tap.v('a1') and code = '4000';
insert into tap.ctx select 'acc_rent',   id from public.accounts where client_id = tap.v('a1') and code = '6100';
insert into tap.ctx select 'acc_vat_in', id from public.accounts where client_id = tap.v('a1') and code = '1310';
insert into tap.ctx select 'acc_cap',    id from public.accounts where client_id = tap.v('a1') and code = '3000';
grant insert on tap.ctx to authenticated;

select tap.login('22222222-2222-4222-8222-222222222202');

-- Seed the tax layer as staff
select public.seed_client_tax_codes(tap.v('a1'), 'vat');
select is(
  (select count(*) from public.tax_codes tc
   join public.tax_code_rates r on r.tax_code_id = tc.id
   where tc.client_id = tap.v('a1')),
  12::bigint,
  'a VAT-registered client seeds 12 tax codes, each with an opening rate'
);
select is(
  (select regime from public.client_tax_profiles where client_id = tap.v('a1')),
  'vat',
  'the tax profile stores the regime'
);
insert into tap.ctx select 'tc_vat_out', id from public.tax_codes where client_id = tap.v('a1') and code = 'VAT12-OUT';
insert into tap.ctx select 'tc_vat_in',  id from public.tax_codes where client_id = tap.v('a1') and code = 'VAT12-IN';
insert into tap.ctx select 'tc_cwt_svc', id from public.tax_codes where client_id = tap.v('a1') and code = 'CWT-SVC';
insert into tap.ctx select 'tc_ewt_svc', id from public.tax_codes where client_id = tap.v('a1') and code = 'EWT-SVC';
insert into tap.ctx select 'tc_ewt_gds', id from public.tax_codes where client_id = tap.v('a1') and code = 'EWT-GDS';

with c as (
  insert into public.contacts (client_id, name, contact_type, tin)
  values (tap.v('a1'), 'Vat Test Customer', 'customer', '111-222-333-000') returning id
) insert into tap.ctx select 'cust', id from c;
with c as (
  insert into public.contacts (client_id, name, contact_type, tin)
  values (tap.v('a1'), 'Vat Test Vendor', 'vendor', '444-555-666-000') returning id
) insert into tap.ctx select 'vend', id from c;

-- inv1: tax-EXCLUSIVE credit sale, 1000 net + 12% VAT
with d as (
  insert into public.documents (client_id, doc_type, doc_date, due_date, contact_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-08-01', date '2026-08-15', tap.v('cust'), 'Exclusive sale')
  returning id
) insert into tap.ctx select 'inv1', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, tax_code_id)
values (tap.v('inv1'), tap.v('a1'), 1, tap.v('acc_sales'), 'Goods', 1000.00, tap.v('tc_vat_out'));
select public.issue_document(tap.v('inv1'));
select is(
  (select sum(l.credit) from public.journal_lines l
   join public.accounts a on a.id = l.account_id
   join public.documents d on d.entry_id = l.entry_id
   where d.id = tap.v('inv1') and a.code = '2200'),
  120.00::numeric(18,2),
  'the engine credits Output VAT 12% of the exclusive line'
);
select is(
  (select balance from public.open_items(tap.v('a1'), 'invoice', date '2026-08-20')
   where document_id = tap.v('inv1')),
  1120.00::numeric(18,2),
  'the exclusive invoice is receivable at its gross (net + VAT)'
);

-- inv2: tax-INCLUSIVE credit sale, 1120 gross containing 12% VAT
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo, amounts_include_tax)
  values (tap.v('a1'), 'invoice', date '2026-08-02', tap.v('cust'), 'Inclusive sale', true)
  returning id
) insert into tap.ctx select 'inv2', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, tax_code_id)
values (tap.v('inv2'), tap.v('a1'), 1, tap.v('acc_sales'), 'Goods', 1120.00, tap.v('tc_vat_out'));
select public.issue_document(tap.v('inv2'));
select is(
  (select sum(l.credit) from public.journal_lines l
   join public.documents d on d.entry_id = l.entry_id
   where d.id = tap.v('inv2') and l.account_id = tap.v('acc_sales')),
  1000.00::numeric(18,2),
  'inclusive entry extracts the net: income is credited at amount / 1.12'
);
select is(
  (select balance from public.open_items(tap.v('a1'), 'invoice', date '2026-08-20')
   where document_id = tap.v('inv2')),
  1120.00::numeric(18,2),
  'the inclusive invoice is receivable at the amount as entered'
);

-- inv3: CASH sale on an invoice (EOPT: the invoice covers cash sales too)
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-08-03', tap.v('cust'), tap.v('acc_cash'), 'Cash sale')
  returning id
) insert into tap.ctx select 'inv3', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, tax_code_id)
values (tap.v('inv3'), tap.v('a1'), 1, tap.v('acc_sales'), 'Goods', 200.00, tap.v('tc_vat_out'));
select public.issue_document(tap.v('inv3'));
select is(
  (select sum(l.debit) from public.journal_lines l
   join public.documents d on d.entry_id = l.entry_id
   where d.id = tap.v('inv3') and l.account_id = tap.v('acc_cash')),
  224.00::numeric(18,2),
  'a cash invoice debits the bank account for the gross — no AR involved'
);
select is(
  (select count(*) from public.open_items(tap.v('a1'), 'invoice', date '2026-08-20')
   where document_id = tap.v('inv3')),
  0::bigint,
  'a cash invoice is born settled and never appears in AR'
);

-- Wrong-kind and tax-account lines are rejected at the gate
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id)
  values (tap.v('a1'), 'invoice', date '2026-08-04', tap.v('cust'))
  returning id
) insert into tap.ctx select 'inv_bad', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, tax_code_id)
values (tap.v('inv_bad'), tap.v('a1'), 1, tap.v('acc_sales'), 'Wrong kind', 100.00, tap.v('tc_ewt_gds'));
select throws_like(
  $$ select public.issue_document(tap.v('inv_bad')) $$,
  '%wrong kind for this document%',
  'an invoice line cannot carry a withholding tax code'
);
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id)
  values (tap.v('a1'), 'bill', date '2026-08-04', tap.v('vend'))
  returning id
) insert into tap.ctx select 'bill_bad', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount)
values (tap.v('bill_bad'), tap.v('a1'), 1, tap.v('acc_vat_in'), 'Hand-typed VAT', 60.00);
select throws_like(
  $$ select public.issue_document(tap.v('bill_bad')) $$,
  '%cannot post directly to a tax account%',
  'a document line pointing at a tax posting account is rejected'
);

-- bill1: tax-exclusive purchase, 500 + input VAT
with d as (
  insert into public.documents (client_id, doc_type, doc_date, due_date, contact_id, memo)
  values (tap.v('a1'), 'bill', date '2026-08-05', date '2026-08-25', tap.v('vend'), 'Rent billing')
  returning id
) insert into tap.ctx select 'bill1', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, tax_code_id)
values (tap.v('bill1'), tap.v('a1'), 1, tap.v('acc_rent'), 'Rent', 500.00, tap.v('tc_vat_in'));
select public.issue_document(tap.v('bill1'));
select is(
  (select sum(l.debit) from public.journal_lines l
   join public.accounts a on a.id = l.account_id
   join public.documents d on d.entry_id = l.entry_id
   where d.id = tap.v('bill1') and a.code = '1310'),
  60.00::numeric(18,2),
  'the engine debits Input VAT on the bill'
);
select is(
  (select balance from public.open_items(tap.v('a1'), 'bill', date '2026-08-20')
   where document_id = tap.v('bill1')),
  560.00::numeric(18,2),
  'the bill is payable at gross including input VAT'
);

-- rcpt1: collect inv1 in full; customer withheld 2% CWT on the 1000 net
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id, memo,
                                wht_tax_code_id, wht_base)
  values (tap.v('a1'), 'receipt', date '2026-08-10', tap.v('cust'), tap.v('acc_cash'), 'Collection',
          tap.v('tc_cwt_svc'), 1000.00)
  returning id
) insert into tap.ctx select 'rcpt1', id from d;
insert into public.document_applications (client_id, paying_document_id, target_document_id, amount)
values (tap.v('a1'), tap.v('rcpt1'), tap.v('inv1'), 1120.00);
select public.issue_document(tap.v('rcpt1'));
select ok(
  (select sum(l.debit) filter (where a.code = '1320') = 20.00
      and sum(l.debit) filter (where l.account_id = tap.v('acc_cash')) = 1100.00
      and sum(l.credit) filter (where a.code = '1100') = 1120.00
   from public.journal_lines l
   join public.accounts a on a.id = l.account_id
   join public.documents d on d.entry_id = l.entry_id
   where d.id = tap.v('rcpt1')),
  'the receipt splits the collection: cash 1100, CWT asset 20, AR relieved 1120'
);
select is(
  (select count(*) from public.open_items(tap.v('a1'), 'invoice', date '2026-08-20')
   where document_id = tap.v('inv1')),
  0::bigint,
  'the withheld collection still settles the invoice in full'
);

-- disb1: pay bill1 in full; we withhold 2% EWT on the 500 net
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id, memo,
                                wht_tax_code_id, wht_base)
  values (tap.v('a1'), 'disbursement', date '2026-08-11', tap.v('vend'), tap.v('acc_cash'), 'Rent payment',
          tap.v('tc_ewt_svc'), 500.00)
  returning id
) insert into tap.ctx select 'disb1', id from d;
insert into public.document_applications (client_id, paying_document_id, target_document_id, amount)
values (tap.v('a1'), tap.v('disb1'), tap.v('bill1'), 560.00);
select public.issue_document(tap.v('disb1'));
select ok(
  (select sum(l.credit) filter (where a.code = '2230') = 10.00
      and sum(l.credit) filter (where l.account_id = tap.v('acc_cash')) = 550.00
      and sum(l.debit) filter (where a.code = '2000') = 560.00
   from public.journal_lines l
   join public.accounts a on a.id = l.account_id
   join public.documents d on d.entry_id = l.entry_id
   where d.id = tap.v('disb1')),
  'the disbursement withholds EWT: AP relieved 560, cash 550, EWT payable 10'
);

-- Effective-dated rates: a 15% VAT rate starting September applies to
-- September documents and leaves August snapshots untouched.
insert into public.tax_code_rates (tax_code_id, client_id, effective_from, rate)
values (tap.v('tc_vat_out'), tap.v('a1'), date '2026-09-01', 0.15);
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-09-05', tap.v('cust'), 'September sale')
  returning id
) insert into tap.ctx select 'inv4', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, tax_code_id)
values (tap.v('inv4'), tap.v('a1'), 1, tap.v('acc_sales'), 'Goods', 100.00, tap.v('tc_vat_out'));
select public.issue_document(tap.v('inv4'));
select is(
  (select amount from public.document_taxes where document_id = tap.v('inv4')),
  15.00::numeric(18,2),
  'a September document picks up the rate effective in September'
);
select is(
  (select amount from public.document_taxes where document_id = tap.v('inv2')),
  120.00::numeric(18,2),
  'August snapshots are immune to later rate rows'
);
-- The API role has no UPDATE grant on document_taxes at all (the frozen
-- trigger behind it is a second layer for the definer path).
select throws_ok(
  $$ update public.document_taxes set amount = 1.00 where document_id = tap.v('inv2') $$,
  '42501', null,
  'frozen tax snapshots cannot be edited through the API'
);

-- BIR books
select ok(
  (select gross = 1120.00 and taxable = 1000.00 and output_vat = 120.00
   from public.sales_book(tap.v('a1'), date '2026-08-01', date '2026-08-31')
   where doc_no = (select doc_no from public.documents where id = tap.v('inv1'))),
  'the sales book splits the exclusive invoice into taxable base and output VAT'
);
select ok(
  (select gross = 560.00 and taxable = 500.00 and input_vat = 60.00
   from public.purchases_book(tap.v('a1'), date '2026-08-01', date '2026-08-31')
   where ref = 'BILL-' || (select doc_no from public.documents where id = tap.v('bill1'))),
  'the purchases book shows the bill gross, net, and input VAT'
);
select ok(
  (select cash = 1100.00 and cwt = 20.00 and ar_credit = 1120.00
   from public.cash_receipts_book(tap.v('a1'), date '2026-08-01', date '2026-08-31')
   where ar_credit = 1120.00),
  'the cash receipts book carries the columnar split of the collection'
);

-- General journal book: manual non-cash entries only
with s as (
  insert into public.journal_entries (client_id, entry_date, memo)
  values (tap.v('a1'), date '2026-08-15', 'Accrue owner cap adj') returning id
) insert into tap.ctx select 'je_manual', id from s;
insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit) values
  (tap.v('je_manual'), tap.v('a1'), 1, tap.v('acc_rent'), 100, 0),
  (tap.v('je_manual'), tap.v('a1'), 2, tap.v('acc_cap'), 0, 100);
select public.post_entry(tap.v('je_manual'));
select ok(
  (select count(distinct entry_no) = 1 and count(*) = 2
   from public.general_journal_book(tap.v('a1'), date '2026-08-01', date '2026-08-31')),
  'the general journal book holds only the manual non-cash entry — documents and cash entries live in their own books'
);

-- Viewer is read-only on the tax layer
select tap.logout();
select tap.login('22222222-2222-4222-8222-222222222204');
select throws_ok(
  $$ insert into public.tax_codes (client_id, code, name, kind, vat_class, account_code)
     values (tap.v('a1'), 'HAX', 'Nope', 'output_vat', 'taxable', '2200') $$,
  '42501', null,
  'a client viewer cannot create tax codes'
);
select tap.logout();

select * from finish();
rollback;
