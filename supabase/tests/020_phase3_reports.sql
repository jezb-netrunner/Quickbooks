-- Phase 3 regression — trial balance ties even when an account with postings is
-- archived (P3-07). Before the fix, archiving one side of a posted entry dropped
-- that side from the TB, so total_debit no longer equalled total_credit.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(3);

\ir 000_fixture.sql.inc

select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.seed_client_coa(tap.v('a1'));
select set_config('request.jwt.claims', '', true);
insert into tap.ctx select 'acc_cash',  id from public.accounts where client_id = tap.v('a1') and code = '1000-02';
insert into tap.ctx select 'acc_sales', id from public.accounts where client_id = tap.v('a1') and code = '4000';

-- A posted cash sale: DR Cash 200 / CR Sales 200.
with e as (
  insert into public.journal_entries (client_id, entry_date, memo)
  values (tap.v('a1'), date '2026-08-05', 'cash sale') returning id
) insert into tap.ctx select 'je', id from e;
insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit) values
  (tap.v('je'), tap.v('a1'), 1, tap.v('acc_cash'),  200, 0),
  (tap.v('je'), tap.v('a1'), 2, tap.v('acc_sales'), 0, 200);
select tap.login('22222222-2222-4222-8222-222222222201');
select public.post_entry(tap.v('je'));
select tap.logout();

-- Archive the Sales account even though it carries a posting (permitted today).
update public.accounts set archived_at = now() where id = tap.v('acc_sales');

-- P3-07
select tap.login('22222222-2222-4222-8222-222222222201');
select is(
  (select sum(total_debit)  from public.trial_balance(tap.v('a1'), date '2026-01-01', date '2026-12-31')),
  (select sum(total_credit) from public.trial_balance(tap.v('a1'), date '2026-01-01', date '2026-12-31')),
  'P3-07: the trial balance still balances after archiving an account with postings'
);
select ok(
  exists (select 1 from public.trial_balance(tap.v('a1'), date '2026-01-01', date '2026-12-31')
          where code = '4000'),
  'P3-07: the archived account with in-range movement still appears in the TB'
);
select is(
  (select total_credit from public.trial_balance(tap.v('a1'), date '2026-01-01', date '2026-12-31')
   where code = '4000'),
  200::numeric(18,2),
  'P3-07: its 200 credit is included, so the TB ties to the P&L/BS'
);
select tap.logout();

select * from finish();
rollback;
