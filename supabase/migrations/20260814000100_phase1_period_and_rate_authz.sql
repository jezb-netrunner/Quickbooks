-- Phase 1 remediation — tenant isolation on period + compliance-rate RPCs.
-- Fixes audit findings P4-01, P4-05 (period authorization) and P4-06
-- (percentage-tax rate leak). No schema change, no data conversion: this
-- migration only redefines four functions. CREATE OR REPLACE preserves the
-- existing EXECUTE grants and ownership established by the original migrations.

-- ---------------------------------------------------------------------------
-- P4-05 — Period RPCs authorized on FIRM-WIDE role, not client access.
--
-- The original helper returned m.role from a plain firm-membership join, so a
-- reviewer scoped to one client (or, in theory, an admin) got a role back for
-- EVERY client in the firm — including clients they aren't assigned to. Mirror
-- app.can_access_client's access predicate here so the role is returned only
-- when the caller actually has access to THIS client; a non-member or an
-- unassigned reviewer now resolves to NULL. This also underpins the P4-01 fix:
-- "no access" is a clean NULL that the NULL-safe guards below reject.
create or replace function app.period_role_for_change(p_client_id uuid) returns text
language sql stable security definer
set search_path = ''
as $$
  select m.role
  from public.clients c
  join public.memberships m on m.firm_id = c.firm_id and m.user_id = (select auth.uid())
  where c.id = p_client_id
    and (
      m.role = 'firm_admin'
      or (m.role in ('staff', 'reviewer') and m.has_all_clients)
      or (m.role = 'client_viewer' and m.client_id = c.id)
      or (m.role in ('staff', 'reviewer') and exists (
            select 1 from public.client_assignments ca
            where ca.membership_id = m.id and ca.client_id = c.id))
    )
$$;

-- ---------------------------------------------------------------------------
-- P4-01 — NULL role fails OPEN. `NULL not in (...)` and `NULL <> ...` both
-- evaluate to NULL, which a PL/pgSQL IF treats as false, so the "not
-- authorized" raise was SKIPPED for any caller with no membership in the
-- client's firm — letting a non-member (e.g. a removed staffer replaying a
-- remembered period UUID) irreversibly lock another tenant's period.
--
-- Fix: NULL-safe comparisons with IS DISTINCT FROM. Role policy is UNCHANGED —
-- close/reopen remain firm_admin OR reviewer; lock remains firm_admin only;
-- staff and client_viewer stay excluded — but NULL is now correctly rejected.
create or replace function public.close_period(p_period_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_client uuid; v_status text; v_role text;
begin
  select client_id, status into v_client, v_status from public.periods where id = p_period_id;
  if v_client is null then raise exception 'period not found'; end if;
  v_role := (select app.period_role_for_change(v_client));
  if v_role is distinct from 'firm_admin' and v_role is distinct from 'reviewer' then
    raise exception 'not authorized';
  end if;
  if v_status <> 'open' then raise exception 'only an open period can be closed'; end if;
  update public.periods set status = 'closed' where id = p_period_id;
end $$;

create or replace function public.reopen_period(p_period_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_client uuid; v_status text; v_role text;
begin
  select client_id, status into v_client, v_status from public.periods where id = p_period_id;
  if v_client is null then raise exception 'period not found'; end if;
  v_role := (select app.period_role_for_change(v_client));
  if v_role is distinct from 'firm_admin' and v_role is distinct from 'reviewer' then
    raise exception 'not authorized';
  end if;
  if v_status = 'locked' then raise exception 'a locked period cannot be reopened'; end if;
  if v_status <> 'closed' then raise exception 'only a closed period can be reopened'; end if;
  update public.periods set status = 'open' where id = p_period_id;
end $$;

create or replace function public.lock_period(p_period_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_client uuid; v_status text; v_role text;
begin
  select client_id, status into v_client, v_status from public.periods where id = p_period_id;
  if v_client is null then raise exception 'period not found'; end if;
  v_role := (select app.period_role_for_change(v_client));
  if v_role is distinct from 'firm_admin' then raise exception 'not authorized'; end if;
  if v_status <> 'closed' then raise exception 'close the period before locking it'; end if;
  update public.periods set status = 'locked' where id = p_period_id;
end $$;

-- ---------------------------------------------------------------------------
-- P4-06 — app.compliance_rate (SECURITY DEFINER) read compliance_settings with
-- no access check, so wp_percentage_tax leaked a foreign client's configured
-- percentage-tax rate to any authenticated caller who supplied that client's
-- UUID. Guard the shared helper at the root with the NULL-safe access boolean
-- used everywhere else; legitimate same-client use is unchanged.
create or replace function app.compliance_rate(p_client_id uuid, p_key text, p_on date) returns numeric
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v numeric;
begin
  if not (select app.can_access_client(p_client_id)) then
    raise exception 'not authorized';
  end if;
  select s.rate into v
  from public.compliance_settings s
  where s.client_id = p_client_id and s.key = p_key and s.effective_from <= p_on
  order by s.effective_from desc
  limit 1;
  if v is null then
    raise exception 'no % rate is configured as of % — run compliance setup or add one', p_key, p_on;
  end if;
  return v;
end $$;
