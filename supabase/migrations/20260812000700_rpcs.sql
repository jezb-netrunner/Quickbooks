-- Membership management RPCs — with no server tier, SQL is the server.
--
-- All: SECURITY DEFINER, search_path pinned, EXECUTE granted to authenticated
-- only. None trusts a caller-supplied firm id for authorization — each derives
-- the firm from the row it acts on, then checks admin-ship of THAT firm. Every
-- firm-mutating RPC serializes on an advisory lock keyed by firm id, closing
-- the concurrent last-admin/assignment races (TOCTOU) the constraint triggers
-- alone cannot close with friendly errors.

-- Bootstrap: a new signed-up user becomes a firm's admin atomically. There is
-- never a window where a firm exists without an admin.
create or replace function public.create_firm(p_name text) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_firm uuid;
begin
  if v_uid is null then
    raise exception 'authentication required';
  end if;
  -- Verified email required on every membership-granting path (blueprint §5);
  -- and one firm per creator — a damper on free-tier abuse from open signup.
  if not exists (select 1 from auth.users u where u.id = v_uid and u.email_confirmed_at is not null) then
    raise exception 'verify your email before creating a firm';
  end if;
  if exists (select 1 from public.firms f where f.created_by = v_uid) then
    raise exception 'this account has already created a firm';
  end if;

  insert into public.firms (name, created_by)
  values (btrim(p_name), v_uid)
  returning id into v_firm;

  insert into public.memberships (firm_id, user_id, role, created_by)
  values (v_firm, v_uid, 'firm_admin', v_uid);

  return v_firm;
end $$;

-- Admin connects an existing, verified account by email. (Invitation flow for
-- not-yet-registered emails is a later, additive feature.)
create or replace function public.add_member(
  p_firm_id uuid,
  p_email text,
  p_role text,
  p_client_id uuid default null,
  p_has_all_clients boolean default false
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_target uuid;
  v_id     uuid;
begin
  if not (select app.is_firm_admin(p_firm_id)) then
    raise exception 'not authorized';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_firm_id::text, 0));

  select p.user_id into v_target
  from public.profiles p
  where lower(p.email) = lower(btrim(p_email));
  if v_target is null then
    raise exception 'no account found for this email — the person must sign up first';
  end if;
  -- Unverified accounts can be planted on someone else's address; never grant
  -- them access to books.
  if not exists (select 1 from auth.users u where u.id = v_target and u.email_confirmed_at is not null) then
    raise exception 'this account has not verified its email yet';
  end if;

  insert into public.memberships (firm_id, user_id, role, has_all_clients, client_id, created_by)
  values (p_firm_id, v_target, p_role, p_has_all_clients, p_client_id, v_uid)
  returning id into v_id;
  -- Table CHECKs validate the role string and viewer binding; the composite FK
  -- proves a viewer's client belongs to this firm.
  return v_id;
end $$;

create or replace function public.update_member(
  p_membership_id uuid,
  p_role text,
  p_has_all_clients boolean,
  p_client_id uuid default null
) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_firm     uuid;
  v_old_role text;
begin
  select m.firm_id, m.role into v_firm, v_old_role
  from public.memberships m where m.id = p_membership_id;
  if v_firm is null then
    raise exception 'membership not found';
  end if;
  if not (select app.is_firm_admin(v_firm)) then
    raise exception 'not authorized';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_firm::text, 0));

  if v_old_role = 'firm_admin' and p_role <> 'firm_admin'
     and (select count(*) from public.memberships m
          where m.firm_id = v_firm and m.role = 'firm_admin') <= 1 then
    raise exception 'cannot demote the last admin of a firm';
  end if;

  -- Role transitions out of staff/reviewer clean up assignment rows; the
  -- role-gated helpers make stale rows inert regardless, and the constraint
  -- trigger rejects any path that forgets this delete.
  if p_role not in ('staff', 'reviewer') then
    delete from public.client_assignments ca where ca.membership_id = p_membership_id;
  end if;

  update public.memberships
     set role            = p_role,
         has_all_clients = case when p_role = 'client_viewer' then false else p_has_all_clients end,
         client_id       = case when p_role = 'client_viewer' then p_client_id else null end
   where id = p_membership_id;
end $$;

create or replace function public.remove_member(p_membership_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_firm     uuid;
  v_old_role text;
begin
  select m.firm_id, m.role into v_firm, v_old_role
  from public.memberships m where m.id = p_membership_id;
  if v_firm is null then
    raise exception 'membership not found';
  end if;
  if not (select app.is_firm_admin(v_firm)) then
    raise exception 'not authorized';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_firm::text, 0));

  if v_old_role = 'firm_admin'
     and (select count(*) from public.memberships m
          where m.firm_id = v_firm and m.role = 'firm_admin') <= 1 then
    raise exception 'cannot remove the last admin of a firm';
  end if;

  -- Hard delete: the simplest state is the safest state. History lives in
  -- audit_log (approved decision 3); no revoked_at filter class can ever be
  -- forgotten because it never exists.
  delete from public.memberships m where m.id = p_membership_id;
end $$;

-- Replace-set semantics — idempotent from the UI's checkbox list.
create or replace function public.set_client_assignments(
  p_membership_id uuid,
  p_client_ids uuid[]
) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_firm uuid;
  v_role text;
begin
  select m.firm_id, m.role into v_firm, v_role
  from public.memberships m where m.id = p_membership_id;
  if v_firm is null then
    raise exception 'membership not found';
  end if;
  if not (select app.is_firm_admin(v_firm)) then
    raise exception 'not authorized';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_firm::text, 0));

  if v_role not in ('staff', 'reviewer') then
    raise exception 'client assignments apply to staff and reviewer roles only';
  end if;

  delete from public.client_assignments ca where ca.membership_id = p_membership_id;
  insert into public.client_assignments (membership_id, firm_id, client_id, created_by)
  select p_membership_id, v_firm, cid, v_uid
  from unnest(coalesce(p_client_ids, '{}'::uuid[])) as cid;
  -- The (firm_id, client_id) composite FK rejects any id from another firm.
end $$;

revoke all on function
  public.create_firm(text),
  public.add_member(uuid, text, text, uuid, boolean),
  public.update_member(uuid, text, boolean, uuid),
  public.remove_member(uuid),
  public.set_client_assignments(uuid, uuid[])
from public, anon, authenticated;

grant execute on function
  public.create_firm(text),
  public.add_member(uuid, text, text, uuid, boolean),
  public.update_member(uuid, text, boolean, uuid),
  public.remove_member(uuid),
  public.set_client_assignments(uuid, uuid[])
to authenticated;
