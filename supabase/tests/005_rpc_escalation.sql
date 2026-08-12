-- Bootstrap atomicity and every escalation path: forged tenant ids, direct DML,
-- unverified accounts, last-admin protection.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(16);

\ir 000_fixture.sql.inc

-- Bootstrap: fresh verified user creates a firm and becomes its admin atomically
select tap.login('22222222-2222-4222-8222-222222222207');
select lives_ok(
  $$ select public.create_firm('Extra & Co') $$,
  'a fresh verified user can create a firm'
);
select is(
  (select count(*) from public.memberships
   where user_id = '22222222-2222-4222-8222-222222222207' and role = 'firm_admin'),
  1::bigint,
  'creator is the firm admin, atomically'
);
select throws_like(
  $$ select public.create_firm('Second Co') $$,
  '%already created a firm%',
  'one firm per creator'
);
select tap.login('22222222-2222-4222-8222-222222222206');
select throws_like(
  $$ select public.create_firm('Ghost Co') $$,
  '%verify your email%',
  'unverified accounts cannot create firms'
);

-- Admins can insert a client AND read it back in the same statement — the
-- browser's insert().select() path. Regression: a select policy that looks the
-- checked row up in clients cannot see a row its own statement is inserting
-- (statement snapshot), which broke RETURNING for legitimate admins.
select tap.login('22222222-2222-4222-8222-222222222201');
select lives_ok(
  $$ insert into public.clients (firm_id, name)
     values (tap.v('firm_a'), 'Returning Co') returning id, name $$,
  'insert with RETURNING succeeds for a firm admin'
);

-- Direct DML dies at the grant wall
select throws_ok(
  $$ insert into public.firms (name, created_by)
     values ('Forged', '22222222-2222-4222-8222-222222222201') $$,
  '42501', null,
  'no direct insert into firms — create_firm only'
);
select throws_ok(
  $$ insert into public.memberships (firm_id, user_id, role)
     values (tap.v('firm_a'), '22222222-2222-4222-8222-222222222207', 'firm_admin') $$,
  '42501', null,
  'no direct insert into memberships — RPCs only'
);
select throws_ok(
  $$ update public.memberships set role = 'firm_admin' where id = tap.v('m_staff_a') $$,
  '42501', null,
  'no direct role updates — RPCs only'
);
select throws_ok(
  $$ insert into public.client_assignments (membership_id, firm_id, client_id)
     values (tap.v('m_staff_a'), tap.v('firm_a'), tap.v('a2')) $$,
  '42501', null,
  'no direct insert into client_assignments — RPCs only'
);
select throws_ok(
  $$ insert into public.clients (firm_id, name) values (tap.v('firm_b'), 'Forged Client') $$,
  '42501', null,
  'a forged firm_id on client insert fails WITH CHECK'
);

-- Non-admins cannot reach membership management; admin-ship never crosses firms
select tap.login('22222222-2222-4222-8222-222222222202');
select throws_like(
  $$ select public.add_member(tap.v('firm_a'), 'extra@tap.test', 'staff') $$,
  '%not authorized%',
  'staff cannot add members'
);
select tap.login('22222222-2222-4222-8222-222222222201');
select throws_like(
  $$ select public.remove_member(tap.v('m_admin_b')) $$,
  '%not authorized%',
  'firm A''s admin cannot touch firm B''s memberships'
);
select throws_like(
  $$ select public.add_member(tap.v('firm_a'), 'unverified@tap.test', 'staff') $$,
  '%not verified its email%',
  'unverified accounts cannot be granted access to books'
);

-- Last-admin protection
select throws_like(
  $$ select public.remove_member(tap.v('m_admin_a')) $$,
  '%last admin%',
  'the last admin cannot be removed'
);
select lives_ok(
  $$ do $handover$ begin
       perform public.add_member(tap.v('firm_a'), 'extra@tap.test', 'firm_admin');
       perform public.remove_member(tap.v('m_admin_a'));
     end $handover$ $$,
  'with a second admin in place, the first can leave'
);
select is_empty(
  $$ select * from public.firms where id = tap.v('firm_a') $$,
  'removal takes effect instantly — the removed admin sees nothing'
);
select tap.logout();

select * from finish();
rollback;
