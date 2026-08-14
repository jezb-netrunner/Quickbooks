-- Phase 3 regression suite — accounting integrity.
-- P3-05: reverse_entry serializes and cannot double-reverse; a reversal exactly
-- cancels the original in the GL.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(6);

\ir 000_fixture.sql.inc

-- A chart of accounts for Firm A's client a1.
select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.seed_client_coa(tap.v('a1'));
select set_config('request.jwt.claims', '', true);
insert into tap.ctx select 'acc_rent', id from public.accounts where client_id = tap.v('a1') and code = '6100';
insert into tap.ctx select 'acc_cash', id from public.accounts where client_id = tap.v('a1') and code = '1000-02';

-- A posted manual JE: DR Rent 100 / CR Cash 100 (owner sets it up; admin posts).
with e as (
  insert into public.journal_entries (client_id, entry_date, memo)
  values (tap.v('a1'), date '2026-08-10', 'rent for August') returning id
) insert into tap.ctx select 'je', id from e;
insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit) values
  (tap.v('je'), tap.v('a1'), 1, tap.v('acc_rent'), 100, 0),
  (tap.v('je'), tap.v('a1'), 2, tap.v('acc_cash'), 0, 100);
select tap.login('22222222-2222-4222-8222-222222222201');
select public.post_entry(tap.v('je'));

-- P3-05
select lives_ok(
  $$ select public.reverse_entry(tap.v('je')) $$,
  'P3-05: a posted entry reverses'
);
select ok(
  (select reversed_by from public.journal_entries where id = tap.v('je')) is not null,
  'P3-05: the original entry is flagged reversed'
);
select is(
  (select count(*) from public.journal_entries
    where reversal_of = tap.v('je') and source_type = 'reversal'),
  1::bigint,
  'P3-05: exactly one reversing entry exists'
);
-- Money invariant: original + reversal net to zero on both accounts.
select is(
  (select coalesce(sum(l.debit - l.credit), 0)
     from public.journal_lines l join public.journal_entries e2 on e2.id = l.entry_id
    where e2.client_id = tap.v('a1') and l.account_id = tap.v('acc_rent')),
  0::numeric,
  'P3-05: Rent nets to zero after reversal (the reversal cancels the original)'
);
select is(
  (select coalesce(sum(l.debit - l.credit), 0)
     from public.journal_lines l join public.journal_entries e2 on e2.id = l.entry_id
    where e2.client_id = tap.v('a1') and l.account_id = tap.v('acc_cash')),
  0::numeric,
  'P3-05: Cash nets to zero after reversal'
);
select throws_like(
  $$ select public.reverse_entry(tap.v('je')) $$,
  '%already reversed%',
  'P3-05: reversing the same entry a second time is rejected'
);
select tap.logout();

select * from finish();
rollback;
