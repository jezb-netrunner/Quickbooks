-- NOT A TEST FILE (the runner picks up *.sql only). Tests 002-006 pull this in
-- with psql's \ir meta-command, which resolves relative to the including file —
-- keep this file in the same directory as the tests. Everything here is created
-- inside each test's transaction and vanishes on rollback.
--
-- Personas                                      key           uuid suffix
--   admin_a     firm_admin of Firm A            m_admin_a     ...01
--   staff_a     staff, assigned to A1 only      m_staff_a     ...02
--   staff_un    staff, no assignments           m_staff_un    ...03
--   viewer_a    client_viewer bound to A1       m_viewer_a    ...04
--   admin_b     firm_admin of Firm B            m_admin_b     ...05
--   unverified  signed up, email not confirmed                ...06
--   extra       verified, no memberships                      ...07
-- Data: Firm A (clients a1, a2), Firm B (client b1).

create schema tap;
grant usage on schema tap to authenticated, anon;

create table tap.ctx (k text primary key, v uuid);
grant select on tap.ctx to authenticated, anon;

create function tap.v(p_k text) returns uuid
language sql stable as $$ select v from tap.ctx where k = p_k $$;

create function tap.mkuser(p_id uuid, p_email text, p_confirmed boolean default true) returns void
language plpgsql as $$
begin
  insert into auth.users (
    instance_id, id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change, email_change_token_new, email_change_token_current
  ) values (
    '00000000-0000-0000-0000-000000000000', p_id, 'authenticated', 'authenticated',
    p_email, case when p_confirmed then now() end,
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', '', ''
  );
end $$;

create function tap.login(p_id uuid) returns void
language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_id, 'role', 'authenticated')::text, true);
end $$;

create function tap.login_anon() returns void
language plpgsql as $$
begin
  execute 'set local role anon';
  perform set_config('request.jwt.claims', '', true);
end $$;

create function tap.logout() returns void
language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

select tap.mkuser('22222222-2222-4222-8222-222222222201', 'admin_a@tap.test');
select tap.mkuser('22222222-2222-4222-8222-222222222202', 'staff_a@tap.test');
select tap.mkuser('22222222-2222-4222-8222-222222222203', 'staff_un@tap.test');
select tap.mkuser('22222222-2222-4222-8222-222222222204', 'viewer_a@tap.test');
select tap.mkuser('22222222-2222-4222-8222-222222222205', 'admin_b@tap.test');
select tap.mkuser('22222222-2222-4222-8222-222222222206', 'unverified@tap.test', false);
select tap.mkuser('22222222-2222-4222-8222-222222222207', 'extra@tap.test');

-- Build tenancy as postgres with per-persona JWT claims: RPCs exercise their
-- real authorization paths (auth.uid() from claims); direct client inserts skip
-- RLS (owner) but every constraint and trigger still fires.
select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222201', 'role', 'authenticated')::text, true);
insert into tap.ctx values ('firm_a', public.create_firm('Firm A'));
with c as (
  insert into public.clients (firm_id, name) values (tap.v('firm_a'), 'Client A1') returning id
) insert into tap.ctx select 'a1', id from c;
with c as (
  insert into public.clients (firm_id, name) values (tap.v('firm_a'), 'Client A2') returning id
) insert into tap.ctx select 'a2', id from c;
insert into tap.ctx values ('m_staff_a', public.add_member(tap.v('firm_a'), 'staff_a@tap.test', 'staff'));
select public.set_client_assignments(tap.v('m_staff_a'), array[tap.v('a1')]);
insert into tap.ctx values ('m_staff_un', public.add_member(tap.v('firm_a'), 'staff_un@tap.test', 'staff'));
insert into tap.ctx values ('m_viewer_a', public.add_member(tap.v('firm_a'), 'viewer_a@tap.test', 'client_viewer', tap.v('a1')));
insert into tap.ctx
  select 'm_admin_a', id from public.memberships
  where firm_id = tap.v('firm_a') and user_id = '22222222-2222-4222-8222-222222222201';

select set_config('request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222205', 'role', 'authenticated')::text, true);
insert into tap.ctx values ('firm_b', public.create_firm('Firm B'));
with c as (
  insert into public.clients (firm_id, name) values (tap.v('firm_b'), 'Client B1') returning id
) insert into tap.ctx select 'b1', id from c;
insert into tap.ctx
  select 'm_admin_b', id from public.memberships
  where firm_id = tap.v('firm_b') and user_id = '22222222-2222-4222-8222-222222222205';

select set_config('request.jwt.claims', '', true);
