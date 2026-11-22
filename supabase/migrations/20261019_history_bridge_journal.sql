-- Private change journal for a temporary Supabase-to-VPS watch-history bridge.
-- It does not alter the app's history rows or their existing RLS policies.
create schema if not exists sync_private;
revoke all on schema sync_private from public;

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
revoke all on sync_private.history_bridge_events from public;
revoke all on sequence sync_private.history_bridge_events_id_seq from public;

create or replace function sync_private.capture_history_bridge_change()
returns trigger
language plpgsql
security definer
set search_path = sync_private, pg_temp
as $$
declare
  changed_row jsonb;
begin
  -- Only the bridge's direct postgres connection can suppress echo events.
  if session_user = 'postgres'
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
  from public;

drop trigger if exists bridge_history_changes on public.history;
create trigger bridge_history_changes
after insert or update or delete on public.history
for each row execute function sync_private.capture_history_bridge_change();

drop trigger if exists bridge_profile_history_changes on public.profile_history;
create trigger bridge_profile_history_changes
after insert or update or delete on public.profile_history
for each row execute function sync_private.capture_history_bridge_change();
