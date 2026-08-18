-- T-01 review follow-up — the taxpayer-shape invariant belongs to the table.
--
-- setup_client validates that the income-tax option fits the taxpayer kind,
-- but authenticated also holds direct column grants on client_tax_profiles
-- (update (regime) / update (taxpayer_kind, income_tax_option)) under RLS, so
-- a PostgREST PATCH could store individual+rcit or corporate+eight_percent and
-- downstream consumers would diverge (seed_client_compliance branches on kind,
-- wp_income_tax on option). The database is the enforcement layer here, so the
-- cross-field rule becomes a CHECK: corporates file RCIT, individuals don't.

-- Normalize any pre-existing inconsistent row to its kind's default option
-- before the constraint validates (defensive: none are known to exist).
update public.client_tax_profiles
   set income_tax_option = case when taxpayer_kind = 'corporate' then 'rcit' else 'graduated' end
 where (taxpayer_kind = 'corporate') <> (income_tax_option = 'rcit');

alter table public.client_tax_profiles
  drop constraint if exists client_tax_profiles_shape_check;
alter table public.client_tax_profiles
  add constraint client_tax_profiles_shape_check
  check ((taxpayer_kind = 'corporate') = (income_tax_option = 'rcit'));
