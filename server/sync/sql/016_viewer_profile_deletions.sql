create table if not exists sync_api.viewer_profile_deletions (
  user_key text not null,
  profile_id text not null,
  primary key (user_key, profile_id)
);

alter table sync_api.viewer_profile_deletions enable row level security;
create policy own_rows on sync_api.viewer_profile_deletions
  for select to authenticated using (user_key = sync_private.jwt_user_key());
grant select on sync_api.viewer_profile_deletions to authenticated;

create function sync_private.record_viewer_profile_deletion()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into sync_api.viewer_profile_deletions values (old.user_key, old.profile_id)
  on conflict do nothing;
  return old;
end;
$$;
revoke all on function sync_private.record_viewer_profile_deletion() from public;

create trigger record_viewer_profile_deletion
after delete on sync_api.viewer_profiles
for each row when (old.profile_id <> 'default')
execute function sync_private.record_viewer_profile_deletion();

create function sync_private.reject_deleted_viewer_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (
    select 1 from sync_api.viewer_profile_deletions
    where user_key = new.user_key and profile_id = new.profile_id
  ) then
    raise exception 'This viewer profile was deleted' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function sync_private.reject_deleted_viewer_profile() from public;

create trigger reject_deleted_viewer_profile
after insert or update on sync_api.viewer_profiles
for each row execute function sync_private.reject_deleted_viewer_profile();

notify pgrst, 'reload schema';
