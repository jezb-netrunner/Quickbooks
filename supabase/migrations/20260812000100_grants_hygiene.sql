-- Grants hygiene: flip the database to default-closed BEFORE any table exists.
--
-- Supabase grants ALL on public objects to anon + authenticated by default, and
-- default privileges re-grant it on every future object. RLS alone is one wall;
-- these revokes are the second, independent wall: a permissive-policy typo and a
-- forgotten-RLS table become two separate failures instead of one silent leak.
-- Meta-tests in /supabase/tests/001_meta.sql tripwire both, forever.

-- Existing objects (idempotent: revoking nothing is a no-op)
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated, public;

-- Future objects: born closed. Migrations always run as the same role (postgres,
-- via supabase db push / db reset), so these default-privilege changes attach to
-- everything later migrations create.
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated, public;

-- Nobody creates objects in public but migrations.
revoke create on schema public from public;

-- Private schema for policy helpers and trigger functions. It is NOT in
-- PostgREST's exposed schemas (see config.toml [api].schemas), so nothing in it
-- is ever a REST endpoint; authenticated needs USAGE so policies evaluated as
-- that role can call the helpers we explicitly grant EXECUTE on.
create schema if not exists app;
grant usage on schema app to authenticated;
alter default privileges in schema app revoke execute on functions from anon, authenticated, public;
