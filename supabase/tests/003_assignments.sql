-- Assignment semantics: default-closed. Staff with zero assignments see zero
-- clients; scope arrives only by explicit assignment or has_all_clients.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(13);

\ir 000_fixture.sql.inc

-- unassigned staff: firm visible, clients invisible
select tap.login('22222222-2222-4222-8222-222222222203');
select is_empty(
  $$ select * from public.clients $$,
  'unassigned staff sees ZERO clients (default-closed proven)'
);
select set_eq(
  $$ select id from public.firms $$,
  $$ select tap.v('firm_a') $$,
  'unassigned staff still sees their firm row'
);

-- assigned staff: exactly the assigned client
select tap.login('22222222-2222-4222-8222-222222222202');
select set_eq(
  $$ select id from public.clients $$,
  $$ select tap.v('a1') $$,
  'staff_a sees exactly assigned client A1'
);
select is_empty(
  $$ select * from public.clients where id = tap.v('a2') $$,
  'staff_a cannot see A2 even by id'
);
select ok(
  (select app.can_write_client(tap.v('a1'))),
  'staff_a can write the assigned client (Phase 2+ write template)'
);
select ok(
  not (select app.can_write_client(tap.v('a2'))),
  'staff_a cannot write an unassigned client'
);

-- admin widens the assignment set
select tap.login('22222222-2222-4222-8222-222222222201');
select lives_ok(
  $$ select public.set_client_assignments(tap.v('m_staff_a'), array[tap.v('a1'), tap.v('a2')]) $$,
  'admin replaces staff_a assignments with A1+A2'
);
select tap.login('22222222-2222-4222-8222-222222222202');
select is(
  (select count(*) from public.clients),
  2::bigint,
  'staff_a now sees both clients'
);

-- has_all_clients grants the whole firm, never another firm
select tap.login('22222222-2222-4222-8222-222222222201');
select lives_ok(
  $$ select public.update_member(tap.v('m_staff_un'), 'staff', true) $$,
  'admin grants staff_un has_all_clients'
);
select tap.login('22222222-2222-4222-8222-222222222203');
select is(
  (select count(*) from public.clients),
  2::bigint,
  'has_all_clients staff sees all firm A clients'
);
select is_empty(
  $$ select * from public.clients where id = tap.v('b1') $$,
  'has_all_clients grants nothing in firm B'
);

-- only admins manage assignments; assignments never attach to viewers
select tap.login('22222222-2222-4222-8222-222222222202');
select throws_like(
  $$ select public.set_client_assignments(tap.v('m_staff_un'), array[tap.v('a1')]) $$,
  '%not authorized%',
  'staff cannot manage assignments'
);
select tap.login('22222222-2222-4222-8222-222222222201');
select throws_like(
  $$ select public.set_client_assignments(tap.v('m_viewer_a'), array[tap.v('a1')]) $$,
  '%staff and reviewer roles only%',
  'assignments cannot attach to a client_viewer membership'
);
select tap.logout();

select * from finish();
rollback;
