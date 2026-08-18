-- The 8% income-tax option is only for NON-VAT individuals (RA 10963/TRAIN:
-- the election is in lieu of the graduated tax AND the Sec. 116 percentage
-- tax, and is unavailable to VAT-registered persons). Live testing produced a
-- VAT + 8% client, which computes a legally impossible return. Practice CPA
-- confirmed the rule (2026-08-19). Three walls: the wizard hides the option,
-- setup_client validates, and the table CHECK makes the shape unstorable.

-- Normalize any existing offender to the graduated table before the CHECK
-- validates (the CPA re-runs setup if non-VAT + 8% was the real intent).
update public.client_tax_profiles
   set income_tax_option = 'graduated'
 where regime = 'vat' and income_tax_option = 'eight_percent';

alter table public.client_tax_profiles
  drop constraint if exists client_tax_profiles_vat_option_check;
alter table public.client_tax_profiles
  add constraint client_tax_profiles_vat_option_check
  check (not (regime = 'vat' and income_tax_option = 'eight_percent'));

-- setup_client — same body as 20260819000200 plus the regime/option rule.
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
  if p_taxpayer_kind = 'corporate' and p_income_tax_option <> 'rcit' then
    raise exception 'a corporate taxpayer files under RCIT — choose rcit';
  end if;
  if p_taxpayer_kind = 'individual' and p_income_tax_option = 'rcit' then
    raise exception 'RCIT applies to corporate taxpayers — choose graduated or eight_percent';
  end if;
  if p_regime = 'vat' and p_income_tax_option = 'eight_percent' then
    raise exception 'the 8%% option is only available to non-VAT individuals — a VAT-registered taxpayer files under the graduated table';
  end if;

  perform public.seed_client_coa(p_client_id);
  -- Write the WHOLE profile in one atomic upsert BEFORE the seeds: updating
  -- regime and option separately would pass through an invalid intermediate
  -- shape (e.g. non-VAT 8% → VAT momentarily reads vat+eight_percent, which
  -- the vat_option CHECK rightly rejects). seed_client_tax_codes' own regime
  -- upsert then no-ops against the already-correct value.
  insert into public.client_tax_profiles
    (client_id, regime, taxpayer_kind, income_tax_option, compliance_start)
  values (p_client_id, p_regime, p_taxpayer_kind, p_income_tax_option,
          date_trunc('month', (now() at time zone 'Asia/Manila'))::date)
  on conflict (client_id) do update
    set regime = p_regime,
        taxpayer_kind = p_taxpayer_kind,
        income_tax_option = p_income_tax_option,
        compliance_start = coalesce(public.client_tax_profiles.compliance_start,
                                    date_trunc('month', (now() at time zone 'Asia/Manila'))::date);
  perform public.seed_client_tax_codes(p_client_id, p_regime);
  perform public.seed_client_compliance(p_client_id);

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
