-- RLS policies and minimal grants, table by table.
--
-- Two independent walls everywhere: table/column grants decide which VERBS a
-- role may attempt; RLS decides which ROWS. anon holds nothing anywhere.
-- Column-level grants double as immutability: an un-granted column cannot be
-- touched through any policy combination (clients.firm_id — a client can never
-- move between firms; functional_currency; every attribution column).
--
-- ENABLE, not FORCE: the definer helpers/RPCs are owner-context by design (§4
-- of the approved blueprint); no API request ever executes as the owner.

-- ---------------------------------------------------------------- firms
alter table public.firms enable row level security;

drop policy if exists firms_select on public.firms;
create policy firms_select on public.firms
  for select to authenticated
  using ((select app.is_firm_member(id)));

drop policy if exists firms_update on public.firms;
create policy firms_update on public.firms
  for update to authenticated
  using ((select app.is_firm_admin(id)))
  with check ((select app.is_firm_admin(id)));

grant select on public.firms to authenticated;
grant update (name) on public.firms to authenticated;
-- No INSERT (create_firm RPC only). No DELETE (not supported).

-- ---------------------------------------------------------------- clients
alter table public.clients enable row level security;

drop policy if exists clients_select on public.clients;
create policy clients_select on public.clients
  for select to authenticated
  using (id in (select app.accessible_client_ids()));

-- The caller sends firm_id, but WITH CHECK re-proves the caller is an admin OF
-- THAT firm server-side — the value is validated, never trusted.
drop policy if exists clients_insert on public.clients;
create policy clients_insert on public.clients
  for insert to authenticated
  with check ((select app.is_firm_admin(firm_id)));

drop policy if exists clients_update on public.clients;
create policy clients_update on public.clients
  for update to authenticated
  using ((select app.is_firm_admin(firm_id)))
  with check ((select app.is_firm_admin(firm_id)));

grant select on public.clients to authenticated;
grant insert (firm_id, name, code, tin, reporting_basis, fiscal_year_end_month)
  on public.clients to authenticated;
grant update (name, code, tin, reporting_basis, fiscal_year_end_month, archived_at)
  on public.clients to authenticated;
-- No DELETE: archive only.

-- ---------------------------------------------------------------- memberships
alter table public.memberships enable row level security;

drop policy if exists memberships_select on public.memberships;
create policy memberships_select on public.memberships
  for select to authenticated
  using (
    user_id = (select auth.uid())              -- everyone sees their own memberships
    or (select app.is_firm_admin(firm_id))     -- admins see the whole roster
  );

grant select on public.memberships to authenticated;
-- No INSERT/UPDATE/DELETE grants or policies: mutations via RPCs only.

-- ---------------------------------------------------------------- client_assignments
alter table public.client_assignments enable row level security;

drop policy if exists client_assignments_select on public.client_assignments;
create policy client_assignments_select on public.client_assignments
  for select to authenticated
  using (
    (select app.is_firm_admin(firm_id))
    -- Staff see their own assignments. This subquery runs as the caller, so the
    -- memberships own-row policy applies — no recursion, no helper needed.
    or exists (
      select 1 from public.memberships m
      where m.id = membership_id and m.user_id = (select auth.uid())
    )
  );

grant select on public.client_assignments to authenticated;
-- Mutations via set_client_assignments() RPC only.

-- ---------------------------------------------------------------- profiles
alter table public.profiles enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select app.shares_firm_with(user_id))  -- staff-side callers only (approved decision 4)
  );

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

grant select on public.profiles to authenticated;
grant update (full_name) on public.profiles to authenticated;
-- INSERT only via the auth.users sync trigger.
