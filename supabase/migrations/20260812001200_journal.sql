-- Phase 2, part 3: the double-entry journal engine.
--
-- Every source document in every later phase posts through THIS structure and
-- THIS posting path — no document type ever writes its own ledger logic.
--
-- Enforcement lives in the database, not the RPCs and never the UI:
--   * every line has exactly one of debit/credit non-zero, amounts >= 0 (CHECK)
--   * per-entry sum(debit) = sum(credit), checked by trigger at posting
--   * posted entries are immutable — corrections are reversing entries
--   * posting into a non-open period is rejected by trigger
--   * cross-client references are unrepresentable (composite FKs)

create table if not exists public.journal_entries (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references public.clients(id),
  entry_no     bigint,                 -- assigned at posting; drafts have none
  entry_date   date not null,
  period_id    uuid,                   -- set at posting from entry_date
  status       text not null default 'draft' check (status in ('draft', 'posted')),
  source_type  text not null default 'manual'
                 check (source_type in ('manual', 'opening_balance', 'reversal')),
  memo         text not null default '',
  reversal_of  uuid,                   -- set on the reversing entry
  reversed_by  uuid,                   -- set on the reversed entry (only mutation allowed after posting)
  created_by   uuid references auth.users(id),
  posted_by    uuid references auth.users(id),
  posted_at    timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (id, client_id),
  foreign key (period_id, client_id)    references public.periods (id, client_id),
  foreign key (reversal_of, client_id)  references public.journal_entries (id, client_id),
  foreign key (reversed_by, client_id)  references public.journal_entries (id, client_id)
);
create unique index if not exists journal_entries_client_no_uniq
  on public.journal_entries (client_id, entry_no) where entry_no is not null;
create index if not exists journal_entries_client_date_idx
  on public.journal_entries (client_id, entry_date);

drop trigger if exists trg_journal_entries_updated_at on public.journal_entries;
create trigger trg_journal_entries_updated_at
  before update on public.journal_entries
  for each row execute function app.set_updated_at();

drop trigger if exists trg_journal_entries_created_by on public.journal_entries;
create trigger trg_journal_entries_created_by
  before insert on public.journal_entries
  for each row execute function app.force_created_by();

create table if not exists public.journal_lines (
  id           uuid primary key default gen_random_uuid(),
  entry_id     uuid not null,
  client_id    uuid not null,
  line_no      smallint not null check (line_no > 0),
  account_id   uuid not null,
  debit        numeric(18,2) not null default 0 check (debit >= 0),
  credit       numeric(18,2) not null default 0 check (credit >= 0),
  dimension_id uuid,
  check (num_nonnulls(nullif(debit, 0), nullif(credit, 0)) = 1),
  unique (entry_id, line_no),
  foreign key (entry_id, client_id)     references public.journal_entries (id, client_id) on delete cascade,
  foreign key (account_id, client_id)   references public.accounts (id, client_id),
  foreign key (dimension_id, client_id) references public.dimensions (id, client_id)
);
create index if not exists journal_lines_entry_idx on public.journal_lines (entry_id);
create index if not exists journal_lines_account_idx on public.journal_lines (account_id);

-- ---------------------------------------------------------------- triggers

-- Posted entries are immutable. The single sanctioned mutation afterwards is
-- setting reversed_by (done by the reversal RPC); everything else — including
-- un-posting — is rejected regardless of who asks, definer context included.
create or replace function app.assert_entry_mutable() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'posted' then
    if tg_op = 'DELETE' then
      raise exception 'posted entries cannot be deleted — post a reversing entry';
    end if;
    if (to_jsonb(new) - 'reversed_by' - 'updated_at')
       is distinct from (to_jsonb(old) - 'reversed_by' - 'updated_at') then
      raise exception 'posted entries are immutable — post a reversing entry';
    end if;
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_journal_entries_immutable on public.journal_entries;
create trigger trg_journal_entries_immutable
  before update or delete on public.journal_entries
  for each row execute function app.assert_entry_mutable();

-- Lines exist only while the parent entry is a draft (cascade delete of a
-- draft entry is the one exception — the parent row is already gone by then).
create or replace function app.assert_lines_mutable() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status text;
begin
  select e.status into v_status
  from public.journal_entries e
  where e.id = coalesce(new.entry_id, old.entry_id);
  if v_status = 'posted' then
    raise exception 'lines of a posted entry are immutable — post a reversing entry';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_journal_lines_immutable on public.journal_lines;
create trigger trg_journal_lines_immutable
  before insert or update or delete on public.journal_lines
  for each row execute function app.assert_lines_mutable();

-- The posting gate. Runs on the draft -> posted transition no matter which
-- code path performs it: balance, line count, period status, date-in-period,
-- and no archived accounts.
create or replace function app.assert_entry_postable() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_debits numeric(18,2);
  v_credits numeric(18,2);
  v_lines int;
  v_period record;
begin
  select coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0), count(*)
    into v_debits, v_credits, v_lines
  from public.journal_lines l
  where l.entry_id = new.id;

  if v_lines < 2 then
    raise exception 'an entry needs at least two lines';
  end if;
  if v_debits <> v_credits then
    raise exception 'entry is out of balance: debits % <> credits %', v_debits, v_credits;
  end if;
  if v_debits = 0 then
    raise exception 'an entry cannot post with zero amounts';
  end if;

  if new.period_id is null then
    raise exception 'posting requires a period';
  end if;
  select p.status, p.period_start, p.period_end into v_period
  from public.periods p where p.id = new.period_id;
  if v_period.status is distinct from 'open' then
    raise exception 'period % to % is % — posting is only allowed into an open period',
      v_period.period_start, v_period.period_end, coalesce(v_period.status, 'missing');
  end if;
  if new.entry_date < v_period.period_start or new.entry_date > v_period.period_end then
    raise exception 'entry date % is outside the posting period', new.entry_date;
  end if;

  if exists (
    select 1 from public.journal_lines l
    join public.accounts a on a.id = l.account_id
    where l.entry_id = new.id and a.archived_at is not null
  ) then
    raise exception 'entry uses an archived account';
  end if;

  return new;
end $$;

drop trigger if exists trg_journal_entries_postable on public.journal_entries;
create trigger trg_journal_entries_postable
  before update of status on public.journal_entries
  for each row
  when (old.status = 'draft' and new.status = 'posted')
  execute function app.assert_entry_postable();

-- -------------------------------------------------------------------- RLS

alter table public.journal_entries enable row level security;
alter table public.journal_lines enable row level security;

drop policy if exists journal_entries_select on public.journal_entries;
create policy journal_entries_select on public.journal_entries
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

drop policy if exists journal_entries_insert on public.journal_entries;
create policy journal_entries_insert on public.journal_entries
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));

drop policy if exists journal_entries_update on public.journal_entries;
create policy journal_entries_update on public.journal_entries
  for update to authenticated
  using ((select app.can_write_client(client_id)) and status = 'draft')
  with check ((select app.can_write_client(client_id)));

drop policy if exists journal_entries_delete on public.journal_entries;
create policy journal_entries_delete on public.journal_entries
  for delete to authenticated
  using ((select app.can_write_client(client_id)) and status = 'draft');

grant select on public.journal_entries to authenticated;
grant insert (client_id, entry_date, memo) on public.journal_entries to authenticated;
grant update (entry_date, memo) on public.journal_entries to authenticated;
grant delete on public.journal_entries to authenticated;
-- status/entry_no/period_id/posting metadata are RPC-only by column grants.

drop policy if exists journal_lines_select on public.journal_lines;
create policy journal_lines_select on public.journal_lines
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

drop policy if exists journal_lines_write on public.journal_lines;
create policy journal_lines_write on public.journal_lines
  for all to authenticated
  using (
    (select app.can_write_client(client_id))
    and exists (select 1 from public.journal_entries e
                where e.id = entry_id and e.status = 'draft')
  )
  with check (
    (select app.can_write_client(client_id))
    and exists (select 1 from public.journal_entries e
                where e.id = entry_id and e.status = 'draft')
  );

grant select on public.journal_lines to authenticated;
grant insert (entry_id, client_id, line_no, account_id, debit, credit, dimension_id)
  on public.journal_lines to authenticated;
grant update (line_no, account_id, debit, credit, dimension_id) on public.journal_lines to authenticated;
grant delete on public.journal_lines to authenticated;

-- -------------------------------------------------------------------- RPCs

-- THE posting API. Serializes per client for gap-free entry numbers; the
-- postable trigger re-validates everything regardless.
create or replace function public.post_entry(p_entry_id uuid) returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
  v_entry record;
  v_no bigint;
begin
  select e.id, e.client_id, e.status, e.entry_date into v_entry
  from public.journal_entries e where e.id = p_entry_id;
  if v_entry.id is null then raise exception 'entry not found'; end if;
  if not (select app.can_write_client(v_entry.client_id)) then
    raise exception 'not authorized';
  end if;
  if v_entry.status <> 'draft' then
    raise exception 'only drafts can be posted';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_entry.client_id::text, 1));
  select coalesce(max(entry_no), 0) + 1 into v_no
  from public.journal_entries where client_id = v_entry.client_id;

  update public.journal_entries
     set status = 'posted',
         entry_no = v_no,
         period_id = app.ensure_period(v_entry.client_id, v_entry.entry_date),
         posted_by = (select auth.uid()),
         posted_at = now()
   where id = p_entry_id;

  return v_no;
end $$;

-- Corrections: a posted entry is never edited — it is reversed by a mirror
-- entry posted through the same gate.
create or replace function public.reverse_entry(
  p_entry_id uuid,
  p_date date default null,
  p_memo text default null
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_entry record;
  v_new uuid;
begin
  select e.id, e.client_id, e.status, e.entry_date, e.entry_no, e.memo, e.reversed_by into v_entry
  from public.journal_entries e where e.id = p_entry_id;
  if v_entry.id is null then raise exception 'entry not found'; end if;
  if not (select app.can_write_client(v_entry.client_id)) then
    raise exception 'not authorized';
  end if;
  if v_entry.status <> 'posted' then
    raise exception 'only posted entries can be reversed';
  end if;
  if v_entry.reversed_by is not null then
    raise exception 'this entry is already reversed';
  end if;

  insert into public.journal_entries (client_id, entry_date, source_type, memo, reversal_of, created_by)
  values (
    v_entry.client_id,
    coalesce(p_date, v_entry.entry_date),
    'reversal',
    coalesce(p_memo, 'Reversal of JE-' || v_entry.entry_no || ': ' || v_entry.memo),
    v_entry.id,
    (select auth.uid())
  ) returning id into v_new;

  insert into public.journal_lines (entry_id, client_id, line_no, account_id, debit, credit, dimension_id)
  select v_new, l.client_id, l.line_no, l.account_id, l.credit, l.debit, l.dimension_id
  from public.journal_lines l where l.entry_id = p_entry_id;

  perform public.post_entry(v_new);

  update public.journal_entries set reversed_by = v_new where id = p_entry_id;

  return v_new;
end $$;

revoke all on function public.post_entry(uuid), public.reverse_entry(uuid, date, text)
  from public, anon, authenticated;
grant execute on function public.post_entry(uuid), public.reverse_entry(uuid, date, text)
  to authenticated;

-- ------------------------------------------------------------ trial balance
-- SECURITY INVOKER on purpose: it reads through the caller's own RLS, so a
-- caller without access to the client simply gets zero rows. All non-archived
-- accounts appear (accounts with no activity show zeros).
create or replace function public.trial_balance(
  p_client_id uuid,
  p_date_from date,
  p_date_to date
) returns table (
  account_id uuid,
  code text,
  name text,
  account_type text,
  normal_balance text,
  total_debit numeric(18,2),
  total_credit numeric(18,2)
)
language sql stable
set search_path = ''
as $$
  select
    a.id,
    a.code,
    a.name,
    a.account_type,
    a.normal_balance,
    coalesce(sum(l.debit), 0)::numeric(18,2),
    coalesce(sum(l.credit), 0)::numeric(18,2)
  from public.accounts a
  left join public.journal_lines l
    on l.account_id = a.id
   and l.entry_id in (
     select e.id from public.journal_entries e
     where e.client_id = p_client_id
       and e.status = 'posted'
       and e.entry_date between p_date_from and p_date_to
   )
  where a.client_id = p_client_id
    and a.archived_at is null
  group by a.id, a.code, a.name, a.account_type, a.normal_balance
  order by a.code
$$;

revoke all on function public.trial_balance(uuid, date, date) from public, anon, authenticated;
grant execute on function public.trial_balance(uuid, date, date) to authenticated;
