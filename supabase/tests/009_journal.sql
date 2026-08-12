-- Phase 2: the journal engine — balance, immutability, period gate, reversal,
-- structural tenancy, trial balance. Non-negotiables #2 and #3 live here.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(18);

\ir 000_fixture.sql.inc

-- Fixture: charts for both firms' clients; capture working account ids.
select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.seed_client_coa(tap.v('a1'));
select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222205', 'role', 'authenticated')::text, true);
select public.seed_client_coa(tap.v('b1'));
select set_config('request.jwt.claims', '', true);
insert into tap.ctx select 'acc_cash',  id from public.accounts where client_id = tap.v('a1') and code = '1000-02';
insert into tap.ctx select 'acc_sales', id from public.accounts where client_id = tap.v('a1') and code = '4000';
insert into tap.ctx select 'acc_b_cash', id from public.accounts where client_id = tap.v('b1') and code = '1000-02';
grant insert on tap.ctx to authenticated;

-- Assigned staff drafts an entry through the plain API
select tap.login('22222222-2222-4222-8222-222222222202');
with e as (
  insert into public.journal_entries (client_id, entry_date, memo)
  values (tap.v('a1'), date '2026-07-15', 'Cash sale') returning id
) insert into tap.ctx select 'e1', id from e;
insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
values (tap.v('e1'), tap.v('a1'), 1, tap.v('acc_cash'), 500.00, 0),
       (tap.v('e1'), tap.v('a1'), 2, tap.v('acc_sales'), 0, 250.00);
select is(
  (select status from public.journal_entries where id = tap.v('e1')),
  'draft',
  'staff can draft an entry with lines through the API'
);

-- One-sided line rule and balance gate
select throws_ok(
  $$ insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
     values (tap.v('e1'), tap.v('a1'), 3, tap.v('acc_cash'), 10.00, 10.00) $$,
  '23514', null,
  'a line must have exactly one of debit/credit non-zero'
);
select throws_like(
  $$ select public.post_entry(tap.v('e1')) $$,
  '%out of balance%',
  'an unbalanced entry cannot post (500.00 vs 250.00)'
);
update public.journal_lines set credit = 500.00
 where entry_id = tap.v('e1') and line_no = 2;
select is(
  (select public.post_entry(tap.v('e1'))),
  1::bigint,
  'the balanced entry posts and takes entry number 1'
);

-- Posted entries are immutable — through the API and through owner context
update public.journal_entries set memo = 'tampered' where id = tap.v('e1');
select is(
  (select memo from public.journal_entries where id = tap.v('e1')),
  'Cash sale',
  'API updates to a posted entry match zero rows (draft-only policy)'
);
select throws_like(
  $$ insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
     values (tap.v('e1'), tap.v('a1'), 3, tap.v('acc_cash'), 1.00, 0) $$,
  '%immutable%',
  'adding lines to a posted entry is rejected (trigger fires before the draft-only policy)'
);
delete from public.journal_entries where id = tap.v('e1');
select is(
  (select count(*) from public.journal_entries where id = tap.v('e1')),
  1::bigint,
  'API deletes of a posted entry match zero rows'
);
select tap.logout();
select throws_like(
  $$ update public.journal_entries set memo = 'tampered' where id = tap.v('e1') $$,
  '%immutable%',
  'even owner-context updates to a posted entry are rejected by trigger'
);
select throws_like(
  $$ delete from public.journal_entries where id = tap.v('e1') $$,
  '%cannot be deleted%',
  'even owner-context deletes of a posted entry are rejected by trigger'
);
select throws_like(
  $$ update public.journal_lines set debit = 9999 where entry_id = tap.v('e1') and line_no = 1 $$,
  '%immutable%',
  'even owner-context line edits on a posted entry are rejected by trigger'
);

-- Closed periods reject posting — by trigger, not UI
select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.close_period(app.ensure_period(tap.v('a1'), date '2026-07-15'));
select tap.login('22222222-2222-4222-8222-222222222202');
with e as (
  insert into public.journal_entries (client_id, entry_date, memo)
  values (tap.v('a1'), date '2026-07-20', 'Late entry') returning id
) insert into tap.ctx select 'e2', id from e;
insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
values (tap.v('e2'), tap.v('a1'), 1, tap.v('acc_cash'), 100.00, 0),
       (tap.v('e2'), tap.v('a1'), 2, tap.v('acc_sales'), 0, 100.00);
select throws_like(
  $$ select public.post_entry(tap.v('e2')) $$,
  '%only allowed into an open period%',
  'posting into a closed period is rejected by trigger'
);

-- Reversal: the only correction path, posted through the same gate
select tap.login('22222222-2222-4222-8222-222222222202');
select lives_ok(
  $$ select public.reverse_entry(tap.v('e1'), date '2026-08-05') $$,
  'a posted entry reverses into an open period'
);
select throws_like(
  $$ select public.reverse_entry(tap.v('e1')) $$,
  '%already reversed%',
  'an entry cannot be reversed twice'
);
select ok(
  (select sum(total_debit) = sum(total_credit)
     and sum(total_debit) = 1000.00
   from public.trial_balance(tap.v('a1'), date '2026-01-01', date '2026-12-31')),
  'the trial balance balances and the reversal mirrors the original'
);

-- Structural tenancy: a line can NEVER reference another client's account
select tap.logout();
select throws_ok(
  $$ insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit)
     values (tap.v('e2'), tap.v('a1'), 3, tap.v('acc_b_cash'), 10.00, 0) $$,
  '23503', null,
  'cross-client account references are unrepresentable (composite FK)'
);

-- Read/write boundaries
select tap.login('22222222-2222-4222-8222-222222222204');
select ok(
  (select count(*) from public.journal_entries where client_id = tap.v('a1')) >= 2,
  'the client viewer reads the journal'
);
select throws_ok(
  $$ insert into public.journal_entries (client_id, entry_date, memo)
     values (tap.v('a1'), current_date, 'Viewer entry') $$,
  '42501', null,
  'the client viewer cannot draft entries'
);
select tap.login('22222222-2222-4222-8222-222222222205');
select is_empty(
  $$ select * from public.journal_entries where client_id = tap.v('a1') $$,
  'firm B sees none of firm A''s journal'
);
select tap.logout();

select * from finish();
rollback;
