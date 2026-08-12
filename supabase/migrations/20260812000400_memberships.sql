-- memberships and client_assignments — who can touch which books, and how hard.
--
-- Semantics (approved blueprint §2):
--   firm_admin    all firm clients, manages members
--   reviewer      assigned clients (or has_all_clients); staff semantics until Phase 7
--   staff         assigned clients (or has_all_clients); ZERO assignments = ZERO clients
--   client_viewer read-only, bound to exactly one client via memberships.client_id
--
-- All mutations go through the SECURITY DEFINER RPCs in 20260812000700_rpcs.sql —
-- there are no DML grants on either table. The constraint triggers below are the
-- second, independent wall: they hold even against a future definer-context bug
-- and against cascade deletes from auth.users.

create table if not exists public.memberships (
  id               uuid primary key default gen_random_uuid(),
  firm_id          uuid not null references public.firms(id),
  -- References profiles (not auth.users directly) so PostgREST can embed
  -- member names/emails; profiles cascades from auth.users, so deleting an auth
  -- user still cascades through to memberships.
  user_id          uuid not null references public.profiles(user_id) on delete cascade,
  role             text not null
                     check (role in ('firm_admin', 'reviewer', 'staff', 'client_viewer')),
  -- Explicit whole-firm grant for staff/reviewer. Never an implicit default:
  -- a new staff member sees nothing until scoped.
  has_all_clients  boolean not null default false,
  -- The client_viewer binding; null for every other role.
  client_id        uuid,
  created_by       uuid references auth.users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  unique (firm_id, user_id),
  unique (id, firm_id),  -- composite-FK anchor for client_assignments
  -- A viewer's bound client is provably in the SAME firm — structurally.
  foreign key (firm_id, client_id) references public.clients (firm_id, id),
  constraint viewer_binds_exactly_one check ((role = 'client_viewer') = (client_id is not null)),
  constraint viewer_never_all_clients check (role <> 'client_viewer' or has_all_clients = false)
);

create index if not exists memberships_user_idx on public.memberships (user_id);  -- the RLS hot path
create index if not exists memberships_firm_idx on public.memberships (firm_id);

drop trigger if exists trg_memberships_updated_at on public.memberships;
create trigger trg_memberships_updated_at
  before update on public.memberships
  for each row execute function app.set_updated_at();

drop trigger if exists trg_memberships_created_by on public.memberships;
create trigger trg_memberships_created_by
  before insert on public.memberships
  for each row execute function app.force_created_by();

create table if not exists public.client_assignments (
  membership_id  uuid not null,
  firm_id        uuid not null,
  client_id      uuid not null,
  created_by     uuid references auth.users(id),
  created_at     timestamptz not null default now(),

  primary key (membership_id, client_id),
  foreign key (membership_id, firm_id) references public.memberships (id, firm_id) on delete cascade,
  foreign key (firm_id, client_id)     references public.clients (firm_id, id)
  -- The two composite FKs jointly prove membership.firm = assignment.firm = client.firm.
);

create index if not exists client_assignments_client_idx on public.client_assignments (client_id);

drop trigger if exists trg_client_assignments_created_by on public.client_assignments;
create trigger trg_client_assignments_created_by
  before insert on public.client_assignments
  for each row execute function app.force_created_by();

-- ---------------------------------------------------------------------------
-- Invariant wall 1: assignment rows exist only for staff/reviewer memberships.
-- (Viewers bind via client_id; admins are implicitly all-clients — no stale rows
-- to forget.) Fires on assignment INSERT and, crucially, on membership role
-- UPDATE — the transition where the demotion leak would otherwise live.
-- ---------------------------------------------------------------------------
create or replace function app.assert_assignment_role() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_role text;
begin
  select m.role into v_role from public.memberships m where m.id = new.membership_id;
  if v_role is null or v_role not in ('staff', 'reviewer') then
    raise exception 'client assignments apply to staff and reviewer memberships only (got %)', coalesce(v_role, 'missing');
  end if;
  return new;
end $$;

drop trigger if exists trg_client_assignments_role on public.client_assignments;
create trigger trg_client_assignments_role
  before insert on public.client_assignments
  for each row execute function app.assert_assignment_role();

create or replace function app.assert_role_transition() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.role not in ('staff', 'reviewer')
     and exists (select 1 from public.client_assignments ca where ca.membership_id = new.id) then
    raise exception 'remove client assignments before changing this membership to %', new.role;
  end if;
  return new;
end $$;

drop trigger if exists trg_memberships_role_transition on public.memberships;
create trigger trg_memberships_role_transition
  before update of role on public.memberships
  for each row execute function app.assert_role_transition();

-- ---------------------------------------------------------------------------
-- Invariant wall 2: a firm can never lose its last admin — not by UPDATE, not by
-- DELETE, not by the auth.users cascade. The RPCs check this too (for a friendly
-- error under an advisory lock); this trigger is the enforcement of last resort.
-- ---------------------------------------------------------------------------
create or replace function app.assert_admin_remains() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.role = 'firm_admin'
     and (tg_op = 'DELETE' or new.role <> 'firm_admin')
     and not exists (
       select 1 from public.memberships m
       where m.firm_id = old.firm_id and m.role = 'firm_admin' and m.id <> old.id
     ) then
    raise exception 'a firm must always retain at least one admin';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_memberships_admin_remains on public.memberships;
create trigger trg_memberships_admin_remains
  before update of role or delete on public.memberships
  for each row execute function app.assert_admin_remains();
