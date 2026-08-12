-- Phase 2, part 1: chart of accounts per client + the PH SME template.
--
-- House rules inherited from Phase 1: client_id NOT NULL, unique (id, client_id)
-- anchors, composite FKs, the two-line RLS contract, archive-never-delete,
-- column-level grants as immutability.

create table if not exists public.accounts (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references public.clients(id),
  code            text not null check (code ~ '^[0-9]{4}(-[0-9]{2})?$'),
  name            text not null check (length(btrim(name)) between 1 and 120),
  account_type    text not null check (account_type in ('asset','liability','equity','income','expense')),
  normal_balance  text not null check (normal_balance in ('debit','credit')),
  parent_id       uuid,
  archived_at     timestamptz,
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (client_id, code),
  unique (id, client_id),
  foreign key (parent_id, client_id) references public.accounts (id, client_id)
);
create index if not exists accounts_client_idx on public.accounts (client_id);

drop trigger if exists trg_accounts_updated_at on public.accounts;
create trigger trg_accounts_updated_at
  before update on public.accounts
  for each row execute function app.set_updated_at();

drop trigger if exists trg_accounts_created_by on public.accounts;
create trigger trg_accounts_created_by
  before insert on public.accounts
  for each row execute function app.force_created_by();

-- Classification is immutable once the account has activity: account_type and
-- normal_balance drive report classification, so changing them would silently
-- restate history. (Excluded from the UPDATE grant entirely; archive and
-- recreate if a template account was set up wrong before use.)

alter table public.accounts enable row level security;

drop policy if exists accounts_select on public.accounts;
create policy accounts_select on public.accounts
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

drop policy if exists accounts_insert on public.accounts;
create policy accounts_insert on public.accounts
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));

drop policy if exists accounts_update on public.accounts;
create policy accounts_update on public.accounts
  for update to authenticated
  using ((select app.can_write_client(client_id)))
  with check ((select app.can_write_client(client_id)));

grant select on public.accounts to authenticated;
grant insert (client_id, code, name, account_type, normal_balance, parent_id)
  on public.accounts to authenticated;
grant update (code, name, parent_id, archived_at) on public.accounts to authenticated;
-- No DELETE: an account with activity must survive; archive hides it.

-- ---------------------------------------------------------------- dimensions
-- Optional branch/cost-center dimension per client (approved scope: some
-- clients need it). Schema now, UI when a client actually asks.
create table if not exists public.dimensions (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.clients(id),
  name        text not null check (length(btrim(name)) between 1 and 80),
  archived_at timestamptz,
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (id, client_id)
);
create unique index if not exists dimensions_client_name_uniq
  on public.dimensions (client_id, lower(name)) where archived_at is null;

drop trigger if exists trg_dimensions_updated_at on public.dimensions;
create trigger trg_dimensions_updated_at
  before update on public.dimensions
  for each row execute function app.set_updated_at();

drop trigger if exists trg_dimensions_created_by on public.dimensions;
create trigger trg_dimensions_created_by
  before insert on public.dimensions
  for each row execute function app.force_created_by();

alter table public.dimensions enable row level security;

drop policy if exists dimensions_select on public.dimensions;
create policy dimensions_select on public.dimensions
  for select to authenticated
  using (client_id in (select app.accessible_client_ids()));

drop policy if exists dimensions_insert on public.dimensions;
create policy dimensions_insert on public.dimensions
  for insert to authenticated
  with check ((select app.can_write_client(client_id)));

drop policy if exists dimensions_update on public.dimensions;
create policy dimensions_update on public.dimensions
  for update to authenticated
  using ((select app.can_write_client(client_id)))
  with check ((select app.can_write_client(client_id)));

grant select on public.dimensions to authenticated;
grant insert (client_id, name) on public.dimensions to authenticated;
grant update (name, archived_at) on public.dimensions to authenticated;

-- ------------------------------------------------------------ CoA template
-- Versioned reference data (non-negotiable #4: structure in tables, values the
-- practice can verify), shipped as a data migration so a fresh database
-- reproduces it everywhere. Not tenant data: readable by any signed-in user.
create table if not exists public.coa_template (
  code            text primary key,
  name            text not null,
  account_type    text not null check (account_type in ('asset','liability','equity','income','expense')),
  normal_balance  text not null check (normal_balance in ('debit','credit')),
  parent_code     text references public.coa_template(code),
  sort_order      int not null
);

alter table public.coa_template enable row level security;
drop policy if exists coa_template_select on public.coa_template;
create policy coa_template_select on public.coa_template
  for select to authenticated using (true);
grant select on public.coa_template to authenticated;
-- Rows come from migrations only.

insert into public.coa_template (code, name, account_type, normal_balance, parent_code, sort_order) values
  ('1000', 'Cash and cash equivalents',            'asset',     'debit',  null,   10),
  ('1000-01', 'Cash on hand',                      'asset',     'debit',  '1000', 11),
  ('1000-02', 'Cash in bank',                      'asset',     'debit',  '1000', 12),
  ('1100', 'Accounts receivable — trade',          'asset',     'debit',  null,   20),
  ('1110', 'Allowance for doubtful accounts',      'asset',     'credit', null,   21),
  ('1150', 'Advances to suppliers',                'asset',     'debit',  null,   22),
  ('1200', 'Inventory',                            'asset',     'debit',  null,   30),
  ('1300', 'Prepaid expenses',                     'asset',     'debit',  null,   40),
  ('1310', 'Input VAT',                            'asset',     'debit',  null,   41),
  ('1320', 'Creditable withholding tax (2307)',    'asset',     'debit',  null,   42),
  ('1500', 'Property and equipment',               'asset',     'debit',  null,   50),
  ('1510', 'Accumulated depreciation',             'asset',     'credit', null,   51),
  ('1600', 'Security deposits',                    'asset',     'debit',  null,   60),
  ('2000', 'Accounts payable — trade',             'liability', 'credit', null,   100),
  ('2100', 'Accrued expenses',                     'liability', 'credit', null,   110),
  ('2200', 'Output VAT',                           'liability', 'credit', null,   120),
  ('2210', 'VAT payable',                          'liability', 'credit', null,   121),
  ('2220', 'Percentage tax payable',               'liability', 'credit', null,   122),
  ('2230', 'Expanded withholding tax payable',     'liability', 'credit', null,   123),
  ('2240', 'Withholding tax on compensation payable', 'liability', 'credit', null, 124),
  ('2250', 'SSS, PhilHealth and Pag-IBIG payable', 'liability', 'credit', null,   125),
  ('2260', 'Income tax payable',                   'liability', 'credit', null,   126),
  ('2300', 'Advances from customers',              'liability', 'credit', null,   130),
  ('2400', 'Loans payable',                        'liability', 'credit', null,   140),
  ('3000', 'Owner''s capital',                     'equity',    'credit', null,   200),
  ('3100', 'Owner''s drawings',                    'equity',    'debit',  null,   210),
  ('3200', 'Retained earnings',                    'equity',    'credit', null,   220),
  ('4000', 'Sales',                                'income',    'credit', null,   300),
  ('4010', 'Sales returns and allowances',         'income',    'debit',  null,   301),
  ('4020', 'Sales discounts',                      'income',    'debit',  null,   302),
  ('4100', 'Service income',                       'income',    'credit', null,   310),
  ('4900', 'Other income',                         'income',    'credit', null,   390),
  ('5000', 'Cost of sales',                        'expense',   'debit',  null,   400),
  ('5010', 'Purchases',                            'expense',   'debit',  null,   401),
  ('5020', 'Freight-in',                           'expense',   'debit',  null,   402),
  ('6000', 'Salaries and wages',                   'expense',   'debit',  null,   500),
  ('6010', 'SSS, PhilHealth and Pag-IBIG — employer', 'expense', 'debit', null,   501),
  ('6020', '13th month pay and bonuses',           'expense',   'debit',  null,   502),
  ('6100', 'Rent expense',                         'expense',   'debit',  null,   510),
  ('6110', 'Utilities expense',                    'expense',   'debit',  null,   511),
  ('6120', 'Communication expense',                'expense',   'debit',  null,   512),
  ('6130', 'Office supplies expense',              'expense',   'debit',  null,   513),
  ('6140', 'Transportation and travel',            'expense',   'debit',  null,   514),
  ('6150', 'Repairs and maintenance',              'expense',   'debit',  null,   515),
  ('6160', 'Insurance expense',                    'expense',   'debit',  null,   516),
  ('6170', 'Professional fees',                    'expense',   'debit',  null,   517),
  ('6180', 'Representation and entertainment',     'expense',   'debit',  null,   518),
  ('6190', 'Taxes and licenses',                   'expense',   'debit',  null,   519),
  ('6200', 'Depreciation expense',                 'expense',   'debit',  null,   520),
  ('6210', 'Bank charges',                         'expense',   'debit',  null,   521),
  ('6220', 'Interest expense',                     'expense',   'debit',  null,   522),
  ('6900', 'Miscellaneous expense',                'expense',   'debit',  null,   590)
on conflict (code) do nothing;

-- Seeds a client's chart from the template. Two-pass so parent links land
-- regardless of insert order. Idempotent per account code.
create or replace function public.seed_client_coa(p_client_id uuid) returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if not (select app.can_write_client(p_client_id)) then
    raise exception 'not authorized';
  end if;

  insert into public.accounts (client_id, code, name, account_type, normal_balance, created_by)
  select p_client_id, t.code, t.name, t.account_type, t.normal_balance, (select auth.uid())
  from public.coa_template t
  on conflict (client_id, code) do nothing;
  get diagnostics v_count = row_count;

  update public.accounts a
     set parent_id = p.id
    from public.coa_template t, public.accounts p
   where a.client_id = p_client_id
     and a.code = t.code
     and t.parent_code is not null
     and p.client_id = a.client_id
     and p.code = t.parent_code
     and a.parent_id is null;

  return v_count;
end $$;

revoke all on function public.seed_client_coa(uuid) from public, anon, authenticated;
grant execute on function public.seed_client_coa(uuid) to authenticated;
