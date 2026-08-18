-- T-01 regression — guided client setup. One atomic RPC configures a client
-- (COA + tax codes + taxpayer shape + compliance calendar), and an
-- unconfigured client cannot issue documents.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(23);

\ir 000_fixture.sql.inc

-- Mirror the live defect: a client with a chart of accounts but NO tax setup.
select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
select public.seed_client_coa(tap.v('a1'));
select set_config('request.jwt.claims', '', true);
insert into tap.ctx select 'acc_sales', id from public.accounts where client_id = tap.v('a1') and code = '4000';
grant insert on tap.ctx to authenticated;

select tap.login('22222222-2222-4222-8222-222222222201');
with c as (
  insert into public.contacts (client_id, name, contact_type)
  values (tap.v('a1'), 'Mango Grove Cafe', 'customer') returning id
) insert into tap.ctx select 'cust', id from c;
with d as (
  insert into public.documents (client_id, doc_type, doc_date, contact_id, memo)
  values (tap.v('a1'), 'invoice', date '2026-08-01', tap.v('cust'), 'Pre-setup invoice')
  returning id
) insert into tap.ctx select 'inv', id from d;
insert into public.document_lines (document_id, client_id, line_no, account_id, description, amount)
values (tap.v('inv'), tap.v('a1'), 1, tap.v('acc_sales'), 'Retainer', 5000.00);

-- T-01: the gate — no tax profile, no posting.
select throws_like(
  $$ select public.issue_document(tap.v('inv')) $$,
  '%run tax setup first%',
  'T-01: issuing a document for a client with no tax profile is rejected'
);

-- Validation: the option must fit the taxpayer kind, and enums are enforced.
select throws_like(
  $$ select public.setup_client(tap.v('a1'), 'vat', 'corporate', 'graduated') $$,
  '%RCIT%',
  'T-01: a corporate taxpayer cannot take the graduated option'
);
select throws_like(
  $$ select public.setup_client(tap.v('a1'), 'sometimes-vat', 'individual', 'graduated') $$,
  '%regime%',
  'T-01: an unknown regime is rejected'
);
select tap.logout();

-- Authorization: setup_client rides app.can_write_client — probe each persona.
select tap.login('22222222-2222-4222-8222-222222222205');
select throws_like(
  $$ select public.setup_client(tap.v('a1'), 'vat', 'individual', 'graduated') $$,
  '%not authorized%',
  'T-01: an outsider cannot run setup on another firm''s client'
);
select tap.logout();
select tap.login('22222222-2222-4222-8222-222222222204');
select throws_like(
  $$ select public.setup_client(tap.v('a1'), 'vat', 'individual', 'graduated') $$,
  '%not authorized%',
  'T-01: a client viewer cannot run setup'
);
select tap.logout();
select tap.login('22222222-2222-4222-8222-222222222203');
select throws_like(
  $$ select public.setup_client(tap.v('a1'), 'vat', 'individual', 'graduated') $$,
  '%not authorized%',
  'T-01: unassigned staff cannot run setup'
);
select tap.logout();

-- The wizard's call: one RPC, fully configured.
select tap.login('22222222-2222-4222-8222-222222222201');
select lives_ok(
  $$ select public.setup_client(tap.v('a1'), 'vat', 'individual', 'graduated') $$,
  'T-01: setup_client configures a VAT individual in one call'
);
select is(
  (select (p.regime, p.taxpayer_kind, p.income_tax_option)::text
   from public.client_tax_profiles p where p.client_id = tap.v('a1')),
  '(vat,individual,graduated)',
  'T-01: the profile stores regime, taxpayer kind, and income-tax option'
);
select is(
  (select count(*) from public.tax_codes where client_id = tap.v('a1') and kind in ('output_vat', 'input_vat')),
  4::bigint,
  'T-01: a VAT client gets the four VAT codes'
);
select ok(
  exists (select 1 from public.compliance_rules where client_id = tap.v('a1') and form = '2550Q')
  and not exists (select 1 from public.compliance_rules where client_id = tap.v('a1') and form = '2551Q')
  and exists (select 1 from public.compliance_rules where client_id = tap.v('a1') and form = '1701Q'),
  'T-01: a VAT individual gets 2550Q and 1701Q deadlines, and no 2551Q'
);

-- The gated invoice now issues, and setup can safely run again.
select lives_ok(
  $$ select public.issue_document(tap.v('inv')) $$,
  'T-01: after setup the same document issues'
);
select lives_ok(
  $$ select public.setup_client(tap.v('a1'), 'vat', 'individual', 'graduated') $$,
  'T-01: setup is idempotent — re-running keeps the configuration'
);

-- P3-09 interplay: an 8% individual comes out with no 2551Q and no VAT codes.
select lives_ok(
  $$ select public.setup_client(tap.v('a2'), 'non_vat', 'individual', 'eight_percent') $$,
  'T-01: setup_client configures an 8%-option non-VAT individual'
);
select ok(
  not exists (select 1 from public.tax_codes
              where client_id = tap.v('a2') and kind in ('output_vat', 'input_vat'))
  and not exists (select 1 from public.compliance_rules
                  where client_id = tap.v('a2') and form in ('2550Q', '2551Q')),
  'T-01: the 8% non-VAT client gets no VAT codes and no 2550Q/2551Q (P3-09)'
);

-- Reconciliation: a re-run with a CHANGED profile toggles the contradictory
-- rules and VAT codes (active only — filing history is never touched).
select lives_ok(
  $$ select public.setup_client(tap.v('a1'), 'non_vat', 'individual', 'eight_percent') $$,
  'T-01: re-running with a changed regime and option succeeds'
);
select ok(
  not exists (select 1 from public.tax_codes
              where client_id = tap.v('a1') and kind in ('output_vat', 'input_vat') and active)
  and not exists (select 1 from public.compliance_rules
                  where client_id = tap.v('a1') and form in ('2550Q', '2551Q') and active),
  'T-01: switching to non-VAT 8% deactivates the VAT codes, 2550Q, and any 2551Q'
);
select lives_ok(
  $$ select public.setup_client(tap.v('a1'), 'vat', 'individual', 'graduated') $$,
  'T-01: switching back to VAT succeeds'
);
select ok(
  (select count(*) from public.tax_codes
   where client_id = tap.v('a1') and kind in ('output_vat', 'input_vat') and active) = 4
  and exists (select 1 from public.compliance_rules
              where client_id = tap.v('a1') and form = '2550Q' and active),
  'T-01: switching back reactivates the four VAT codes and the 2550Q rule'
);
select lives_ok(
  $$ select public.setup_client(tap.v('a2'), 'non_vat', 'corporate', 'rcit') $$,
  'T-01: an individual client can be reshaped to corporate'
);
select ok(
  exists (select 1 from public.compliance_rules
          where client_id = tap.v('a2') and form = '1702Q' and active)
  and not exists (select 1 from public.compliance_rules
                  where client_id = tap.v('a2') and form in ('1701Q', '1701A') and active),
  'T-01: the corporate reshape activates 1702Q and deactivates the 1701 forms'
);
select tap.logout();

-- Assigned staff may run setup (same authority as the seeds they replace).
select tap.login('22222222-2222-4222-8222-222222222202');
select lives_ok(
  $$ select public.setup_client(tap.v('a1'), 'vat', 'individual', 'graduated') $$,
  'T-01: staff assigned to the client can run setup'
);
-- The taxpayer-shape invariant holds even for direct column updates that
-- bypass the RPC (PostgREST PATCH path): the table CHECK is the enforcement.
select throws_like(
  $$ update public.client_tax_profiles
     set income_tax_option = 'rcit' where client_id = tap.v('a1') $$,
  '%violates check constraint%',
  'T-01: storing individual+rcit directly is rejected by the table CHECK'
);
select tap.logout();

-- An archived client cannot be reconfigured.
update public.clients set archived_at = now() where id = tap.v('a2');
select tap.login('22222222-2222-4222-8222-222222222201');
select throws_like(
  $$ select public.setup_client(tap.v('a2'), 'non_vat', 'corporate', 'rcit') $$,
  '%not authorized%',
  'T-01: setup is refused for an archived client'
);
select tap.logout();

select * from finish();
rollback;
