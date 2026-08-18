-- T-01 remediation — guided client setup (live-testing finding, 2026-08-18).
--
-- Live CPA testing found a client ("Petron") with a chart of accounts, no tax
-- profile, no tax codes — and 14 posted entries. Creating a client and seeding
-- the COA never set up tax, and nothing stopped document posting for an
-- unconfigured client, so its books were silently VAT-free.
--
-- Two changes:
--   1) setup_client — one atomic RPC the onboarding wizard calls: seeds the
--      COA, the tax codes for the regime, stamps the taxpayer shape, and seeds
--      the compliance calendar, in an order that respects the P3-09 branch
--      (compliance reads income_tax_option, so the option lands first).
--   2) assert_lines_avoid_control (v4) — issuing any document now requires the
--      client to have a tax profile. The UI blocks entry earlier with a banner;
--      this is the enforcement. Existing unconfigured clients regain posting
--      the moment tax setup runs (Client settings → Tax profile).
--      Scope is DOCUMENTS deliberately: manual journal entries and bank
--      categorization stay open for an unconfigured client (they carry no
--      VAT/withholding, and P3-02's control-account guard already keeps them
--      off the tax and subledger accounts) — 009_journal pins that behavior.

-- ---------------------------------------------------------------- 1) RPC
create or replace function public.setup_client(
  p_client_id uuid,
  p_regime text,
  p_taxpayer_kind text,
  p_income_tax_option text
) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not (select app.can_write_client(p_client_id)) then
    raise exception 'not authorized';
  end if;
  if p_regime not in ('vat', 'non_vat') then
    raise exception 'regime must be vat or non_vat';
  end if;
  if p_taxpayer_kind not in ('individual', 'corporate') then
    raise exception 'taxpayer kind must be individual or corporate';
  end if;
  if p_income_tax_option not in ('graduated', 'eight_percent', 'rcit') then
    raise exception 'income tax option must be graduated, eight_percent, or rcit';
  end if;
  -- The income-tax option follows the taxpayer kind (1701 individuals file
  -- graduated or 8%; 1702 corporations file RCIT).
  if p_taxpayer_kind = 'corporate' and p_income_tax_option <> 'rcit' then
    raise exception 'a corporate taxpayer files under RCIT — choose rcit';
  end if;
  if p_taxpayer_kind = 'individual' and p_income_tax_option = 'rcit' then
    raise exception 'RCIT applies to corporate taxpayers — choose graduated or eight_percent';
  end if;

  -- Each seed is idempotent (insert … on conflict do nothing) and takes the
  -- same per-client advisory lock, so re-running setup keeps existing codes,
  -- rates, and rules and only adds what is missing.
  perform public.seed_client_coa(p_client_id);
  perform public.seed_client_tax_codes(p_client_id, p_regime);
  update public.client_tax_profiles
     set taxpayer_kind = p_taxpayer_kind,
         income_tax_option = p_income_tax_option
   where client_id = p_client_id;
  -- After the option update: seed_client_compliance branches on it (P3-09 —
  -- an 8%-option client must not get the 2551Q rule).
  perform public.seed_client_compliance(p_client_id);

  -- Reconcile a re-run with a CHANGED profile. The seeds are additive-only, so
  -- flipping regime/kind/option would otherwise leave contradictory rules and
  -- codes behind (e.g. graduated→8% keeps a live 2551Q; vat→non_vat keeps the
  -- VAT codes issuable). Toggle `active` only: filing history references forms
  -- by text and is never touched, and a flip back reactivates cleanly.
  update public.tax_codes set active = (p_regime = 'vat')
   where client_id = p_client_id and kind in ('output_vat', 'input_vat');
  update public.compliance_rules set active = (p_regime = 'vat')
   where client_id = p_client_id and form = '2550Q';
  update public.compliance_rules
     set active = (p_regime = 'non_vat' and p_income_tax_option <> 'eight_percent')
   where client_id = p_client_id and form = '2551Q';
  update public.compliance_rules set active = (p_taxpayer_kind = 'individual')
   where client_id = p_client_id and form in ('1701Q', '1701A');
  update public.compliance_rules set active = (p_taxpayer_kind = 'corporate')
   where client_id = p_client_id and form in ('1702Q', '1702-RT');
end $$;

revoke all on function public.setup_client(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.setup_client(uuid, text, text, text) to authenticated;

-- ------------------------------------------------- 2) issue gate (guard v4)
-- Same body as v3 (control accounts, 1200-via-items, tax accounts) plus the
-- tax-profile gate up front. issue_document calls this for every document
-- type before posting, so an unconfigured client cannot move the books.
create or replace function app.assert_lines_avoid_control(p_document_id uuid, p_client_id uuid) returns void
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.client_tax_profiles p where p.client_id = p_client_id
  ) then
    raise exception 'run tax setup first — this client has no tax profile, so VAT and withholding cannot apply (Client settings → Tax profile)';
  end if;
  if exists (
    select 1
    from public.document_lines l
    join public.accounts a on a.id = l.account_id
    where l.document_id = p_document_id
      and a.code in ('1100', '2000')
  ) then
    raise exception 'document lines cannot use the receivable or payable control accounts — those sides post automatically';
  end if;
  if exists (
    select 1
    from public.document_lines l
    join public.accounts a on a.id = l.account_id
    where l.document_id = p_document_id
      and l.item_id is null
      and a.code = '1200'
  ) then
    raise exception 'inventory moves through item lines — pick an item instead of posting to 1200 directly';
  end if;
  if exists (
    select 1
    from public.document_lines l
    join public.accounts a on a.id = l.account_id
    where l.document_id = p_document_id
      and a.code in (select tc.account_code from public.tax_codes tc where tc.client_id = p_client_id)
  ) then
    raise exception 'document lines cannot post directly to a tax account — pick a tax code on the line and the engine posts the tax';
  end if;
end $$;
