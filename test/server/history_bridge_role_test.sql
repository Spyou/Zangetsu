-- The bridge has only the private journal/state and history table permissions.
begin;
set local role AniAura_bridge;
select count(*) from sync_private.history_bridge_events;
delete from sync_private.history_bridge_events where id = -1;
select count(*) from sync_private.history_bridge_cursors;
select count(*) from sync_private.history_bridge_latest;
select count(*) from sync_api.history;
select count(*) from sync_api.profile_history;
do $$
declare
  private_count bigint;
begin
  begin
    select count(*) into private_count from pg_catalog.pg_authid;
    raise exception 'bridge unexpectedly read auth secrets';
  exception when insufficient_privilege then
    null;
  end;
end;
$$;
rollback;
