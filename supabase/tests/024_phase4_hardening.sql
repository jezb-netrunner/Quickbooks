-- Hardening-pass regressions: P3-03 (WHT base net-of-VAT cap), P3-06 (FIFO
-- sub-centavo cap), T-05 (compliance start bound), P2-18 (filing guard),
-- P3-10 (books resolve re-pointed tax accounts), P2-22 (bank input VAT),
-- P2-17 (pre-close counts), and a P3-18 pin (on-account purchase ties to the
-- 2550Q through the purchases book).
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(20);

\ir 000_fixture.sql.inc

select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.seed_client_coa(tap.v('a1'));
select public.seed_client_tax_codes(tap.v('a1'), 'vat');
select set_config('request.jwt.claims', '', true);

insert into tap.ctx select 'acc_sales', id from public.accounts where client_id = tap.v('a1') and code = '4000';
insert into tap.ctx select 'acc_cash',  id from public.accounts where client_id = tap.v('a1') and code = '1000-02';
insert into tap.ctx select 'acc_rent',  id from public.accounts where client_id = tap.v('a1') and code = '6100';
insert into tap.ctx select 'vat_out', id from public.tax_codes where client_id = tap.v('a1') and code = 'VAT12-OUT';
insert into tap.ctx select 'vat_in',  id from public.tax_codes where client_id = tap.v('a1') and code = 'VAT12-IN';
insert into tap.ctx select 'cwt',     id from public.tax_codes where client_id = tap.v('a1') and code = 'CWT-GDS';
grant insert on tap.ctx to authenticated;

select tap.login('22222222-2222-4222-8222-222222222201');
with c as (
  insert into public.contacts (client_id, name, contact_type)
  values (tap.v('a1'), 'Mango Grove Cafe', 'customer') returning id
) insert into tap.ctx select 'cust', id from c;
with c as (
  insert into public.contacts (client_id, name, contact_type)
  values (tap.v('a1'), 'Petron Dealer', 'vendor') returning id
) insert into tap.ctx select 'vend', id from c;

-- ---------------------------------------------------------------- P3-03
-- Invoice: net 10,000 + VAT 1,200 (exclusive) = 11,200 gross.
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-08-03', tap.v('cust'), 'August sale')
  returning id
) insert into tap.ctx select 'inv1', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, tax_code_id)
values (tap.v('inv1'), tap.v('a1'), 1, tap.v('acc_sales'), 'Goods', 10000.00, tap.v('vat_out'));
select public.issue_document(tap.v('inv1'));

-- Receipt applying the full 11,200 gross with a base typed as the GROSS.
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id, memo, wht_tax_code_id, wht_base)
  values (tap.v('a1'), 'receipt', date '2026-08-05', tap.v('cust'), tap.v('acc_cash'), 'Collection', tap.v('cwt'), 11200.00)
  returning id
) insert into tap.ctx select 'rcpt1', id from d;
insert into public.document_applications (client_id, paying_document_id, target_document_id, amount)
values (tap.v('a1'), tap.v('rcpt1'), tap.v('inv1'), 11200.00);
select throws_like(
  $$ select public.issue_document(tap.v('rcpt1')) $$,
  '%exceeds the net-of-VAT value%',
  'P3-03: a withholding base above the applied net-of-VAT is rejected'
);
update public.documents set wht_base = 10000.00 where id = tap.v('rcpt1');
select lives_ok(
  $$ select public.issue_document(tap.v('rcpt1')) $$,
  'P3-03: the correct net-of-VAT base issues (CWT 1% on 10,000 = 100)'
);

-- Partial payment: 5,600 of a fresh 11,200 invoice — the ceiling pro-rates.
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-08-04', tap.v('cust'), 'Second sale')
  returning id
) insert into tap.ctx select 'inv2', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, tax_code_id)
values (tap.v('inv2'), tap.v('a1'), 1, tap.v('acc_sales'), 'Goods', 10000.00, tap.v('vat_out'));
select public.issue_document(tap.v('inv2'));
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id, memo, wht_tax_code_id, wht_base)
  values (tap.v('a1'), 'receipt', date '2026-08-06', tap.v('cust'), tap.v('acc_cash'), 'Partial', tap.v('cwt'), 5600.00)
  returning id
) insert into tap.ctx select 'rcpt2', id from d;
insert into public.document_applications (client_id, paying_document_id, target_document_id, amount)
values (tap.v('a1'), tap.v('rcpt2'), tap.v('inv2'), 5600.00);
select throws_like(
  $$ select public.issue_document(tap.v('rcpt2')) $$,
  '%exceeds the net-of-VAT value%',
  'P3-03: a partial payment''s base ceiling pro-rates (5,600 gross → 5,000 net)'
);
update public.documents set wht_base = 5000.00 where id = tap.v('rcpt2');
select lives_ok(
  $$ select public.issue_document(tap.v('rcpt2')) $$,
  'P3-03: the pro-rated net base issues'
);

-- ---------------------------------------------------------------- P3-06
-- 100 units at half a centavo each: cost_total 0.50, unit_cost 0.005 —
-- every single-unit take used to round to ₱0.01 and overshoot the layer.
with i as (
  insert into public.items (client_id, sku, name) values (tap.v('a1'), 'PENNY', 'Penny candy')
  returning id
) insert into tap.ctx select 'penny', id from i;
select lives_ok(
  $$ select public.post_stock_adjustment(tap.v('a1'), tap.v('penny'), date '2026-08-02', 100, 0.005, tap.v('acc_rent'), 'Opening') $$,
  'P3-06: a half-centavo unit cost layer opens (cost_total 0.50)'
);
select tap.logout();
-- 60 single-unit consumptions, then the exhausting 40 — direct engine calls.
do $do$
begin
  for i in 1..60 loop
    perform app.consume_fifo(tap.v('a1'), tap.v('penny'), 1, null, null, date '2026-08-02');
  end loop;
end $do$;
select is(
  (select sum(c.cost)::numeric(18,2) from public.layer_consumptions c
   join public.inventory_layers l on l.id = c.layer_id where l.item_id = tap.v('penny')),
  0.50::numeric(18,2),
  'P3-06: cumulative consumption caps at the layer''s cost_total (no overshoot)'
);
select lives_ok(
  $$ select app.consume_fifo(tap.v('a1'), tap.v('penny'), 40, null, null, date '2026-08-02') $$,
  'P3-06: the last units remain sellable (exhausting take is never negative)'
);
select is(
  (select coalesce(sum(l.cost_total) - (
     select coalesce(sum(c.cost), 0) from public.layer_consumptions c
     join public.inventory_layers l2 on l2.id = c.layer_id where l2.item_id = tap.v('penny')), 0)::numeric(18,2)
   from public.inventory_layers l where l.item_id = tap.v('penny')),
  0.00::numeric(18,2),
  'P3-06: an exhausted layer holds exactly zero residual value — never negative'
);

-- ---------------------------------------------------------------- T-05
select tap.login('22222222-2222-4222-8222-222222222201');
select public.seed_client_compliance(tap.v('a1'));
select is(
  (select count(*)::int from public.compliance_calendar(tap.v('a1'), 2026) where form = '0619-E'),
  8,
  'T-05/P2-26: with no start bound, 0619-E runs its eight non-quarter months'
);
update public.client_tax_profiles set compliance_start = date '2026-07-01'
 where client_id = tap.v('a1');
select ok(
  (select count(*) = 4
      and count(*) filter (where period_end < date '2026-07-01') = 0
   from public.compliance_calendar(tap.v('a1'), 2026) where form = '0619-E')
  and exists (select 1 from public.compliance_calendar(tap.v('a1'), 2026) where form = '1604-E'),
  'T-05: deadlines before the compliance start vanish; year-end forms stay'
);

-- ---------------------------------------------------------------- P2-18
select public.set_filing_status(tap.v('a1'), '2550Q',
  date '2026-01-01', date '2026-03-31', date '2026-04-25', 'filed', 'EFPS-123');
select throws_like(
  $$ select public.set_filing_status(tap.v('a1'), '2550Q',
       date '2026-01-01', date '2026-03-31', date '2026-04-25', 'pending') $$,
  '%explicit confirmation%',
  'P2-18: un-filing a filed return without confirmation is refused'
);
select public.set_filing_status(tap.v('a1'), '2550Q',
  date '2026-01-01', date '2026-03-31', date '2026-04-25', 'filed', '');
select is(
  (select reference from public.compliance_filings
   where client_id = tap.v('a1') and form = '2550Q' and period_end = date '2026-03-31'),
  'EFPS-123',
  'P2-18: an empty reference keeps the stored one instead of erasing it'
);
select public.set_filing_status(tap.v('a1'), '2550Q',
  date '2026-01-01', date '2026-03-31', date '2026-04-25', 'pending', '', true);
select ok(
  not exists (select 1 from public.compliance_filings
              where client_id = tap.v('a1') and form = '2550Q' and period_end = date '2026-03-31'),
  'P2-18: with explicit confirmation the filing record clears'
);

-- ---------------------------------------------------------------- P3-10
-- Re-point Output VAT to a custom account; the receipts book must still
-- land it in the output_vat column, not Sundry.
select tap.logout();
insert into public.accounts (client_id, code, name, account_type, normal_balance)
values (tap.v('a1'), '2290', 'Output VAT (custom)', 'liability', 'credit');
update public.tax_codes set account_code = '2290'
 where client_id = tap.v('a1') and code = 'VAT12-OUT';
select tap.login('22222222-2222-4222-8222-222222222201');
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, bank_account_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-08-12', tap.v('cust'), tap.v('acc_cash'), 'Cash sale')
  returning id
) insert into tap.ctx select 'inv3', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, tax_code_id)
values (tap.v('inv3'), tap.v('a1'), 1, tap.v('acc_sales'), 'Goods', 1000.00, tap.v('vat_out'));
select public.issue_document(tap.v('inv3'));
select ok(
  (select b.output_vat = 120.00 and b.sundry_credit = 0
   from public.cash_receipts_book(tap.v('a1'), date '2026-08-12', date '2026-08-12') b
   limit 1),
  'P3-10: a re-pointed output-VAT account still fills the book''s VAT column'
);

-- ---------------------------------------------------------------- P2-22
do $do$
begin
  perform * from public.import_bank_txns(
    tap.v('a1'), tap.v('acc_cash'),
    '[{"d":"2026-08-10","a":-1120.00,"m":"Fuel purchase"},
      {"d":"2026-08-11","a":-500.00,"m":"Uncategorized"}]'::jsonb);
end $do$;
insert into tap.ctx
  select 'btx', id from public.bank_txns
  where client_id = tap.v('a1') and amount = -1120.00;
select lives_ok(
  $$ select public.categorize_bank_txn(tap.v('btx'), tap.v('acc_rent'), null, tap.v('vat_in')) $$,
  'P2-22: a bank line categorizes with an input-VAT code'
);
select ok(
  (select sum(l.debit) filter (where a.code = '6100') = 1000.00
      and sum(l.debit) filter (where a.code = '1310') = 120.00
      and sum(l.credit) filter (where a.code = '1000-02') = 1120.00
   from public.bank_txns b
   join public.journal_lines l on l.entry_id = b.entry_id
   join public.accounts a on a.id = l.account_id
   where b.id = tap.v('btx')),
  'P2-22: the entry splits net 1,000 to expense and 120 to input VAT'
);
select is(
  (select amount from public.wp_vat(tap.v('a1'), date '2026-08-10', date '2026-08-11') where line_no = 5),
  120.00::numeric(18,2),
  'P2-22: the 2550Q input-tax line counts bank-captured VAT'
);

-- ---------------------------------------------------------------- P2-17
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-08-25', tap.v('cust'), 'Still a draft')
  returning id
) insert into tap.ctx select 'draft1', id from d;
select ok(
  (select c.draft_docs = 1 and c.pending_bank = 1
   from public.period_close_check(
     (select id from public.periods where client_id = tap.v('a1')
      and period_start = date '2026-08-01')) c),
  'P2-17: the pre-close check counts the month''s drafts and pending bank lines'
);

-- ---------------------------------------------------------------- P3-18 pin
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
  values (tap.v('a1'), 'purchase', date '2026-08-20', tap.v('vend'), 'On-account supplies')
  returning id
) insert into tap.ctx select 'pr1', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount, tax_code_id)
values (tap.v('pr1'), tap.v('a1'), 1, tap.v('acc_rent'), 'Supplies', 2000.00, tap.v('vat_in'));
select public.issue_document(tap.v('pr1'));
select ok(
  exists (select 1 from public.purchases_book(tap.v('a1'), date '2026-08-01', date '2026-08-31')
          where ref like 'PR-%' and input_vat = 240.00),
  'P3-18: an on-account purchase shows in the purchases book with its VAT'
);
select is(
  (select amount from public.wp_vat(tap.v('a1'), date '2026-08-01', date '2026-08-31') where line_no = 5),
  360.00::numeric(18,2),
  'P3-18: the same VAT (240 purchase + 120 bank) reaches the 2550Q input line'
);
select tap.logout();

select * from finish();
rollback;
