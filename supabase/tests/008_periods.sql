-- Phase 2: periods — lazy creation, status transitions, the one-way lock, and
-- the frozen client profile (ADR-0001 Phase 2 obligation).
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(13);

\ir 000_fixture.sql.inc

-- Lazy creation (owner context — posting calls this internally)
insert into tap.ctx values ('p_aug', app.ensure_period(tap.v('a1'), date '2026-08-15'));
select is(
  (select status from public.periods where id = tap.v('p_aug')),
  'open',
  'ensure_period creates the month as open'
);
select is(
  app.ensure_period(tap.v('a1'), date '2026-08-31'),
  tap.v('p_aug'),
  'the same month resolves to the same period'
);

-- close: admin or reviewer, never staff
select tap.login('22222222-2222-4222-8222-222222222202');
select throws_like(
  $$ select public.close_period(tap.v('p_aug')) $$,
  '%not authorized%',
  'staff cannot close a period'
);
select tap.login('22222222-2222-4222-8222-222222222201');
select lives_ok(
  $$ select public.close_period(tap.v('p_aug')) $$,
  'admin closes the period'
);
select throws_like(
  $$ select public.close_period(tap.v('p_aug')) $$,
  '%only an open period%',
  'closing twice is rejected'
);

-- reopen: admin/reviewer, and never after lock
select tap.login('22222222-2222-4222-8222-222222222202');
select throws_like(
  $$ select public.reopen_period(tap.v('p_aug')) $$,
  '%not authorized%',
  'staff cannot reopen a period'
);
select tap.login('22222222-2222-4222-8222-222222222201');
select lives_ok(
  $$ select public.reopen_period(tap.v('p_aug')) $$,
  'admin reopens a closed period'
);
select lives_ok(
  $$ select public.close_period(tap.v('p_aug')) $$,
  'admin closes it again ahead of locking'
);
select lives_ok(
  $$ select public.lock_period(tap.v('p_aug')) $$,
  'admin locks the closed period'
);
select throws_like(
  $$ select public.reopen_period(tap.v('p_aug')) $$,
  '%locked period cannot be reopened%',
  'a locked period never reopens (non-negotiable #3)'
);
select tap.logout();
insert into tap.ctx values ('p_sep', app.ensure_period(tap.v('a1'), date '2026-09-01'));
select tap.login('22222222-2222-4222-8222-222222222201');
select throws_like(
  $$ select public.lock_period(tap.v('p_sep')) $$,
  '%close the period before locking%',
  'an open period cannot be locked directly'
);

-- Frozen client profile once periods exist
select throws_like(
  $$ update public.clients set fiscal_year_end_month = 6 where id = tap.v('a1') $$,
  '%frozen once accounting periods exist%',
  'fiscal year end is frozen once the client has periods'
);

-- Viewers can see period status for their client
select tap.login('22222222-2222-4222-8222-222222222204');
select ok(
  (select count(*) from public.periods where client_id = tap.v('a1')) >= 2,
  'the client viewer sees the client''s periods'
);
select tap.logout();

select * from finish();
rollback;
