-- Fix: INSERT ... RETURNING on clients failed for legitimate admins.
--
-- Postgres enforces SELECT policies on RETURNING rows as if they were WITH
-- CHECK expressions, and the old clients_select policy
--   using (id in (select app.accessible_client_ids()))
-- re-queried the clients table inside a STABLE helper — which runs on the
-- statement's snapshot and therefore cannot see the row the statement itself
-- is inserting. The insert passed; returning the new row was denied.
--
-- The clients table is the ONE place a policy must not look up the checked row
-- in clients: derive access from the row's own (firm_id, id) against the
-- membership graph only. Semantics are identical to the old policy — same
-- role-gated branches, proven by the pgTAP suite. accessible_client_ids()
-- remains the contract for every OTHER client-scoped table (their policies
-- read clients rows that already exist, so the snapshot issue never applies).

create or replace function app.can_read_firm_client(p_firm_id uuid, p_client_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships m
    where m.firm_id = p_firm_id
      and m.user_id = (select auth.uid())
      and (
        m.role = 'firm_admin'
        or (m.role in ('staff', 'reviewer') and m.has_all_clients)
        or (m.role = 'client_viewer' and m.client_id = p_client_id)
        or (m.role in ('staff', 'reviewer') and exists (
              select 1 from public.client_assignments ca
              where ca.membership_id = m.id and ca.client_id = p_client_id))
      )
  );
$$;

revoke all on function app.can_read_firm_client(uuid, uuid) from public, anon, authenticated;
grant execute on function app.can_read_firm_client(uuid, uuid) to authenticated;

drop policy if exists clients_select on public.clients;
create policy clients_select on public.clients
  for select to authenticated
  using ((select app.can_read_firm_client(firm_id, id)));
