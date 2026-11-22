-- One transaction: ordinary app edits emit events, replay does not.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"content-journal-test"}', true);
insert into sync_api.reading_history (user_key, source_id, show_id, updated_ms)
values ('content-journal-test', 'source', 'show', 1);
insert into sync_api.viewer_profiles (user_key, profile_id, name)
values ('content-journal-test', 'viewer', 'Viewer');
insert into sync_api.backups (user_key, payload)
values ('content-journal-test', '{}');
update sync_api.reading_history set pos = 5
  where user_key = 'content-journal-test';
delete from sync_api.reading_history where user_key = 'content-journal-test';
reset role;

do $$
begin
  if (select count(*) from sync_private.content_bridge_events
      where user_key = 'content-journal-test') <> 5 then
    raise exception 'content inserts, update, and delete were not journaled';
  end if;
  if not exists (select 1 from sync_private.content_bridge_events
      where user_key = 'content-journal-test' and operation = 'delete'
        and table_name = 'reading_history') then
    raise exception 'reading delete did not produce a tombstone event';
  end if;
end;
$$;

set session authorization AniAura_bridge;
select set_config('AniAura.bridge_replay', 'on', true);
insert into sync_api.profile_reading_history
  (user_key, profile_id, source_id, show_id)
values ('content-journal-test', 'viewer', 'source', 'show');
do $$
begin
  if (select count(*) from sync_private.content_bridge_events
      where user_key = 'content-journal-test') <> 5 then
    raise exception 'bridge replay echoed into the journal';
  end if;
end;
$$;
rollback;
