-- Phase 2: chart of accounts — seeding, tenancy, immutability of classification.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(12);

\ir 000_fixture.sql.inc

-- Admin seeds the PH SME template into client A1
select tap.login('22222222-2222-4222-8222-222222222201');
select lives_ok(
  $$ select public.seed_client_coa(tap.v('a1')) $$,
  'admin seeds the client chart from the template'
);
select ok(
  (select count(*) from public.accounts where client_id = tap.v('a1')) > 40,
  'the template produced a full chart'
);
select ok(
  exists (select 1 from public.accounts where client_id = tap.v('a1') and parent_id is not null),
  'parent/child account links landed'
);
select is(
  (select public.seed_client_coa(tap.v('a1'))),
  0,
  're-seeding is a no-op (idempotent per code)'
);

-- Write access follows the Phase 1 access model
select tap.login('22222222-2222-4222-8222-222222222202');
select lives_ok(
  $$ insert into public.accounts (client_id, code, name, account_type, normal_balance)
     values (tap.v('a1'), '9999', 'Test account', 'expense', 'debit') $$,
  'assigned staff can add an account'
);
select throws_ok(
  $$ insert into public.accounts (client_id, code, name, account_type, normal_balance)
     values (tap.v('b1'), '9999', 'Forged', 'expense', 'debit') $$,
  '42501', null,
  'a forged client_id on account insert fails WITH CHECK'
);
select throws_ok(
  $$ insert into public.accounts (client_id, code, name, account_type, normal_balance)
     values (tap.v('a1'), '9999', 'Duplicate', 'expense', 'debit') $$,
  '23505', null,
  'account codes are unique per client'
);
select tap.login('22222222-2222-4222-8222-222222222203');
select throws_like(
  $$ select public.seed_client_coa(tap.v('a1')) $$,
  '%not authorized%',
  'unassigned staff cannot seed a chart'
);
select tap.login('22222222-2222-4222-8222-222222222204');
select throws_like(
  $$ select public.seed_client_coa(tap.v('a1')) $$,
  '%not authorized%',
  'a client viewer cannot seed a chart'
);
select ok(
  (select count(*) from public.coa_template) > 40,
  'the template reference data is readable'
);

-- Isolation and classification immutability
select tap.login('22222222-2222-4222-8222-222222222205');
select is_empty(
  $$ select * from public.accounts where client_id = tap.v('a1') $$,
  'firm B sees none of firm A''s accounts'
);
select tap.login('22222222-2222-4222-8222-222222222201');
select throws_ok(
  $$ update public.accounts set account_type = 'income'
     where client_id = tap.v('a1') and code = '9999' $$,
  '42501', null,
  'account_type is not updatable through the API (report classification is immutable)'
);
select tap.logout();

select * from finish();
rollback;
