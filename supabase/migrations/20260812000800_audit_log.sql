-- Administrative audit log (approved decision 3): "who granted access to whose
-- books, and when" starts on day one and cannot be retrofitted.
--
-- Scope is deliberately narrow — the four administrative tables. The general
-- ledger is NEVER row-imaged: posted entries are immutable and self-auditing;
-- Phase 2+ audits state transitions (posted, reversed, period closed), keeping
-- this table at kilobytes instead of doubling the database.
--
-- Written only by a SECURITY DEFINER trigger (owner context bypasses RLS; the
-- table has no INSERT grant and no INSERT policy, so no API caller can write or
-- tamper). bigint identity: append-only, never in a URL.

create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  actor_id    uuid,                  -- auth.uid(); no FK so history survives user deletion
  firm_id     uuid not null,
  client_id   uuid,
  table_name  text not null,
  record_id   uuid not null,
  action      text not null check (action in ('insert', 'update', 'delete')),
  changes     jsonb                  -- {"old": {...}, "new": {...}} — small admin rows only
);

create index if not exists audit_log_firm_time_idx
  on public.audit_log (firm_id, occurred_at desc);

alter table public.audit_log enable row level security;

drop policy if exists audit_log_select on public.audit_log;
create policy audit_log_select on public.audit_log
  for select to authenticated
  using ((select app.is_firm_admin(firm_id)));

grant select on public.audit_log to authenticated;
-- No INSERT/UPDATE/DELETE grants or policies for any API role, ever.

create or replace function app.write_audit() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_new    jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_old    jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_row    jsonb := coalesce(v_new, v_old);
  v_firm   uuid;
  v_client uuid;
  v_record uuid;
begin
  v_firm := case
    when tg_table_name = 'firms' then (v_row ->> 'id')::uuid
    else (v_row ->> 'firm_id')::uuid
  end;
  v_client := case
    when tg_table_name = 'clients' then (v_row ->> 'id')::uuid
    else (v_row ->> 'client_id')::uuid
  end;
  -- client_assignments has a composite PK; its membership_id identifies the row.
  v_record := coalesce((v_row ->> 'id')::uuid, (v_row ->> 'membership_id')::uuid);

  insert into public.audit_log (actor_id, firm_id, client_id, table_name, record_id, action, changes)
  values (
    (select auth.uid()),
    v_firm,
    v_client,
    tg_table_name,
    v_record,
    lower(tg_op),
    jsonb_strip_nulls(jsonb_build_object('old', v_old, 'new', v_new))
  );
  return coalesce(new, old);
end $$;

drop trigger if exists trg_audit_firms on public.firms;
create trigger trg_audit_firms
  after insert or update or delete on public.firms
  for each row execute function app.write_audit();

drop trigger if exists trg_audit_clients on public.clients;
create trigger trg_audit_clients
  after insert or update or delete on public.clients
  for each row execute function app.write_audit();

drop trigger if exists trg_audit_memberships on public.memberships;
create trigger trg_audit_memberships
  after insert or update or delete on public.memberships
  for each row execute function app.write_audit();

drop trigger if exists trg_audit_client_assignments on public.client_assignments;
create trigger trg_audit_client_assignments
  after insert or update or delete on public.client_assignments
  for each row execute function app.write_audit();
