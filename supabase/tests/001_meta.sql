-- Structural tripwires. These five make "forgot the rule on a Phase-N object"
-- a red build forever — they scan the catalog, not a fixture.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(8);

select is_empty(
  $$ select c.relname
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity $$,
  'every table in public has row level security enabled'
);

select is_empty(
  $$ select n.nspname || '.' || p.proname
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'public') and p.prosecdef
       and (p.proconfig is null
            or not exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%')) $$,
  'every security definer function has a pinned search_path'
);

select is_empty(
  $$ select table_name, privilege_type
     from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'anon' $$,
  'anon holds zero table privileges in public'
);

select is_empty(
  $$ select routine_schema || '.' || routine_name
     from information_schema.role_routine_grants
     where routine_schema in ('public', 'app') and grantee = 'anon' $$,
  'anon holds zero function privileges in public/app'
);

-- P4-08: anon is a member of PUBLIC, so a GRANT ... TO PUBLIC (grantee='PUBLIC')
-- slips past the anon-only checks above (this is how P4-07 hid). Tripwire the
-- API-EXPOSED schema explicitly. Scope is 'public' only: PostgREST exposes just
-- the public schema, so a PUBLIC grant there is anon-reachable, whereas the app
-- schema is never a REST endpoint. (App-schema PUBLIC grants exist but are not
-- reachable — see docs/audit-2026-08.md "Found during remediation".)
select is_empty(
  $$ select table_name || ' ' || privilege_type
     from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'PUBLIC' $$,
  'PUBLIC holds zero table privileges in the exposed public schema'
);
select is_empty(
  $$ select routine_name
     from information_schema.role_routine_grants
     where routine_schema = 'public' and grantee = 'PUBLIC' $$,
  'PUBLIC holds zero function privileges in the exposed public schema'
);

select is_empty(
  $$ select c.relname
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'v'
       and coalesce(
             (select option_value::boolean
              from pg_options_to_table(c.reloptions)
              where option_name = 'security_invoker'),
             false) is distinct from true $$,
  'every view in public is security_invoker (definer views silently bypass RLS)'
);

select is_empty(
  $$ select schemaname || '.' || tablename
     from pg_publication_tables
     where pubname = 'supabase_realtime' $$,
  'the realtime publication carries no tables (no realtime side channel)'
);

select * from finish();
rollback;
