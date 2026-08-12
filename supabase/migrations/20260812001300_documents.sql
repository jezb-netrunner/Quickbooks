-- Phase 3, part 1: contacts and source documents (invoices, bills, receipts,
-- disbursements), all posting through the Phase 2 journal engine — no document
-- type writes its own ledger logic. Open-item AR/AP application lives in
-- document_applications; a document's open balance is its total minus issued,
-- unvoided applications against it.

-- ---------------------------------------------------------------- contacts
create table if not exists public.contacts (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references public.clients(id),
  name         text not null check (length(btrim(name)) between 1 and 160),
  contact_type text not null check (contact_type in ('customer', 'vendor', 'both')),
  tin          text,
  email        text,
  archived_at  timestamptz,
  created_by   uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (id, client_id)
);
create unique index if not exists contacts_client_name_uniq
  on public.contacts (client_id, lower(name)) where archived_at is null;
create index if not exists contacts_client_idx on public.contacts (client_id);

drop trigger if exists trg_contacts_updated_at on public.contacts;
create trigger trg_contacts_updated_at
  before update on public.contacts
  for each row execute function app.set_updated_at();

drop trigger if exists trg_contacts_created_by on public.contacts;
create trigger trg_contacts_created_by
  before insert on public.contacts
  for each row execute function app.force_created_by();

alter table public.contacts enable row level security;

drop policy if exists contacts_select on public.contacts;
create policy contacts_select on public.contacts
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

drop policy if exists contacts_insert on public.contacts;
create policy contacts_insert on public.contacts
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));

drop policy if exists contacts_update on public.contacts;
create policy contacts_update on public.contacts
  for update to authenticated
  using ((select app.can_write_client(client_id)))
  with check ((select app.can_write_client(client_id)));

grant select on public.contacts to authenticated;
grant insert (client_id, name, contact_type, tin, email) on public.contacts to authenticated;
grant update (name, contact_type, tin, email, archived_at) on public.contacts to authenticated;

-- ---------------------------------------------------- journal source types
-- Documents post with their own source label through the same engine.
alter table public.journal_entries drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries add constraint journal_entries_source_type_check
  check (source_type in ('manual', 'opening_balance', 'reversal',
                         'invoice', 'bill', 'receipt', 'disbursement'));

-- -------------------------------------------------------------- documents
create table if not exists public.documents (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid not null references public.clients(id),
  doc_type         text not null check (doc_type in ('invoice', 'bill', 'receipt', 'disbursement')),
  doc_no           bigint,                -- assigned per client+type at issue
  doc_date         date not null,
  due_date         date,
  contact_id       uuid not null,
  -- receipts/disbursements: the cash/bank account money moved through
  bank_account_id  uuid,
  memo             text not null default '',
  status           text not null default 'draft' check (status in ('draft', 'issued', 'voided')),
  entry_id         uuid,                  -- the journal entry this document posted
  voided_at        timestamptz,
  created_by       uuid references auth.users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (id, client_id),
  foreign key (contact_id, client_id)      references public.contacts (id, client_id),
  foreign key (bank_account_id, client_id) references public.accounts (id, client_id),
  foreign key (entry_id, client_id)        references public.journal_entries (id, client_id)
);
create unique index if not exists documents_client_type_no_uniq
  on public.documents (client_id, doc_type, doc_no) where doc_no is not null;
create index if not exists documents_client_type_idx on public.documents (client_id, doc_type);
create index if not exists documents_contact_idx on public.documents (contact_id);

drop trigger if exists trg_documents_updated_at on public.documents;
create trigger trg_documents_updated_at
  before update on public.documents
  for each row execute function app.set_updated_at();

drop trigger if exists trg_documents_created_by on public.documents;
create trigger trg_documents_created_by
  before insert on public.documents
  for each row execute function app.force_created_by();

create table if not exists public.document_lines (
  id           uuid primary key default gen_random_uuid(),
  document_id  uuid not null,
  client_id    uuid not null,
  line_no      smallint not null check (line_no > 0),
  account_id   uuid not null,
  description  text not null default '',
  amount       numeric(18,2) not null check (amount > 0),
  unique (document_id, line_no),
  foreign key (document_id, client_id) references public.documents (id, client_id) on delete cascade,
  foreign key (account_id, client_id)  references public.accounts (id, client_id)
);
create index if not exists document_lines_document_idx on public.document_lines (document_id);

-- Open-item application: a paying document (receipt/disbursement) settles one
-- or more target documents (invoices/bills), partially or fully.
create table if not exists public.document_applications (
  id                uuid primary key default gen_random_uuid(),
  client_id         uuid not null,
  paying_document_id uuid not null,
  target_document_id uuid not null,
  amount            numeric(18,2) not null check (amount > 0),
  unique (paying_document_id, target_document_id),
  foreign key (paying_document_id, client_id) references public.documents (id, client_id) on delete cascade,
  foreign key (target_document_id, client_id) references public.documents (id, client_id)
);
create index if not exists document_applications_target_idx
  on public.document_applications (target_document_id);

-- Issued documents are frozen except the void transition (RPC-only columns).
create or replace function app.assert_document_mutable() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status <> 'draft' then
    if tg_op = 'DELETE' then
      raise exception 'issued documents cannot be deleted — void them instead';
    end if;
    if (to_jsonb(new) - 'status' - 'voided_at' - 'updated_at')
       is distinct from (to_jsonb(old) - 'status' - 'voided_at' - 'updated_at')
       or (new.status is distinct from old.status and not (old.status = 'issued' and new.status = 'voided')) then
      raise exception 'issued documents are immutable — void and recreate';
    end if;
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_documents_immutable on public.documents;
create trigger trg_documents_immutable
  before update or delete on public.documents
  for each row execute function app.assert_document_mutable();

create or replace function app.assert_document_children_mutable() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_parent uuid;
  v_status text;
begin
  -- Each child table names its parent differently; only the taken branch is
  -- evaluated, so the record field access stays valid per table.
  if tg_table_name = 'document_lines' then
    v_parent := coalesce(new.document_id, old.document_id);
  else
    v_parent := coalesce(new.paying_document_id, old.paying_document_id);
  end if;
  select d.status into v_status from public.documents d where d.id = v_parent;
  if v_status is distinct from 'draft' and v_status is not null then
    raise exception 'lines and applications are frozen once the document is issued';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_document_lines_frozen on public.document_lines;
create trigger trg_document_lines_frozen
  before insert or update or delete on public.document_lines
  for each row execute function app.assert_document_children_mutable();

drop trigger if exists trg_document_applications_frozen on public.document_applications;
create trigger trg_document_applications_frozen
  before insert or update or delete on public.document_applications
  for each row execute function app.assert_document_children_mutable();

-- -------------------------------------------------------------------- RLS
alter table public.documents enable row level security;
alter table public.document_lines enable row level security;
alter table public.document_applications enable row level security;

drop policy if exists documents_select on public.documents;
create policy documents_select on public.documents
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

drop policy if exists documents_insert on public.documents;
create policy documents_insert on public.documents
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));

drop policy if exists documents_update on public.documents;
create policy documents_update on public.documents
  for update to authenticated
  using ((select app.can_write_client(client_id)) and status = 'draft')
  with check ((select app.can_write_client(client_id)));

drop policy if exists documents_delete on public.documents;
create policy documents_delete on public.documents
  for delete to authenticated
  using ((select app.can_write_client(client_id)) and status = 'draft');

grant select on public.documents to authenticated;
grant insert (client_id, doc_type, doc_date, due_date, contact_id, bank_account_id, memo)
  on public.documents to authenticated;
grant update (doc_date, due_date, contact_id, bank_account_id, memo)
  on public.documents to authenticated;
grant delete on public.documents to authenticated;

drop policy if exists document_lines_select on public.document_lines;
create policy document_lines_select on public.document_lines
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

drop policy if exists document_lines_write on public.document_lines;
create policy document_lines_write on public.document_lines
  for all to authenticated
  using (
    (select app.can_write_client(client_id))
    and exists (select 1 from public.documents d where d.id = document_id and d.status = 'draft')
  )
  with check (
    (select app.can_write_client(client_id))
    and exists (select 1 from public.documents d where d.id = document_id and d.status = 'draft')
  );

grant select on public.document_lines to authenticated;
grant insert (document_id, client_id, line_no, account_id, description, amount)
  on public.document_lines to authenticated;
grant update (line_no, account_id, description, amount) on public.document_lines to authenticated;
grant delete on public.document_lines to authenticated;

drop policy if exists document_applications_select on public.document_applications;
create policy document_applications_select on public.document_applications
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

drop policy if exists document_applications_write on public.document_applications;
create policy document_applications_write on public.document_applications
  for all to authenticated
  using (
    (select app.can_write_client(client_id))
    and exists (select 1 from public.documents d where d.id = paying_document_id and d.status = 'draft')
  )
  with check (
    (select app.can_write_client(client_id))
    and exists (select 1 from public.documents d where d.id = paying_document_id and d.status = 'draft')
  );

grant select on public.document_applications to authenticated;
grant insert (client_id, paying_document_id, target_document_id, amount)
  on public.document_applications to authenticated;
grant update (amount) on public.document_applications to authenticated;
grant delete on public.document_applications to authenticated;
