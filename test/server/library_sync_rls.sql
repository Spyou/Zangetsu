-- Run against the stage in one transaction; no test rows survive.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"library-test-a"}', true);
insert into sync_api.viewer_profiles (user_key, profile_id, name)
values ('library-test-a', 'viewer', 'Viewer');

insert into sync_api.mylist (user_key, source_id, item_id, title)
values ('library-test-a', 'source', 'item', 'Test');
do $$
begin
  if (select sync_version from sync_api.mylist where item_id = 'item') <> 1
      or (select version from sync_api.mylist_sync_clock
          where user_key = 'library-test-a' and profile_scope = '') <> 1 then
    raise exception 'initial list version was not assigned';
  end if;
end;
$$;

update sync_api.mylist set status = 'watching' where item_id = 'item';
delete from sync_api.mylist where item_id = 'item';
do $$
begin
  if (select sync_version from sync_api.mylist_sync_tombstones
      where item_id = 'item') <> 3 then
    raise exception 'deletion marker did not advance';
  end if;
end;
$$;

insert into sync_api.mylist (user_key, source_id, item_id, title)
values ('library-test-a', 'source', 'item', 'Restored');
do $$
begin
  if exists (select 1 from sync_api.mylist_sync_tombstones
      where item_id = 'item') then
    raise exception 're-added item retained a tombstone';
  end if;
end;
$$;

insert into sync_api.profile_mylist
  (user_key, profile_id, source_id, item_id, title)
values ('library-test-a', 'viewer', 'source', 'profile-item', 'Test');
insert into sync_api.list_categories (id, user_key, name)
values ('00000000-0000-4000-8000-000000000001', 'library-test-a', 'Favorites');
insert into sync_api.mylist_categories
  (user_key, source_id, item_id, category_id)
values ('library-test-a', 'source', 'item',
  '00000000-0000-4000-8000-000000000001');

select set_config('request.jwt.claims', '{"sub":"library-test-b"}', true);
do $$
begin
  if exists (select 1 from sync_api.mylist)
      or exists (select 1 from sync_api.profile_mylist)
      or exists (select 1 from sync_api.list_categories)
      or exists (select 1 from sync_api.mylist_categories)
      or exists (select 1 from sync_api.mylist_sync_clock) then
    raise exception 'another user could read library data';
  end if;
  begin
    insert into sync_api.mylist (user_key, source_id, item_id)
    values ('library-test-a', 'source', 'denied');
    raise exception 'cross-user insert unexpectedly succeeded';
  exception when insufficient_privilege then
    null;
  end;
end;
$$;
rollback;
