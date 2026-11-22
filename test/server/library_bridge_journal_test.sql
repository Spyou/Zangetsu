-- One transaction: ordinary app edits emit events, replay does not.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"library-journal-test"}', true);
insert into sync_api.mylist (user_key, source_id, item_id)
values ('library-journal-test', 'source', 'item');
insert into sync_api.list_categories (id, user_key, name)
values ('00000000-0000-4000-8000-000000000002',
  'library-journal-test', 'Favorites');
insert into sync_api.mylist_categories
  (user_key, source_id, item_id, category_id)
values ('library-journal-test', 'source', 'item',
  '00000000-0000-4000-8000-000000000002');
delete from sync_api.mylist where user_key = 'library-journal-test';
reset role;

do $$
begin
  if (select count(*) from sync_private.library_bridge_events
      where user_key = 'library-journal-test') <> 4 then
    raise exception 'library insert, category, assignment, delete were not journaled';
  end if;
  if not exists (select 1 from sync_private.library_bridge_events
      where user_key = 'library-journal-test' and operation = 'delete'
        and table_name = 'mylist') then
    raise exception 'list delete did not produce a tombstone event';
  end if;
end;
$$;

set session authorization AniAura_bridge;
select set_config('AniAura.bridge_replay', 'on', true);
insert into sync_api.profile_mylist
  (user_key, profile_id, source_id, item_id)
values ('library-journal-test', 'viewer', 'source', 'profile-item');
do $$
begin
  if (select count(*) from sync_private.library_bridge_events
      where user_key = 'library-journal-test') <> 4 then
    raise exception 'bridge replay echoed into the journal';
  end if;
end;
$$;
rollback;
