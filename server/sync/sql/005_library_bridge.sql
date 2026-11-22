-- Ordered journal for the six user-edited library tables. The derived sync
-- clock and tombstones are maintained by each database's own list triggers.
create table if not exists sync_private.library_bridge_events (
  id bigint generated always as identity primary key,
  table_name text not null check (table_name in (
    'mylist', 'profile_mylist', 'list_categories',
    'profile_list_categories', 'mylist_categories',
    'profile_mylist_categories')),
  user_key text not null,
  profile_scope text not null default '',
  key_data jsonb not null,
  operation text not null check (operation in ('upsert', 'delete')),
  row_data jsonb,
  changed_at timestamptz not null default clock_timestamp()
);
create table if not exists sync_private.library_bridge_cursors (
  origin text primary key check (origin in ('supabase', 'vps')),
  last_id bigint not null default 0
);
create table if not exists sync_private.library_bridge_latest (
  table_name text not null,
  user_key text not null,
  profile_scope text not null,
  key_text text not null,
  origin text not null,
  event_id bigint not null,
  operation text not null,
  row_data jsonb,
  changed_at timestamptz not null,
  primary key (table_name, user_key, profile_scope, key_text)
);

create or replace function sync_private.capture_library_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  row_data jsonb := case when tg_op = 'DELETE' then to_jsonb(old)
    else to_jsonb(new) end;
  row_key jsonb;
begin
  if session_user = 'AniAura_bridge'
      and current_setting('AniAura.bridge_replay', true) = 'on' then
    return coalesce(new, old);
  end if;
  if tg_table_name in ('mylist', 'profile_mylist') then
    row_key := jsonb_build_object('source_id', row_data ->> 'source_id',
      'item_id', row_data ->> 'item_id');
  elsif tg_table_name in ('list_categories', 'profile_list_categories') then
    row_key := jsonb_build_object('id', row_data ->> 'id');
  elsif tg_table_name in ('mylist_categories', 'profile_mylist_categories') then
    row_key := jsonb_build_object('source_id', row_data ->> 'source_id',
      'item_id', row_data ->> 'item_id',
      'category_id', row_data ->> 'category_id');
  else
    raise exception 'unexpected library table %', tg_table_name;
  end if;
  insert into sync_private.library_bridge_events
    (table_name, user_key, profile_scope, key_data, operation, row_data)
  values (tg_table_name, row_data ->> 'user_key',
    coalesce(row_data ->> 'profile_id', ''), row_key,
    case when tg_op = 'DELETE' then 'delete' else 'upsert' end,
    case when tg_op = 'DELETE' then null else row_data end);
  return coalesce(new, old);
end;
$$;
revoke all on function sync_private.capture_library_change() from public;

do $$
declare table_name text;
begin
  foreach table_name in array array[
    'mylist', 'profile_mylist', 'list_categories',
    'profile_list_categories', 'mylist_categories',
    'profile_mylist_categories'
  ] loop
    execute format('drop trigger if exists library_bridge_capture on sync_api.%I',
      table_name);
    execute format('create trigger library_bridge_capture '
      'after insert or update or delete on sync_api.%I '
      'for each row execute function sync_private.capture_library_change()',
      table_name);
    execute format('grant select, insert, update, delete on sync_api.%I '
      'to AniAura_bridge', table_name);
    execute format('drop policy if exists bridge_rows on sync_api.%I',
      table_name);
    execute format('create policy bridge_rows on sync_api.%I for all '
      'to AniAura_bridge using (true) with check (true)', table_name);
  end loop;
end;
$$;
grant select, delete on sync_private.library_bridge_events to AniAura_bridge;
grant select, insert, update, delete on
  sync_private.library_bridge_cursors,
  sync_private.library_bridge_latest to AniAura_bridge;
grant select, insert, update, delete on
  sync_api.mylist_sync_clock,
  sync_api.mylist_sync_tombstones to AniAura_bridge;
drop policy if exists bridge_clock on sync_api.mylist_sync_clock;
create policy bridge_clock on sync_api.mylist_sync_clock for all
  to AniAura_bridge using (true) with check (true);
drop policy if exists bridge_tombstones on sync_api.mylist_sync_tombstones;
create policy bridge_tombstones on sync_api.mylist_sync_tombstones for all
  to AniAura_bridge using (true) with check (true);
