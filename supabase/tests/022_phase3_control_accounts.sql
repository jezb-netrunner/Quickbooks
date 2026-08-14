-- Phase 3 regression — a free-form manual journal entry cannot post to a
-- control account (P3-02). Those subledgers are owned by the document engine and
-- stock adjustments; a manual posting to them desyncs open_items /
-- inventory_valuation from the GL.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(3);

\ir 000_fixture.sql.inc

select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.seed_client_coa(tap.v('a1'));
select set_config('request.jwt.claims', '', true);
insert into tap.ctx select 'acc_ar',    id from public.accounts where client_id = tap.v('a1') and code = '1100';
insert into tap.ctx select 'acc_sales', id from public.accounts where client_id = tap.v('a1') and code = '4000';
insert into tap.ctx select 'acc_rent',  id from public.accounts where client_id = tap.v('a1') and code = '6100';
insert into tap.ctx select 'acc_cash',  id from public.accounts where client_id = tap.v('a1') and code = '1000-02';

-- A manual JE that posts DIRECTLY to the AR control account (the bug).
with e as (
  insert into public.journal_entries (client_id, entry_date, memo)
  values (tap.v('a1'), date '2026-08-12', 'hand-posted AR') returning id
) insert into tap.ctx select 'je_bad', id from e;
insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit) values
  (tap.v('je_bad'), tap.v('a1'), 1, tap.v('acc_ar'),    100, 0),
  (tap.v('je_bad'), tap.v('a1'), 2, tap.v('acc_sales'), 0, 100);

-- A normal manual JE that uses no control accounts.
with e as (
  insert into public.journal_entries (client_id, entry_date, memo)
  values (tap.v('a1'), date '2026-08-12', 'rent accrual') returning id
) insert into tap.ctx select 'je_ok', id from e;
insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit) values
  (tap.v('je_ok'), tap.v('a1'), 1, tap.v('acc_rent'), 50, 0),
  (tap.v('je_ok'), tap.v('a1'), 2, tap.v('acc_cash'), 0, 50);

select tap.login('22222222-2222-4222-8222-222222222201');
select throws_like(
  $$ select public.post_entry(tap.v('je_bad')) $$,
  '%control account%',
  'P3-02: a manual JE posting to the AR control account is rejected'
);
select lives_ok(
  $$ select public.post_entry(tap.v('je_ok')) $$,
  'P3-02: a normal manual JE (no control accounts) still posts'
);
select tap.logout();

-- P3-11: archive an account that the posted entry used, then reverse it — the
-- reversal replays the original lines and must be allowed despite the archive.
update public.accounts set archived_at = now() where id = tap.v('acc_rent');
select tap.login('22222222-2222-4222-8222-222222222201');
select lives_ok(
  $$ select public.reverse_entry(tap.v('je_ok')) $$,
  'P3-11: an entry using a since-archived account can still be reversed/voided'
);
select tap.logout();

select * from finish();
rollback;
