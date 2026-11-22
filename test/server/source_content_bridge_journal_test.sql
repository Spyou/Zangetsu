begin;
insert into public.reading_history (user_key, source_id, show_id)
values ('source-content-test', 'source', 'show');
insert into public.viewer_profiles (user_key, profile_id, name)
values ('source-content-test', 'viewer', 'Viewer');
insert into public.backups (user_key, payload)
values ('source-content-test', '{}');
delete from public.reading_history where user_key = 'source-content-test';
do $$
begin
  if (select count(*) from sync_private.content_bridge_events
      where user_key = 'source-content-test') <> 4 then
    raise exception 'source edits did not enter the content journal';
  end if;
  if has_schema_privilege('authenticated', 'sync_private', 'USAGE')
      or has_table_privilege('authenticated',
        'sync_private.content_bridge_events', 'SELECT') then
    raise exception 'app role can read the private content journal';
  end if;
end;
$$;

select set_config('AniAura.bridge_replay', 'on', true);
insert into public.profile_reading_history
  (user_key, profile_id, source_id, show_id)
values ('source-content-test', 'viewer', 'source', 'show');
do $$
begin
  if (select count(*) from sync_private.content_bridge_events
      where user_key = 'source-content-test') <> 4 then
    raise exception 'source replay echoed into its journal';
  end if;
end;
$$;
rollback;
