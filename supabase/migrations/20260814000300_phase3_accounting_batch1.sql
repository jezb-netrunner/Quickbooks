-- Phase 3 remediation — accounting integrity (batch 1).
-- Fixes audit finding P3-05.

-- ---------------------------------------------------------------------------
-- P3-05 — reverse_entry had a check-then-act race: it read reversed_by, checked
-- it was null, built and POSTED the mirror entry, and only afterwards set
-- reversed_by — unconditionally, with no lock taken before the check. Two
-- concurrent calls (double-click / two tabs / a retried request) both passed the
-- null check and both posted, leaving the ledger with A + R1 + R2 = -A and the
-- original flagged reversed (R1 orphaned). Fix: take the client's posting
-- advisory lock (the same key post_entry uses) BEFORE the check so reversals of
-- one client serialize, re-read reversed_by under the lock, and make the final
-- flag-write conditional with a row-count guard as a second wall.
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
  v_status text;
  v_reversed uuid;
begin
  select e.id, e.client_id, e.status, e.entry_date, e.entry_no, e.memo, e.reversed_by into v_entry
  from public.journal_entries e where e.id = p_entry_id;
  if v_entry.id is null then raise exception 'entry not found'; end if;
  if not (select app.can_write_client(v_entry.client_id)) then
    raise exception 'not authorized';
  end if;

  -- Serialize reversals of this client (post_entry takes the same key later; the
  -- lock is reentrant within this transaction), then re-read under the lock.
  perform pg_advisory_xact_lock(hashtextextended(v_entry.client_id::text, 1));
  select e.status, e.reversed_by into v_status, v_reversed
  from public.journal_entries e where e.id = p_entry_id;
  if v_status <> 'posted' then
    raise exception 'only posted entries can be reversed';
  end if;
  if v_reversed is not null then
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

  update public.journal_entries set reversed_by = v_new
   where id = p_entry_id and reversed_by is null;
  if not found then
    raise exception 'this entry was reversed concurrently';
  end if;

  return v_new;
end $$;
