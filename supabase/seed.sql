-- Local development fixtures ONLY. This file runs on `supabase db reset` for the
-- LOCAL stack; it never runs against the hosted project (deploys use `db push`,
-- which applies migrations only). Every name below is fictional — real client
-- data must never appear in this repo (public repo, approved decision 2).
--
-- Demo topology (mirrors the pgTAP fixtures, so manual poking in the local
-- dashboard matches what the tests assert):
--   Firm "Dela Cruz & Co, CPAs"
--     owner@demo.larkspur.ph       firm_admin
--     staff@demo.larkspur.ph       staff, assigned to Sampaguita Trading only
--     unassigned@demo.larkspur.ph  staff, no assignments (sees nothing)
--     viewer@demo.larkspur.ph      client_viewer bound to Sampaguita Trading
--     clients: Sampaguita Trading, Narra Furniture Works
--   Firm "Bayanihan Bookkeepers"
--     other@demo.larkspur.ph       firm_admin
--     client: Mango Grove Cafe
-- All passwords: demo-password-123

do $$
declare
  u record;
begin
  for u in
    select * from (values
      ('11111111-1111-4111-8111-111111111101'::uuid, 'owner@demo.larkspur.ph',      'Maria dela Cruz'),
      ('11111111-1111-4111-8111-111111111102'::uuid, 'staff@demo.larkspur.ph',      'Juan Santos'),
      ('11111111-1111-4111-8111-111111111103'::uuid, 'unassigned@demo.larkspur.ph', 'Ana Reyes'),
      ('11111111-1111-4111-8111-111111111104'::uuid, 'viewer@demo.larkspur.ph',     'Ben Ocampo'),
      ('11111111-1111-4111-8111-111111111105'::uuid, 'other@demo.larkspur.ph',      'Liza Navarro')
    ) as t(id, email, full_name)
  loop
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change, email_change_token_new, email_change_token_current
    ) values (
      '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
      u.email, extensions.crypt('demo-password-123', extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('full_name', u.full_name),
      now(), now(), '', '', '', '', ''
    ) on conflict (id) do nothing;

    insert into auth.identities (
      id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at
    ) values (
      gen_random_uuid(), u.id, u.id::text, 'email',
      jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
      now(), now(), now()
    ) on conflict do nothing;
  end loop;
exception when others then
  raise warning 'demo auth user seeding failed (local login may not work): %', sqlerrm;
end $$;

-- Build the tenancy through the same RPCs the app uses. auth.uid() resolves
-- from request.jwt.claims, which we set per persona.
do $$
declare
  v_firm_a uuid;
  v_firm_b uuid;
  v_a1     uuid;
  v_a2     uuid;
  v_staff_membership uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', '11111111-1111-4111-8111-111111111101', 'role', 'authenticated')::text, false);
  v_firm_a := public.create_firm('Dela Cruz & Co, CPAs');

  insert into public.clients (firm_id, name, code, tin, reporting_basis, fiscal_year_end_month)
  values (v_firm_a, 'Sampaguita Trading', 'SAMPA', '123-456-789-000', 'accrual', 12)
  returning id into v_a1;
  insert into public.clients (firm_id, name, code, reporting_basis, fiscal_year_end_month)
  values (v_firm_a, 'Narra Furniture Works', 'NARRA', 'accrual', 6)
  returning id into v_a2;

  v_staff_membership := public.add_member(v_firm_a, 'staff@demo.larkspur.ph', 'staff');
  perform public.set_client_assignments(v_staff_membership, array[v_a1]);
  perform public.add_member(v_firm_a, 'unassigned@demo.larkspur.ph', 'staff');
  perform public.add_member(v_firm_a, 'viewer@demo.larkspur.ph', 'client_viewer', v_a1);

  perform set_config('request.jwt.claims',
    json_build_object('sub', '11111111-1111-4111-8111-111111111105', 'role', 'authenticated')::text, false);
  v_firm_b := public.create_firm('Bayanihan Bookkeepers');
  insert into public.clients (firm_id, name) values (v_firm_b, 'Mango Grove Cafe');

  perform set_config('request.jwt.claims', '', false);
exception when others then
  raise warning 'demo tenancy seeding failed: %', sqlerrm;
end $$;
