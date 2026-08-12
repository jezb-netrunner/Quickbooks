-- client_viewer: read-only, exactly one client, sees no one's profile but their
-- own (approved decision 4 — viewers can be competing businesses).
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(12);

\ir 000_fixture.sql.inc

select tap.login('22222222-2222-4222-8222-222222222204');
select set_eq(
  $$ select id from public.clients $$,
  $$ select tap.v('a1') $$,
  'viewer sees exactly the bound client A1'
);
select set_eq(
  $$ select id from public.firms $$,
  $$ select tap.v('firm_a') $$,
  'viewer sees the firm row'
);
select ok(
  not (select app.can_write_client(tap.v('a1'))),
  'viewer can never write, even the bound client'
);

-- Writes: UPDATE passes the column grant but RLS matches zero rows (silent
-- no-op — prove nothing changed); INSERT fails the WITH CHECK outright.
update public.clients set name = 'hijacked' where id = tap.v('a1');
select tap.logout();
select is(
  (select name from public.clients where id = tap.v('a1')),
  'Client A1',
  'viewer update was a zero-row no-op'
);
select tap.login('22222222-2222-4222-8222-222222222204');
select throws_ok(
  $$ insert into public.clients (firm_id, name) values (tap.v('firm_a'), 'Sneaky Co') $$,
  '42501', null,
  'viewer insert fails row-level security'
);
select throws_like(
  $$ select public.add_member(tap.v('firm_a'), 'extra@tap.test', 'staff') $$,
  '%not authorized%',
  'viewer cannot add members'
);
select throws_like(
  $$ select public.update_member(tap.v('m_viewer_a'), 'firm_admin', false) $$,
  '%not authorized%',
  'viewer cannot change their own role'
);

-- Profile privacy
select set_eq(
  $$ select user_id from public.profiles $$,
  $$ values ('22222222-2222-4222-8222-222222222204'::uuid) $$,
  'viewer sees ONLY their own profile — no staff names, no other viewers'
);
select is_empty(
  $$ select * from public.audit_log $$,
  'viewer sees no audit history'
);

-- Staff-side visibility is unchanged by the viewer restriction
select tap.login('22222222-2222-4222-8222-222222222202');
select is(
  (select count(*) from public.profiles),
  4::bigint,
  'staff_a sees all four firm A member profiles'
);

-- Binding invariants
select tap.login('22222222-2222-4222-8222-222222222201');
select throws_ok(
  $$ select public.add_member(tap.v('firm_a'), 'extra@tap.test', 'client_viewer') $$,
  '23514', null,
  'a viewer must bind to exactly one client (CHECK)'
);
select throws_ok(
  $$ select public.add_member(tap.v('firm_a'), 'extra@tap.test', 'client_viewer', tap.v('b1')) $$,
  '23503', null,
  'binding a viewer to another firm''s client violates the composite FK'
);
select tap.logout();

select * from finish();
rollback;
