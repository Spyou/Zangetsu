-- VPS-side watch-history change journal for the temporary old/new app bridge.
-- Keep this schema private; only the bridge process may read these events.
create table if not exists sync_private.history_bridge_events (
  id bigint generated always as identity primary key,
  user_key text not null,
  profile_id text,
  source_id text not null,
  show_id text not null,
  operation text not null check (operation in ('upsert', 'delete')),
  row_data jsonb,
  changed_at timestamptz not null default clock_timestamp()
);

create index if not exists history_bridge_events_user_id
  on sync_private.history_bridge_events (user_key, id);
revoke all on sync_private.history_bridge_events from public, authenticated;

create table if not exists sync_private.history_bridge_cursors (
  origin text primary key check (origin in ('supabase', 'vps')),
  last_id bigint not null default 0
);
create table if not exists sync_private.history_bridge_latest (
  user_key text not null,
  profile_scope text not null default '',
  source_id text not null,
  show_id text not null,
  origin text not null check (origin in ('supabase', 'vps')),
  event_id bigint not null,
  operation text not null check (operation in ('upsert', 'delete')),
  changed_at timestamptz not null,
  row_data jsonb,
  primary key (user_key, profile_scope, source_id, show_id)
);
revoke all on sync_private.history_bridge_cursors,
  sync_private.history_bridge_latest from public, authenticated;

create or replace function sync_private.capture_history_bridge_change()
returns trigger
language plpgsql
security definer
set search_path = sync_private, pg_temp
as $$
declare
  changed_row jsonb;
begin
  -- The bridge writes to the destination with this flag to avoid echo loops.
  -- Only its direct database connection may suppress a journal event.
  if session_user in ('postgres', 'AniAura_bridge')
      and current_setting('AniAura.bridge_replay', true) = 'on' then
    return coalesce(new, old);
  end if;
  if tg_op = 'UPDATE' and to_jsonb(new) = to_jsonb(old) then
    return new;
  end if;
  changed_row := to_jsonb(case when tg_op = 'DELETE' then old else new end);
  insert into sync_private.history_bridge_events (
    user_key, profile_id, source_id, show_id, operation, row_data
  ) values (
    changed_row ->> 'user_key',
    changed_row ->> 'profile_id',
    changed_row ->> 'source_id',
    changed_row ->> 'show_id',
    case when tg_op = 'DELETE' then 'delete' else 'upsert' end,
    case when tg_op = 'DELETE' then null else changed_row end
  );
  return coalesce(new, old);
end;
$$;
revoke all on function sync_private.capture_history_bridge_change()
  from public, authenticated;

drop trigger if exists bridge_history_changes on sync_api.history;
create trigger bridge_history_changes
after insert or update or delete on sync_api.history
for each row execute function sync_private.capture_history_bridge_change();

drop trigger if exists bridge_profile_history_changes on sync_api.profile_history;
create trigger bridge_profile_history_changes
after insert or update or delete on sync_api.profile_history
for each row execute function sync_private.capture_history_bridge_change();
