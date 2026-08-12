-- Policy helpers — the single access question, answered once.
--
-- Why SECURITY DEFINER in a private schema: a memberships policy that selects
-- from memberships recurses (42P17). Helpers owned by postgres skip RLS on the
-- tables they read (RLS is ENABLEd, never FORCEd), so there is no policy
-- re-entry. They take no trusted input — each reads auth.uid() itself — and app
-- is not API-exposed, so none of these is ever a REST endpoint. On hosted
-- Supabase no BYPASSRLS role can be minted; this is the supported pattern.
--
-- Every access branch is ROLE-GATED so a role transition can never leave a
-- stale grant readable (e.g. staff demoted to client_viewer must not read
-- through leftover assignment rows — those rows are also deleted, but the
-- role gate is the property that survives future bugs).
--
-- Policies call these wrapped in (select ...) so the planner evaluates them
-- once per statement, not once per row.

create or replace function app.is_firm_member(p_firm_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships m
    where m.firm_id = p_firm_id and m.user_id = (select auth.uid())
  );
$$;

create or replace function app.is_firm_admin(p_firm_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships m
    where m.firm_id = p_firm_id
      and m.user_id = (select auth.uid())
      and m.role = 'firm_admin'
  );
$$;

-- Read strength.
create or replace function app.can_access_client(p_client_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.clients c
    join public.memberships m
      on m.firm_id = c.firm_id and m.user_id = (select auth.uid())
    where c.id = p_client_id
      and (
        m.role = 'firm_admin'
        or (m.role in ('staff', 'reviewer') and m.has_all_clients)
        or (m.role = 'client_viewer' and m.client_id = c.id)
        or (m.role in ('staff', 'reviewer') and exists (
              select 1 from public.client_assignments ca
              where ca.membership_id = m.id and ca.client_id = c.id))
      )
  );
$$;

-- Write strength: viewers never write; archived books never change.
create or replace function app.can_write_client(p_client_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.clients c
    join public.memberships m
      on m.firm_id = c.firm_id and m.user_id = (select auth.uid())
    where c.id = p_client_id
      and c.archived_at is null
      and m.role in ('firm_admin', 'reviewer', 'staff')
      and (
        m.role = 'firm_admin'
        or m.has_all_clients
        or exists (
             select 1 from public.client_assignments ca
             where ca.membership_id = m.id and ca.client_id = c.id)
      )
  );
$$;

-- Set form: SELECT policies on high-row tables (Phase 2+) use
--   using (client_id in (select app.accessible_client_ids()))
-- — one membership-graph evaluation per statement instead of per row.
create or replace function app.accessible_client_ids() returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select c.id
  from public.clients c
  join public.memberships m
    on m.firm_id = c.firm_id and m.user_id = (select auth.uid())
  where m.role = 'firm_admin'
     or (m.role in ('staff', 'reviewer') and m.has_all_clients)
     or (m.role = 'client_viewer' and m.client_id = c.id)
     or (m.role in ('staff', 'reviewer') and exists (
           select 1 from public.client_assignments ca
           where ca.membership_id = m.id and ca.client_id = c.id));
$$;

-- Role-aware co-member visibility for profiles: only STAFF-SIDE callers see
-- colleagues. Client viewers see nobody through this helper — two viewers in
-- the same firm can be competing businesses, and the staff roster's names and
-- emails are not theirs to read.
create or replace function app.shares_firm_with(p_user_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.memberships a
    join public.memberships b on b.firm_id = a.firm_id
    where a.user_id = (select auth.uid())
      and a.role in ('firm_admin', 'reviewer', 'staff')
      and b.user_id = p_user_id
  );
$$;

revoke all on function
  app.is_firm_member(uuid),
  app.is_firm_admin(uuid),
  app.can_access_client(uuid),
  app.can_write_client(uuid),
  app.accessible_client_ids(),
  app.shares_firm_with(uuid)
from public, anon, authenticated;

grant execute on function
  app.is_firm_member(uuid),
  app.is_firm_admin(uuid),
  app.can_access_client(uuid),
  app.can_write_client(uuid),
  app.accessible_client_ids(),
  app.shares_firm_with(uuid)
to authenticated;
