-- Transition attacks — the bugs that live BETWEEN states: role demotion with
-- stale assignments, instant revocation, forged attribution, and the audit
-- trail that must record all of it.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(10);

\ir 000_fixture.sql.inc

-- Demote assigned staff to viewer: assignments are cleaned up AND the
-- role-gated helpers would ignore them regardless.
select tap.login('22222222-2222-4222-8222-222222222201');
select lives_ok(
  $$ select public.update_member(tap.v('m_staff_a'), 'client_viewer', false, tap.v('a1')) $$,
  'admin demotes assigned staff_a to client_viewer bound to A1'
);
select tap.login('22222222-2222-4222-8222-222222222202');
select set_eq(
  $$ select id from public.clients $$,
  $$ select tap.v('a1') $$,
  'demoted user sees exactly the bound client'
);
select is_empty(
  $$ select * from public.clients where id = tap.v('a2') $$,
  'the previously assigned A2 is gone — no stale-assignment leak'
);
select tap.logout();
select is_empty(
  $$ select * from public.client_assignments where membership_id = tap.v('m_staff_a') $$,
  'assignment rows were deleted on demotion'
);

-- Second wall: even an owner-context path that forgets the cleanup is rejected.
-- (postgres role with admin claims: the RPC authorizes; the later direct UPDATE
-- simulates a buggy owner-context code path.)
select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.set_client_assignments(tap.v('m_staff_un'), array[tap.v('a2')]);
select throws_like(
  $$ update public.memberships set role = 'client_viewer', client_id = tap.v('a2'), has_all_clients = false
     where id = tap.v('m_staff_un') $$,
  '%remove client assignments%',
  'the constraint trigger blocks role changes that skip assignment cleanup'
);

-- Revocation is instant
select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.remove_member(tap.v('m_staff_a'));
select tap.login('22222222-2222-4222-8222-222222222202');
select is_empty(
  $$ select * from public.clients $$,
  'a removed member sees nothing, immediately'
);

-- Attribution cannot be forged
select tap.login('22222222-2222-4222-8222-222222222201');
select throws_ok(
  $$ insert into public.clients (firm_id, name, created_by)
     values (tap.v('firm_a'), 'Spoofed Co', '22222222-2222-4222-8222-222222222205') $$,
  '42501', null,
  'created_by is not in the INSERT column grant — spoofing dies at the wall'
);
insert into public.clients (firm_id, name) values (tap.v('firm_a'), 'Honest Co');
select tap.logout();
select is(
  (select created_by from public.clients where name = 'Honest Co'),
  '22222222-2222-4222-8222-222222222201'::uuid,
  'created_by is forced to the calling user'
);

-- The audit trail recorded the administrative history
select ok(
  (select count(*) from public.audit_log
   where firm_id = tap.v('firm_a') and table_name = 'memberships' and action = 'delete') >= 1,
  'the membership removal is in the audit log'
);
select ok(
  (select count(*) from public.audit_log where firm_id = tap.v('firm_a')) >= 8,
  'admin mutations write audit rows'
);

select * from finish();
rollback;
