-- firms and clients — the top two levels of the tenancy tree.
-- House rules established here, inherited by every later phase:
--   * unique (firm_id, id) anchors so children use composite FKs (cross-tenant
--     references become unrepresentable, not merely policy-blocked)
--   * attribution (created_by) is forced server-side, never trusted from the client
--   * archive, never delete

-- Forces created_by to the calling user whenever a real user is on the request.
-- coalesce keeps seed/test fixtures (no JWT, running as postgres) workable; an
-- API caller always has auth.uid(), so forgery through PostgREST is impossible.
create or replace function app.force_created_by() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.created_by = coalesce((select auth.uid()), new.created_by);
  return new;
end $$;

create table if not exists public.firms (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(btrim(name)) between 1 and 120),
  created_by  uuid not null references auth.users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

drop trigger if exists trg_firms_updated_at on public.firms;
create trigger trg_firms_updated_at
  before update on public.firms
  for each row execute function app.set_updated_at();

drop trigger if exists trg_firms_created_by on public.firms;
create trigger trg_firms_created_by
  before insert on public.firms
  for each row execute function app.force_created_by();

create table if not exists public.clients (
  id                     uuid primary key default gen_random_uuid(),  -- the /c/:clientId URL segment
  firm_id                uuid not null references public.firms(id),
  name                   text not null check (length(btrim(name)) between 1 and 200),
  -- Optional display label for BIR books / working papers. Never a lookup or URL key.
  code                   text check (code is null or length(btrim(code)) between 1 and 20),
  -- Format validation arrives with the Phase 5 tax profile.
  tin                    text,
  reporting_basis        text not null default 'accrual'
                           check (reporting_basis in ('accrual', 'cash')),
  fiscal_year_end_month  smallint not null default 12
                           check (fiscal_year_end_month between 1 and 12),
  -- Books are PHP-functional. FX-readiness is deliberately NOT a Phase 1 feature:
  -- lifting this CHECK plus optional original-currency columns on future document
  -- tables is purely additive. Column-level grants exclude this column, so no
  -- API caller can touch it even before the CHECK is consulted.
  functional_currency    char(3) not null default 'PHP'
                           check (functional_currency = 'PHP'),
  archived_at            timestamptz,
  created_by             uuid not null references auth.users(id),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (firm_id, id)   -- composite-FK anchor for every later child table
);

-- Active client names unique per firm; archiving frees the name for re-onboarding.
create unique index if not exists clients_firm_name_uniq
  on public.clients (firm_id, lower(name)) where archived_at is null;
create unique index if not exists clients_firm_code_uniq
  on public.clients (firm_id, code) where code is not null;
create index if not exists clients_firm_idx on public.clients (firm_id);

drop trigger if exists trg_clients_updated_at on public.clients;
create trigger trg_clients_updated_at
  before update on public.clients
  for each row execute function app.set_updated_at();

drop trigger if exists trg_clients_created_by on public.clients;
create trigger trg_clients_created_by
  before insert on public.clients
  for each row execute function app.force_created_by();

-- Phase 2 obligation (recorded in ADR-0001): once periods exist, changes to
-- fiscal_year_end_month and reporting_basis must be trigger-blocked for clients
-- that have generated periods.
