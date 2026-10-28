-- Run against the stage in one transaction; no test rows survive.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"content-test-a"}', true);

insert into sync_api.viewer_profiles (user_key, profile_id, name)
values ('content-test-a', 'viewer', 'Viewer');
insert into sync_api.reading_history
  (user_key, source_id, show_id, title, updated_ms, type)
values ('content-test-a', 'source', 'show', 'Test', 1, 'manga');
insert into sync_api.profile_reading_history
  (user_key, profile_id, source_id, show_id, title, updated_ms)
values ('content-test-a', 'viewer', 'source', 'show', 'Test', 1);
insert into sync_api.backups (user_key, payload)
values ('content-test-a', '{}');

select set_config('request.jwt.claims', '{"sub":"content-test-b"}', true);
do $$
begin
  if exists (select 1 from sync_api.reading_history)
      or exists (select 1 from sync_api.profile_reading_history)
      or exists (select 1 from sync_api.viewer_profiles)
      or exists (select 1 from sync_api.backups) then
    raise exception 'another user could read content data';
  end if;
  begin
    insert into sync_api.reading_history (user_key, source_id, show_id)
    values ('content-test-a', 'source', 'denied');
    raise exception 'cross-user insert unexpectedly succeeded';
  exception when insufficient_privilege then
    null;
  end;
end;
$$;

-- The four-profile cap must match Supabase exactly.
select set_config('request.jwt.claims', '{"sub":"content-test-cap"}', true);
insert into sync_api.viewer_profiles (user_key, profile_id, name) values
  ('content-test-cap', 'one', 'One'),
  ('content-test-cap', 'two', 'Two'),
  ('content-test-cap', 'three', 'Three'),
  ('content-test-cap', 'four', 'Four');
do $$
begin
  insert into sync_api.viewer_profiles (user_key, profile_id, name)
  values ('content-test-cap', 'five', 'Five');
  raise exception 'a fifth profile was accepted';
exception when raise_exception then
  if position('four profiles' in sqlerrm) = 0 then
    raise;
  end if;
end;
$$;
rollback;
