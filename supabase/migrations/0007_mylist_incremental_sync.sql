-- Versioned My List changes let clients fetch only rows changed since their
-- last successful sync. Existing list rows stay in place and start at version 0.
alter table public.mylist
  add column if not exists sync_id bigint generated always as identity,
  add column if not exists sync_version bigint not null default 0;

alter table public.profile_mylist
  add column if not exists sync_id bigint generated always as identity,
  add column if not exists sync_version bigint not null default 0;

create unique index if not exists mylist_user_sync_id_unique
  on public.mylist(user_key, sync_id);
create unique index if not exists profile_mylist_user_sync_id_unique
  on public.profile_mylist(user_key, profile_id, sync_id);
create index if not exists mylist_sync_version_idx
  on public.mylist(user_key, sync_version);
create index if not exists profile_mylist_sync_version_idx
  on public.profile_mylist(user_key, profile_id, sync_version);

create table if not exists public.mylist_sync_clock (
  user_key text not null,
  profile_scope text not null default '',
  version bigint not null default 0,
  primary key (user_key, profile_scope)
);

create table if not exists public.mylist_sync_tombstones (
  user_key text not null,
  profile_scope text not null default '',
  source_id text not null,
  item_id text not null,
  sync_version bigint not null,
  primary key (user_key, profile_scope, source_id, item_id)
);
create index if not exists mylist_sync_tombstones_version_idx
  on public.mylist_sync_tombstones(user_key, profile_scope, sync_version);

alter table public.mylist_sync_clock enable row level security;
alter table public.mylist_sync_tombstones enable row level security;
drop policy if exists mylist_sync_clock_read_own on public.mylist_sync_clock;
create policy mylist_sync_clock_read_own on public.mylist_sync_clock
  for select using (user_key = auth.uid()::text);
drop policy if exists mylist_sync_tombstones_read_own
  on public.mylist_sync_tombstones;
create policy mylist_sync_tombstones_read_own on public.mylist_sync_tombstones
  for select using (user_key = auth.uid()::text);
grant select on public.mylist_sync_clock, public.mylist_sync_tombstones
  to authenticated;

create or replace function public.bump_mylist_sync_version()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  row_data jsonb;
  owner_key text;
  profile_key text;
  next_version bigint;
begin
  row_data := to_jsonb(new);
  owner_key := row_data ->> 'user_key';
  profile_key := coalesce(row_data ->> 'profile_id', '');

  insert into public.mylist_sync_clock(user_key, profile_scope, version)
  values (owner_key, profile_key, 1)
  on conflict (user_key, profile_scope) do update
    set version = public.mylist_sync_clock.version + 1
  returning version into next_version;

  new.sync_version := next_version;
  return new;
end;
$$;

create or replace function public.clear_mylist_sync_tombstone()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  row_data jsonb;
begin
  row_data := to_jsonb(new);
  delete from public.mylist_sync_tombstones
  where user_key = row_data ->> 'user_key'
    and profile_scope = coalesce(row_data ->> 'profile_id', '')
    and source_id = row_data ->> 'source_id'
    and item_id = row_data ->> 'item_id';
  return new;
end;
$$;

create or replace function public.record_mylist_sync_delete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  row_data jsonb;
  owner_key text;
  profile_key text;
  source_key text;
  item_key text;
  next_version bigint;
begin
  -- Removing a viewer profile cascades its list; the profile itself is gone,
  -- so those rows must not leave permanent per-item deletion markers behind.
  if pg_trigger_depth() > 1 then
    return old;
  end if;

  row_data := to_jsonb(old);
  owner_key := row_data ->> 'user_key';
  profile_key := coalesce(row_data ->> 'profile_id', '');
  source_key := row_data ->> 'source_id';
  item_key := row_data ->> 'item_id';

  insert into public.mylist_sync_clock(user_key, profile_scope, version)
  values (owner_key, profile_key, 1)
  on conflict (user_key, profile_scope) do update
    set version = public.mylist_sync_clock.version + 1
  returning version into next_version;

  insert into public.mylist_sync_tombstones(
    user_key, profile_scope, source_id, item_id, sync_version
  ) values (owner_key, profile_key, source_key, item_key, next_version)
  on conflict (user_key, profile_scope, source_id, item_id) do update
    set sync_version = excluded.sync_version;
  return old;
end;
$$;

drop trigger if exists mylist_sync_version on public.mylist;
create trigger mylist_sync_version
before insert or update on public.mylist
for each row execute function public.bump_mylist_sync_version();
drop trigger if exists mylist_sync_clear_tombstone on public.mylist;
create trigger mylist_sync_clear_tombstone
after insert or update on public.mylist
for each row execute function public.clear_mylist_sync_tombstone();
drop trigger if exists mylist_sync_delete on public.mylist;
create trigger mylist_sync_delete
after delete on public.mylist
for each row execute function public.record_mylist_sync_delete();

drop trigger if exists profile_mylist_sync_version on public.profile_mylist;
create trigger profile_mylist_sync_version
before insert or update on public.profile_mylist
for each row execute function public.bump_mylist_sync_version();
drop trigger if exists profile_mylist_sync_clear_tombstone on public.profile_mylist;
create trigger profile_mylist_sync_clear_tombstone
after insert or update on public.profile_mylist
for each row execute function public.clear_mylist_sync_tombstone();
drop trigger if exists profile_mylist_sync_delete on public.profile_mylist;
create trigger profile_mylist_sync_delete
after delete on public.profile_mylist
for each row execute function public.record_mylist_sync_delete();

notify pgrst, 'reload schema';
