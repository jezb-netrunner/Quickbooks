-- Phase 1 regression suite — tenant isolation on period + compliance-rate RPCs.
-- Guards audit findings P4-01 (non-member fail-open on period RPCs), P4-05
-- (firm-wide vs client-scoped authorization), P4-06 (percentage-tax rate leak).
-- Personas come from the shared fixture: admin_a/staff_a(->a1)/viewer_a are
-- Firm A; admin_b is Firm A's neighbour (Firm B, NO membership in Firm A);
-- extra has NO memberships anywhere. Firm A owns clients a1, a2.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(12);

\ir 000_fixture.sql.inc

-- --- fixtures for this suite (owner context; RLS bypassed for setup only) ---
-- Periods: an open + a closed one for Firm A's client a1, and an open one for a2.
insert into tap.ctx values ('pa1_open',   app.ensure_period(tap.v('a1'), date '2026-05-15'));
insert into tap.ctx values ('pa1_closed', app.ensure_period(tap.v('a1'), date '2026-06-15'));
insert into tap.ctx values ('pa2_open',   app.ensure_period(tap.v('a2'), date '2026-05-15'));

-- Pre-close pa1_closed through the real RPC as the Firm A admin.
select tap.login('22222222-2222-4222-8222-222222222201');
select public.close_period(tap.v('pa1_closed'));
select tap.logout();

-- A reviewer scoped to a2 ONLY (never assigned a1) — the P4-05 probe.
select tap.mkuser('22222222-2222-4222-8222-222222222208', 'rev_a2@tap.test');
select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
insert into tap.ctx values ('m_rev_a2', public.add_member(tap.v('firm_a'), 'rev_a2@tap.test', 'reviewer'));
select public.set_client_assignments(tap.v('m_rev_a2'), array[tap.v('a2')]);
select set_config('request.jwt.claims', '', true);

-- A configured percentage-tax rate for a1 — the P4-06 probe reads this.
insert into public.compliance_settings (client_id, key, effective_from, rate)
values (tap.v('a1'), 'percentage_tax_rate', date '2026-01-01', 0.03);

-- ============================ P4-01 ========================================
-- A non-member of Firm A (admin of the neighbouring Firm B) must not be able to
-- touch Firm A's periods. Before the fix a NULL role failed open and every one
-- of these succeeded — lock being irreversible.
select tap.login('22222222-2222-4222-8222-222222222205');  -- admin_b
select throws_like(
  $$ select public.lock_period(tap.v('pa1_closed')) $$,
  '%not authorized%',
  'P4-01: a non-member cannot LOCK another firm''s period'
);
select throws_like(
  $$ select public.close_period(tap.v('pa1_open')) $$,
  '%not authorized%',
  'P4-01: a non-member cannot CLOSE another firm''s period'
);
select throws_like(
  $$ select public.reopen_period(tap.v('pa1_closed')) $$,
  '%not authorized%',
  'P4-01: a non-member cannot REOPEN another firm''s period'
);
select tap.logout();

-- The blocked attack left the period untouched (still closed, not locked).
select is(
  (select status from public.periods where id = tap.v('pa1_closed')),
  'closed',
  'P4-01: the period is unchanged after the blocked lock attempt'
);

-- The removed-staffer vector: an authenticated account with NO memberships at
-- all (replaying a remembered period UUID) is equally rejected.
select tap.login('22222222-2222-4222-8222-222222222207');  -- extra
select throws_like(
  $$ select public.lock_period(tap.v('pa1_closed')) $$,
  '%not authorized%',
  'P4-01: an account with no memberships cannot lock a period'
);
select tap.logout();

-- ============================ P4-05 ========================================
-- A reviewer scoped to a2 must NOT be able to act on a1 (firm-wide role was the
-- bug); but must still work normally on the client it IS assigned to.
select tap.login('22222222-2222-4222-8222-222222222208');  -- rev_a2
select throws_like(
  $$ select public.close_period(tap.v('pa1_open')) $$,
  '%not authorized%',
  'P4-05: a reviewer scoped to a2 cannot close a1''s period'
);
select lives_ok(
  $$ select public.close_period(tap.v('pa2_open')) $$,
  'P4-05: the same reviewer CAN close its own assigned client''s period'
);
select tap.logout();

-- ===================== close-permission policy preserved ===================
-- Staff stays excluded from closing (unchanged behaviour); the legitimate
-- admin path still closes and locks.
select tap.login('22222222-2222-4222-8222-222222222202');  -- staff_a (assigned a1)
select throws_like(
  $$ select public.close_period(tap.v('pa1_open')) $$,
  '%not authorized%',
  'policy preserved: assigned staff still cannot close a period'
);
select tap.logout();

select tap.login('22222222-2222-4222-8222-222222222201');  -- admin_a
select lives_ok(
  $$ select public.close_period(tap.v('pa1_open')) $$,
  'legit path: the firm admin closes an open period'
);
select lives_ok(
  $$ select public.lock_period(tap.v('pa1_closed')) $$,
  'legit path: the firm admin locks a closed period'
);
select tap.logout();

-- ============================ P4-06 ========================================
-- The percentage-tax working paper must not disclose a foreign client's
-- configured rate. Before the fix admin_b got Firm A's rate on line 2.
select tap.login('22222222-2222-4222-8222-222222222205');  -- admin_b
select throws_like(
  $$ select * from public.wp_percentage_tax(tap.v('a1'), date '2026-01-01', date '2026-03-31') $$,
  '%not authorized%',
  'P4-06: a non-member cannot read a foreign client''s percentage-tax rate'
);
select tap.logout();

-- Legitimate same-client use is unchanged: admin_a still sees the rate (3.00%).
select tap.login('22222222-2222-4222-8222-222222222201');  -- admin_a
select is(
  (select amount from public.wp_percentage_tax(tap.v('a1'), date '2026-01-01', date '2026-03-31')
   where line_no = 2),
  3.00::numeric(18,2),
  'P4-06: the owning firm still sees the configured 3.00% rate'
);
select tap.logout();

select * from finish();
rollback;
