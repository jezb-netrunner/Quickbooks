-- profiles: a public mirror of auth.users, synced by trigger.
-- Exists so admins can look users up by email (add_member) and later phases can
-- show "prepared by <name>" — without ever exposing auth.users to the API.

create table if not exists public.profiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  full_name   text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Non-unique on purpose: auth.users owns email uniqueness; a mirrored unique
-- index could fight sync ordering on email changes.
create index if not exists profiles_email_idx on public.profiles (lower(email));

-- Shared updated_at maintainer used by every mutable table.
create or replace function app.set_updated_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- Sync trigger. Exception-hardened: a failure here must never block a signup —
-- the mirror can be repaired; a broken auth flow cannot.
create or replace function app.handle_new_user() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.profiles (user_id, email, full_name)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'full_name', '')
  )
  on conflict (user_id) do update
    set email = excluded.email,
        updated_at = now();
  return new;
exception when others then
  raise warning 'profiles sync failed for auth user %: %', new.id, sqlerrm;
  return new;
end $$;

drop trigger if exists trg_auth_users_profile_sync on auth.users;
create trigger trg_auth_users_profile_sync
  after insert or update of email on auth.users
  for each row execute function app.handle_new_user();

drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute function app.set_updated_at();
