-- Run with psql -v ON_ERROR_STOP=1 after 001_watch_history.sql. The transaction
-- rolls back all test rows. This tests database policy, not JWT signatures.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"test-user-a"}', true);
insert into sync_api.viewer_profiles (user_key, profile_id, name)
values ('test-user-a', 'child', 'Viewer');

insert into sync_api.history
  (user_key, source_id, show_id, episode_number, updated_at)
values ('test-user-a', 'source', 'show', 12.5, 100);
insert into sync_api.history (user_key, source_id, show_id, updated_at)
values ('test-user-a', 'source', 'show', 90)
on conflict (user_key, source_id, show_id)
do update set updated_at = excluded.updated_at;

do $$
begin
  if (select updated_at from sync_api.history where show_id = 'show') <> 100 then
    raise exception 'older upsert replaced newer watch progress';
  end if;
  if (select episode_number from sync_api.history where show_id = 'show') <> 12.5 then
    raise exception 'fractional episode number was lost';
  end if;
end;
$$;

insert into sync_api.profile_history
  (user_key, profile_id, source_id, show_id, updated_at)
values ('test-user-a', 'child', 'source', 'show', 100);

select set_config('request.jwt.claims', '{"sub":"test-user-b"}', true);
do $$
begin
  if exists (select 1 from sync_api.history)
    or exists (select 1 from sync_api.profile_history) then
    raise exception 'cross-user watch history was readable';
  end if;
end;
$$;

delete from sync_api.history where user_key = 'test-user-a';
update sync_api.profile_history set updated_at = 500
where user_key = 'test-user-a';

do $$
begin
  begin
    insert into sync_api.history (user_key, source_id, show_id)
    values ('test-user-a', 'source', 'other');
    raise exception 'cross-user insert unexpectedly succeeded';
  exception when insufficient_privilege then
    null;
  end;
end;
$$;

do $$
begin
  begin
    insert into sync_api.profile_history
      (user_key, profile_id, source_id, show_id)
    values ('test-user-a', 'child', 'source', 'other');
    raise exception 'cross-user profile insert unexpectedly succeeded';
  exception when insufficient_privilege then
    null;
  end;
end;
$$;

select set_config('request.jwt.claims', '{}', true);
do $$
begin
  begin
    insert into sync_api.history (user_key, source_id, show_id)
    values ('test-user-a', 'source', 'without-token');
    raise exception 'a token without a user id unexpectedly wrote history';
  exception when insufficient_privilege then
    null;
  end;
end;
$$;

select set_config('request.jwt.claims', '{"sub":"test-user-a"}', true);
do $$
begin
  if (select updated_at from sync_api.history where show_id = 'show') <> 100
    or (select updated_at from sync_api.profile_history
        where show_id = 'show') <> 100 then
    raise exception 'another user changed or deleted watch history';
  end if;
end;
$$;
rollback;
