-- Structural tripwires. These five make "forgot the rule on a Phase-N object"
-- a red build forever — they scan the catalog, not a fixture.
begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(6);

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
