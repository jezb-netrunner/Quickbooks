-- Non-negotiable #1: no cross-client data leakage. Firm A must never see Firm B,
-- and anon must die at the grant wall before RLS is even consulted.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(13);

\ir 000_fixture.sql.inc

-- admin_a sees exactly Firm A
select tap.login('22222222-2222-4222-8222-222222222201');
select set_eq(
  $$ select id from public.firms $$,
  $$ select tap.v('firm_a') $$,
  'admin_a sees exactly firm A'
);
select is_empty(
  $$ select * from public.firms where id = tap.v('firm_b') $$,
  'naming firm B''s id leaks nothing'
);
select set_eq(
  $$ select id from public.clients $$,
  $$ select tap.v('a1') union select tap.v('a2') $$,
  'admin_a sees exactly clients A1 and A2'
);
select is_empty(
  $$ select * from public.clients where firm_id = tap.v('firm_b') $$,
  'filtering by firm B''s id leaks nothing'
);
select is_empty(
  $$ select * from public.memberships where firm_id <> tap.v('firm_a') $$,
  'admin_a sees no memberships outside firm A'
);

-- staff sees only their own membership row
select tap.login('22222222-2222-4222-8222-222222222202');
select set_eq(
  $$ select id from public.memberships $$,
  $$ select tap.v('m_staff_a') $$,
  'staff_a sees only their own membership row'
);

-- admin_b sees exactly Firm B
select tap.login('22222222-2222-4222-8222-222222222205');
select set_eq(
  $$ select id from public.clients $$,
  $$ select tap.v('b1') $$,
  'admin_b sees exactly client B1'
);

-- anon dies at the grant wall (42501), never reaching policy evaluation
select tap.login_anon();
select throws_ok($$ select * from public.firms $$,              '42501', null, 'anon cannot select firms');
select throws_ok($$ select * from public.clients $$,            '42501', null, 'anon cannot select clients');
select throws_ok($$ select * from public.memberships $$,        '42501', null, 'anon cannot select memberships');
select throws_ok($$ select * from public.client_assignments $$, '42501', null, 'anon cannot select client_assignments');
select throws_ok($$ select * from public.profiles $$,           '42501', null, 'anon cannot select profiles');
select throws_ok($$ select * from public.audit_log $$,          '42501', null, 'anon cannot select audit_log');
select tap.logout();

select * from finish();
rollback;
