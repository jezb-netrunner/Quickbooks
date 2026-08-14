-- Phase 2 remediation — security hardening (batch 1).
-- Fixes audit findings P4-07 and P4-10. (P4-04 CSV/formula injection and P4-08
-- PUBLIC-grant tripwire are fixed in the frontend and the meta-test respectively.)

-- ---------------------------------------------------------------------------
-- P4-07 — open_items and purchases_book were DROP+CREATEd in a later migration
-- without the explicit grant block every other function carries, leaving them
-- PUBLIC/anon-EXECUTEable in the API-exposed schema. Both are SECURITY INVOKER
-- so RLS still returns zero rows to anon, but anon must hold NO execute (the
-- default-closed second wall). Restore it. The P4-08 tripwire (tests/001_meta.sql)
-- now guards this class of regression on every CI run.
revoke all on function
  public.open_items(uuid, text, date),
  public.purchases_book(uuid, date, date)
from public, anon, authenticated;
grant execute on function
  public.open_items(uuid, text, date),
  public.purchases_book(uuid, date, date)
to authenticated;

-- ---------------------------------------------------------------------------
-- P4-10 — import_bank_txns had no cap on the row array (an uncapped loop is a
-- bounded DoS) and a non-array p_rows raised an uncaught "cannot extract
-- elements from a non-array" from jsonb_array_elements OUTSIDE the per-row
-- guard, contradicting the "bad input is skipped" contract. Validate the shape
-- and bound the size up front; per-row parsing is unchanged. (5000 rows/import
-- is a generous ceiling for a bank statement; raise it here if a client needs more.)
create or replace function public.import_bank_txns(
  p_client_id uuid,
  p_bank_account_id uuid,
  p_rows jsonb
) returns table (inserted int, duplicates int, skipped int)
language plpgsql security definer
set search_path = ''
as $$
declare
  v_code text;
  r jsonb;
  v_date date;
  v_amount numeric(18,2);
  v_desc text;
  v_fp text;
  v_ins int := 0;
  v_dup int := 0;
  v_skip int := 0;
  v_count int;
begin
  if not (select app.can_write_client(p_client_id)) then
    raise exception 'not authorized';
  end if;
  select a.code into v_code from public.accounts a
   where a.id = p_bank_account_id and a.client_id = p_client_id and a.archived_at is null;
  if v_code is null or v_code not like '1000%' then
    raise exception 'import lands in an active 1000-series cash account';
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'rows must be a JSON array';
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    raise exception 'too many rows in one import (max 5000)';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    begin
      v_date := (r ->> 'd')::date;
      v_amount := round((r ->> 'a')::numeric, 2);
      v_desc := btrim(coalesce(r ->> 'm', ''));
    exception when others then
      v_skip := v_skip + 1;
      continue;
    end;
    if v_date is null or v_amount is null or v_amount = 0 then
      v_skip := v_skip + 1;
      continue;
    end if;
    v_fp := md5(p_bank_account_id::text || '|' || v_date || '|' || v_amount || '|' || lower(v_desc));
    insert into public.bank_txns
      (client_id, bank_account_id, txn_date, description, amount, fingerprint, imported_by)
    values (p_client_id, p_bank_account_id, v_date, v_desc, v_amount, v_fp, (select auth.uid()))
    on conflict (client_id, fingerprint) do nothing;
    get diagnostics v_count = row_count;
    if v_count = 1 then v_ins := v_ins + 1; else v_dup := v_dup + 1; end if;
  end loop;
  return query select v_ins, v_dup, v_skip;
end $$;
