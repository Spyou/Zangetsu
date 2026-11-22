begin;
insert into public.mylist (user_key, source_id, item_id)
values ('source-library-test', 'source', 'item');
insert into public.list_categories (user_key, id, name)
values ('source-library-test',
  '00000000-0000-4000-8000-000000000003', 'Test');
delete from public.mylist where user_key = 'source-library-test';
do $$
begin
  if (select count(*) from sync_private.library_bridge_events
      where user_key = 'source-library-test') <> 3 then
    raise exception 'source edits did not enter the library journal';
  end if;
  if has_schema_privilege('authenticated', 'sync_private', 'USAGE')
      or has_table_privilege('authenticated',
        'sync_private.library_bridge_events', 'SELECT') then
    raise exception 'app role can read private library journal';
  end if;
end;
$$;

select set_config('AniAura.bridge_replay', 'on', true);
insert into public.profile_mylist
  (user_key, profile_id, source_id, item_id)
values ('source-library-test', 'viewer', 'source', 'item');
do $$
begin
  if (select count(*) from sync_private.library_bridge_events
      where user_key = 'source-library-test') <> 3 then
    raise exception 'source replay echoed into its journal';
  end if;
end;
$$;
rollback;
