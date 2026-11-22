-- Temporary old-version bridge; no existing library row is modified.
create schema if not exists sync_private;
revoke all on schema sync_private from public;

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
revoke all on sync_private.library_bridge_events from public;
revoke all on sync_private.library_bridge_events from authenticated;

create or replace function sync_private.capture_library_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  row_data jsonb := case when tg_op = 'DELETE' then to_jsonb(old)
    else to_jsonb(new) end;
  row_key jsonb;
begin
  if session_user = 'postgres'
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
    execute format('drop trigger if exists library_bridge_capture on public.%I',
      table_name);
    execute format('create trigger library_bridge_capture '
      'after insert or update or delete on public.%I '
      'for each row execute function sync_private.capture_library_change()',
      table_name);
  end loop;
end;
$$;
