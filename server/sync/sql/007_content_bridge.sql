-- Ordered journal for reading history, viewer profiles, and backups. Old app
-- versions still write to Supabase; this and its Supabase twin keep both
-- databases identical while the rollout is in flight.
create table if not exists sync_private.content_bridge_events (
  id bigint generated always as identity primary key,
  table_name text not null check (table_name in (
    'reading_history', 'profile_reading_history',
    'viewer_profiles', 'backups')),
  user_key text not null,
  profile_scope text not null default '',
  key_data jsonb not null,
  operation text not null check (operation in ('upsert', 'delete')),
  row_data jsonb,
  changed_at timestamptz not null default clock_timestamp()
);
create table if not exists sync_private.content_bridge_cursors (
  origin text primary key check (origin in ('supabase', 'vps')),
  last_id bigint not null default 0
);
create table if not exists sync_private.content_bridge_latest (
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

create or replace function sync_private.capture_content_change()
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
  if tg_table_name in ('reading_history', 'profile_reading_history') then
    row_key := jsonb_build_object('source_id', row_data ->> 'source_id',
      'show_id', row_data ->> 'show_id');
  elsif tg_table_name = 'viewer_profiles' then
    row_key := jsonb_build_object('profile_id', row_data ->> 'profile_id');
  elsif tg_table_name = 'backups' then
    row_key := '{}'::jsonb;
  else
    raise exception 'unexpected content table %', tg_table_name;
  end if;
  insert into sync_private.content_bridge_events
    (table_name, user_key, profile_scope, key_data, operation, row_data)
  values (tg_table_name, row_data ->> 'user_key',
    coalesce(row_data ->> 'profile_id', ''), row_key,
    case when tg_op = 'DELETE' then 'delete' else 'upsert' end,
    case when tg_op = 'DELETE' then null else row_data end);
  return coalesce(new, old);
end;
$$;
revoke all on function sync_private.capture_content_change() from public;

do $$
declare table_name text;
begin
  foreach table_name in array array[
    'reading_history', 'profile_reading_history', 'viewer_profiles', 'backups'
  ] loop
    execute format('drop trigger if exists content_bridge_capture on sync_api.%I',
      table_name);
    execute format('create trigger content_bridge_capture '
      'after insert or update or delete on sync_api.%I '
      'for each row execute function sync_private.capture_content_change()',
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
grant select, delete on sync_private.content_bridge_events to AniAura_bridge;
grant select, insert, update, delete on
  sync_private.content_bridge_cursors,
  sync_private.content_bridge_latest to AniAura_bridge;
