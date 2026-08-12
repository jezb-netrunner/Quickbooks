-- Phase 2, part 2: accounting periods per client.
--
-- Monthly periods with open | closed | locked status. Posting into anything
-- but an open period is rejected by a TRIGGER on the journal (next migration),
-- never by the UI. Periods are created lazily by posting (app.ensure_period)
-- and managed by RPCs; there is no direct DML path.

create table if not exists public.periods (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.clients(id),
  period_start  date not null check (period_start = date_trunc('month', period_start)::date),
  period_end    date not null,
  status        text not null default 'open' check (status in ('open', 'closed', 'locked')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (client_id, period_start),
  unique (id, client_id),
  check (period_end = (period_start + interval '1 month' - interval '1 day')::date)
);
create index if not exists periods_client_idx on public.periods (client_id);

drop trigger if exists trg_periods_updated_at on public.periods;
create trigger trg_periods_updated_at
  before update on public.periods
  for each row execute function app.set_updated_at();

alter table public.periods enable row level security;

drop policy if exists periods_select on public.periods;
create policy periods_select on public.periods
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

grant select on public.periods to authenticated;
-- Creation via app.ensure_period; status transitions via RPCs. No DML grants.

-- Called from posting (definer context). Creates the month's period if absent.
create or replace function app.ensure_period(p_client_id uuid, p_date date) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_start date := date_trunc('month', p_date)::date;
  v_id uuid;
begin
  select id into v_id from public.periods
   where client_id = p_client_id and period_start = v_start;
  if v_id is null then
    insert into public.periods (client_id, period_start, period_end)
    values (p_client_id, v_start, (v_start + interval '1 month' - interval '1 day')::date)
    on conflict (client_id, period_start) do nothing;
    select id into v_id from public.periods
     where client_id = p_client_id and period_start = v_start;
  end if;
  return v_id;
end $$;
-- app schema: not API-exposed; no EXECUTE grants needed beyond definer use.

-- Status transitions. close/reopen: admin or reviewer; lock: admin only, and
-- lock is one-way (a locked period never reopens — non-negotiable #3).
create or replace function app.period_role_for_change(p_client_id uuid) returns text
language sql stable security definer
set search_path = ''
as $$
  select m.role
  from public.clients c
  join public.memberships m on m.firm_id = c.firm_id and m.user_id = (select auth.uid())
  where c.id = p_client_id
$$;

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
  if v_role not in ('firm_admin', 'reviewer') then raise exception 'not authorized'; end if;
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
  if v_role not in ('firm_admin', 'reviewer') then raise exception 'not authorized'; end if;
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
  if v_role <> 'firm_admin' then raise exception 'not authorized'; end if;
  if v_status <> 'closed' then raise exception 'close the period before locking it'; end if;
  update public.periods set status = 'locked' where id = p_period_id;
end $$;

revoke all on function
  public.close_period(uuid), public.reopen_period(uuid), public.lock_period(uuid)
from public, anon, authenticated;
grant execute on function
  public.close_period(uuid), public.reopen_period(uuid), public.lock_period(uuid)
to authenticated;

-- Phase 2 obligation from ADR-0001, now due: once a client has periods, its
-- fiscal year end and reporting basis are frozen (changing them would make
-- period history incoherent).
create or replace function app.assert_client_profile_mutable() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.fiscal_year_end_month is distinct from old.fiscal_year_end_month
      or new.reporting_basis is distinct from old.reporting_basis)
     and exists (select 1 from public.periods p where p.client_id = old.id) then
    raise exception 'fiscal year end and reporting basis are frozen once accounting periods exist';
  end if;
  return new;
end $$;

drop trigger if exists trg_clients_profile_frozen on public.clients;
create trigger trg_clients_profile_frozen
  before update of fiscal_year_end_month, reporting_basis on public.clients
  for each row execute function app.assert_client_profile_mutable();
