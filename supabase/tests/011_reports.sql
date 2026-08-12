-- Phase 4: financial statements agree with each other and with the ledger,
-- and the control-account guard closes the AR-against-AR hole.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(9);

\ir 000_fixture.sql.inc

select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.seed_client_coa(tap.v('a1'));
select set_config('request.jwt.claims', '', true);
insert into tap.ctx select 'acc_cash',  id from public.accounts where client_id = tap.v('a1') and code = '1000-02';
insert into tap.ctx select 'acc_ar',    id from public.accounts where client_id = tap.v('a1') and code = '1100';
insert into tap.ctx select 'acc_svc',   id from public.accounts where client_id = tap.v('a1') and code = '4100';
insert into tap.ctx select 'acc_rent',  id from public.accounts where client_id = tap.v('a1') and code = '6100';
insert into tap.ctx select 'acc_cap',   id from public.accounts where client_id = tap.v('a1') and code = '3000';
grant insert on tap.ctx to authenticated;

-- Ledger fixture, posted as staff through the engine:
--   opening: cash 10000 / owner's capital 10000
--   cash service sale 1500; rent paid 400
select tap.login('22222222-2222-4222-8222-222222222202');
do $fix$
declare
  v uuid;
begin
  insert into public.journal_entries (client_id, entry_date, memo)
  values (tap.v('a1'), date '2026-01-05', 'Opening') returning id into v;
  insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit) values
    (v, tap.v('a1'), 1, tap.v('acc_cash'), 10000, 0),
    (v, tap.v('a1'), 2, tap.v('acc_cap'), 0, 10000);
  perform public.post_entry(v);

  insert into public.journal_entries (client_id, entry_date, memo)
  values (tap.v('a1'), date '2026-08-03', 'Cash service sale') returning id into v;
  insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit) values
    (v, tap.v('a1'), 1, tap.v('acc_cash'), 1500, 0),
    (v, tap.v('a1'), 2, tap.v('acc_svc'), 0, 1500);
  perform public.post_entry(v);

  insert into public.journal_entries (client_id, entry_date, memo)
  values (tap.v('a1'), date '2026-08-05', 'Rent') returning id into v;
  insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit) values
    (v, tap.v('a1'), 1, tap.v('acc_rent'), 400, 0),
    (v, tap.v('a1'), 2, tap.v('acc_cash'), 0, 400);
  perform public.post_entry(v);
end $fix$;

-- P&L
select is(
  (select sum(amount) filter (where account_type = 'income')
   from public.profit_and_loss(tap.v('a1'), date '2026-08-01', date '2026-08-31')),
  1500.00::numeric(18,2),
  'P&L income for August is the service sale'
);
select is(
  (select sum(amount) filter (where account_type = 'expense')
   from public.profit_and_loss(tap.v('a1'), date '2026-08-01', date '2026-08-31')),
  400.00::numeric(18,2),
  'P&L expenses for August is the rent'
);

-- Balance sheet balances: assets = liabilities + equity (incl. earnings row)
select is(
  (select sum(balance) filter (where account_type = 'asset')
   from public.balance_sheet(tap.v('a1'), date '2026-08-31')),
  11100.00::numeric(18,2),
  'assets as of August: 10000 opening + 1500 sale - 400 rent'
);
select ok(
  (select sum(balance) filter (where account_type = 'asset')
       = sum(balance) filter (where account_type in ('liability', 'equity'))
   from public.balance_sheet(tap.v('a1'), date '2026-08-31')),
  'the balance sheet balances through the cumulative earnings row'
);

-- Cash flow reconciles to the cash delta for the period
select is(
  (select amount from public.cash_flow_indirect(tap.v('a1'), date '2026-08-01', date '2026-08-31')
   where section = 'cash'),
  1100.00::numeric(18,2),
  'net change in cash for August is 1500 in minus 400 out'
);
select is(
  (select sum(amount) from public.cash_flow_indirect(tap.v('a1'), date '2026-08-01', date '2026-08-31')
   where section <> 'cash'),
  1100.00::numeric(18,2),
  'operating/investing/financing sections explain the cash change'
);

-- GL drill-down running balance
select is(
  (select running from public.general_ledger(tap.v('a1'), tap.v('acc_cash'), date '2026-08-01', date '2026-08-31')
   order by entry_date desc, entry_no desc nulls last limit 1),
  11100.00::numeric(18,2),
  'the GL running balance ends at the account balance'
);

-- The AR-against-AR hole is closed at the gate
with c as (
  insert into public.contacts (client_id, name, contact_type)
  values (tap.v('a1'), 'Guard Test Co', 'customer') returning id
) insert into tap.ctx select 'guard_cust', id from c;
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-08-10', tap.v('guard_cust'), 'Bad line test')
  returning id
) insert into tap.ctx select 'bad_inv', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount)
values (tap.v('bad_inv'), tap.v('a1'), 1, tap.v('acc_ar'), 'Wrong account', 500.00);
select throws_like(
  $$ select public.issue_document(tap.v('bad_inv')) $$,
  '%cannot use the receivable or payable control accounts%',
  'an invoice line pointing at the AR control account is rejected at issue'
);
select lives_ok(
  $$ do $ok$ begin
       update public.document_lines set account_id = tap.v('acc_svc')
        where document_id = tap.v('bad_inv');
       perform public.issue_document(tap.v('bad_inv'));
     end $ok$ $$,
  'the same invoice issues once the line uses an income account'
);
select tap.logout();

select * from finish();
rollback;
