-- Phase 3 regression — percentage tax vs the 8% income-tax option (P3-09).
-- An 8%-option client owes no percentage tax: no 2551Q deadline is seeded and
-- the working paper shows a 0% rate. A graduated non-VAT client still gets 2551Q.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(3);

\ir 000_fixture.sql.inc

-- a1: non-VAT individual on the 8% option; a2: non-VAT individual, graduated.
insert into public.client_tax_profiles (client_id, regime, taxpayer_kind, income_tax_option)
values (tap.v('a1'), 'non_vat', 'individual', 'eight_percent');
insert into public.client_tax_profiles (client_id, regime, taxpayer_kind, income_tax_option)
values (tap.v('a2'), 'non_vat', 'individual', 'graduated');

select tap.login('22222222-2222-4222-8222-222222222201');
select public.seed_client_compliance(tap.v('a1'));
select public.seed_client_compliance(tap.v('a2'));

-- P3-09
select ok(
  not exists (select 1 from public.compliance_rules
              where client_id = tap.v('a1') and form = '2551Q'),
  'P3-09: an 8%-option client gets NO 2551Q percentage-tax deadline'
);
select ok(
  exists (select 1 from public.compliance_rules
          where client_id = tap.v('a2') and form = '2551Q'),
  'P3-09: a graduated non-VAT client still gets the 2551Q deadline'
);
select is(
  (select amount from public.wp_percentage_tax(tap.v('a1'), date '2026-01-01', date '2026-03-31')
   where line_no = 2),
  0::numeric(18,2),
  'P3-09: the 8%-option working paper shows a 0% percentage-tax rate (in lieu)'
);
select tap.logout();

select * from finish();
rollback;
