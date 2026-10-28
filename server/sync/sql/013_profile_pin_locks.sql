-- Profile credentials stay private. Existing cloud rows are never rewritten.
create extension if not exists pgcrypto with schema sync_private;

create table if not exists sync_private.profile_pins (
  user_key text not null,
  profile_id text not null,
  pin_hash text not null,
  recovery_hash bytea not null,
  version bigint not null default 1,
  failures integer not null default 0,
  blocked_until timestamptz not null default '-infinity',
  primary key (user_key, profile_id)
);
alter table sync_private.profile_pins alter column version set default
  floor(extract(epoch from clock_timestamp()) * 1000000)::bigint;
create table if not exists sync_private.profile_pin_grants (
  user_key text not null,
  profile_id text not null,
  token_hash bytea not null,
  version bigint not null,
  expires_at timestamptz not null,
  primary key (user_key, profile_id, token_hash),
  foreign key (user_key, profile_id)
    references sync_private.profile_pins on delete cascade
);
create table if not exists sync_private.profile_pin_devices (
  user_key text not null,
  profile_id text not null,
  token_hash bytea not null,
  version bigint not null,
  expires_at timestamptz not null,
  primary key (user_key, profile_id, token_hash),
  foreign key (user_key, profile_id)
    references sync_private.profile_pins on delete cascade
);
revoke all on sync_private.profile_pins, sync_private.profile_pin_grants,
  sync_private.profile_pin_devices from public, authenticated;

create table if not exists sync_private.profile_pin_rates (
  rate_key text primary key,
  window_start timestamptz not null,
  requests integer not null
);
revoke all on sync_private.profile_pin_rates from public, authenticated;

create or replace function sync_private.allow_pin_request(rate_id text, request_limit integer)
returns boolean language plpgsql security definer set search_path = '' as $$
declare request_count integer;
begin
  insert into sync_private.profile_pin_rates(rate_key, window_start, requests)
    values (rate_id, clock_timestamp(), 1)
    on conflict (rate_key) do update set
      requests = case when profile_pin_rates.window_start < clock_timestamp() - interval '1 minute'
        then 1 else least(profile_pin_rates.requests + 1, request_limit + 1) end,
      window_start = case when profile_pin_rates.window_start < clock_timestamp() - interval '1 minute'
        then clock_timestamp() else profile_pin_rates.window_start end
    returning requests into request_count;
  return request_count <= request_limit;
end;
$$;
revoke all on function sync_private.allow_pin_request(text, integer) from public;

create or replace function sync_private.profile_has_access(owner_key text, viewer_id text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  revision bigint;
  tokens jsonb;
  token text;
begin
  if owner_key is distinct from sync_private.jwt_user_key() then return false; end if;
  select version into revision from sync_private.profile_pins
    where user_key = owner_key and profile_id = viewer_id;
  if not found then return true; end if;
  begin
    tokens := (nullif(current_setting('request.headers', true), '')::jsonb
      ->> 'x-profile-grants')::jsonb;
    token := tokens ->> viewer_id;
    if token is null or token !~ '^[0-9a-f]{64}$' then return false; end if;
  exception when others then return false;
  end;
  return exists (select 1 from sync_private.profile_pin_grants
    where user_key = owner_key and profile_id = viewer_id and version = revision
      and expires_at > statement_timestamp()
      and token_hash = sync_private.digest(token, 'sha256'));
end;
$$;

create or replace function sync_private.require_profile_access(owner_key text, viewer_id text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
  if owner_key is distinct from sync_private.jwt_user_key() then return false; end if;
  if not sync_private.profile_has_access(owner_key, viewer_id) then
    -- An explicit error prevents sync clients mistaking hidden rows for deletions.
    raise sqlstate 'PT403' using message = 'Profile unlock required';
  end if;
  return true;
end;
$$;

create or replace function sync_private.require_all_profile_access(owner_key text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare viewer_id text;
begin
  if owner_key is distinct from sync_private.jwt_user_key() then return false; end if;
  for viewer_id in select profile_id from sync_private.profile_pins where user_key = owner_key loop
    perform sync_private.require_profile_access(owner_key, viewer_id);
  end loop;
  return true;
end;
$$;
revoke all on function sync_private.profile_has_access(text, text),
  sync_private.require_profile_access(text, text),
  sync_private.require_all_profile_access(text) from public;
grant execute on function sync_private.require_profile_access(text, text),
  sync_private.require_all_profile_access(text) to authenticated;

-- Supabase JWT validation is still performed by PostgREST. No caller-supplied
-- account id or credential hash is accepted by this endpoint.
create or replace function sync_api.profile_lock(
  p_action text, p_profile_id text default null, p_pin text default null,
  p_new_pin text default null, p_secret text default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  owner_key text := sync_private.jwt_user_key();
  lock_row sync_private.profile_pins%rowtype;
  has_lock boolean;
  allowed boolean := false;
  token text;
  device_token text;
  recovery text;
  deadline timestamptz;
  response jsonb;
begin
  if owner_key is null then return jsonb_build_object('ok', false, 'error', 'sign_in_required'); end if;
  if p_action is null or p_action not in ('status', 'set', 'unlock', 'remove', 'recover',
    'device_enroll', 'device_unlock', 'device_remove', 'backup_access', 'asset_delete_access') then
    return jsonb_build_object('ok', false, 'error', 'invalid_action');
  end if;
  if p_action = 'backup_access' then
    perform sync_private.require_all_profile_access(owner_key);
    return jsonb_build_object('ok', true);
  end if;
  if p_action = 'asset_delete_access' then
    if p_secret is null or char_length(p_secret) > 128
        or left(p_secret, char_length('avatars/' || owner_key || '/')) <> 'avatars/' || owner_key || '/' then
      return jsonb_build_object('ok', false, 'error', 'invalid_request');
    end if;
    for token in select v.profile_id from sync_api.viewer_profiles v
      where v.user_key = owner_key and (
        right(split_part(v.photo_url, '?', 1), char_length(p_secret) + 1) = '/' || p_secret or
        right(split_part(v.cover_url, '?', 1), char_length(p_secret) + 1) = '/' || p_secret)
    loop
      perform sync_private.require_profile_access(owner_key, token);
    end loop;
    return jsonb_build_object('ok', true);
  end if;
  if p_action = 'status' and p_profile_id is null then
    return jsonb_build_object('ok', true, 'profiles', (
      select coalesce(jsonb_agg(jsonb_build_object('profile_id', ids.profile_id,
        'locked', pins.profile_id is not null, 'version', pins.version)), '[]'::jsonb)
      from (select 'default'::text as profile_id union
        select v.profile_id from sync_api.viewer_profiles v where v.user_key = owner_key) ids
      left join sync_private.profile_pins pins on pins.user_key = owner_key
        and pins.profile_id = ids.profile_id));
  end if;
  if p_profile_id is null or char_length(p_profile_id) > 128 then
    return jsonb_build_object('ok', false, 'error', 'profile_not_found');
  end if;
  -- Parent first, then advisory lock: DELETE takes locks in the same order.
  perform 1 from sync_api.viewer_profiles
    where user_key = owner_key and profile_id = p_profile_id for key share;
  if not found and p_profile_id <> 'default' then
    return jsonb_build_object('ok', false, 'error', 'profile_not_found');
  end if;
  -- Serialize lock creation as well as attempts against an existing lock.
  perform pg_advisory_xact_lock(hashtext(owner_key), hashtext(p_profile_id));
  select * into lock_row from sync_private.profile_pins
    where user_key = owner_key and profile_id = p_profile_id for update;
  has_lock := found;
  if p_action = 'status' then
    return jsonb_build_object('ok', true, 'locked', has_lock, 'version', lock_row.version);
  end if;
  if not sync_private.allow_pin_request('user:' || owner_key, 30) then
    return jsonb_build_object('ok', false, 'error', 'rate_limited', 'retry_after', 60);
  end if;
  if p_action in ('set', 'recover') and
      (p_new_pin is null or char_length(p_new_pin) not in (4, 6) or p_new_pin ~ '[^0-9]') then
    return jsonb_build_object('ok', false, 'error', 'invalid_pin');
  end if;
  if p_pin is not null and char_length(p_pin) > 32 or
      p_secret is not null and char_length(p_secret) > 128 then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  if not has_lock then
    if p_action = 'unlock' then return jsonb_build_object('ok', true, 'locked', false); end if;
    if p_action <> 'set' then return jsonb_build_object('ok', false, 'error', 'not_locked'); end if;
    allowed := true;
  else
    if lock_row.blocked_until > clock_timestamp() then
      return jsonb_build_object('ok', false, 'error', 'rate_limited',
        'retry_after', ceil(extract(epoch from lock_row.blocked_until - clock_timestamp())));
    end if;
    if p_action in ('device_unlock', 'device_remove') then
      allowed := exists (select 1 from sync_private.profile_pin_devices
        where user_key = owner_key and profile_id = p_profile_id
          and version = lock_row.version and expires_at > clock_timestamp()
          and token_hash = sync_private.digest(p_secret, 'sha256'));
    elsif p_action = 'recover' then
      allowed := lock_row.recovery_hash = sync_private.digest(p_secret, 'sha256');
    elsif p_pin is not null then
      -- Bound expensive password hashing on the shared two-core server.
      if not sync_private.allow_pin_request('hashes', 120) then
        return jsonb_build_object('ok', false, 'error', 'rate_limited', 'retry_after', 60);
      end if;
      allowed := lock_row.pin_hash = sync_private.crypt(
        encode(sync_private.digest(p_pin, 'sha256'), 'hex'), lock_row.pin_hash);
    end if;
  end if;
  if allowed is distinct from true then
    update sync_private.profile_pins set failures = least(failures + 1, 20),
      blocked_until = case when failures + 1 >= 5 then clock_timestamp() +
        make_interval(secs => 30 * power(2, least(failures - 4, 5))::integer)
        else '-infinity'::timestamptz end
      where user_key = owner_key and profile_id = p_profile_id;
    return jsonb_build_object('ok', false, 'error', 'verification_failed');
  end if;
  if p_action = 'remove' then
    delete from sync_private.profile_pins where user_key = owner_key and profile_id = p_profile_id;
    return jsonb_build_object('ok', true, 'locked', false);
  end if;
  if p_action = 'device_remove' then
    delete from sync_private.profile_pin_devices where user_key = owner_key
      and profile_id = p_profile_id and token_hash = sync_private.digest(p_secret, 'sha256');
    return jsonb_build_object('ok', true);
  end if;
  if p_action in ('set', 'recover') then
    if not sync_private.allow_pin_request('hashes', 120) then
      return jsonb_build_object('ok', false, 'error', 'rate_limited', 'retry_after', 60);
    end if;
    recovery := encode(sync_private.gen_random_bytes(16), 'hex');
    insert into sync_private.profile_pins(user_key, profile_id, pin_hash, recovery_hash)
      values (owner_key, p_profile_id, sync_private.crypt(
        encode(sync_private.digest(p_new_pin, 'sha256'), 'hex'), sync_private.gen_salt('bf', 12)),
        sync_private.digest(recovery, 'sha256'))
      on conflict (user_key, profile_id) do update set pin_hash = excluded.pin_hash,
        recovery_hash = excluded.recovery_hash, version = profile_pins.version + 1,
        failures = 0, blocked_until = '-infinity';
    delete from sync_private.profile_pin_grants where user_key = owner_key and profile_id = p_profile_id;
    delete from sync_private.profile_pin_devices where user_key = owner_key and profile_id = p_profile_id;
  else
    update sync_private.profile_pins set failures = 0, blocked_until = '-infinity'
      where user_key = owner_key and profile_id = p_profile_id;
  end if;
  select * into lock_row from sync_private.profile_pins where user_key = owner_key and profile_id = p_profile_id;
  if p_action = 'device_enroll' then
    device_token := encode(sync_private.gen_random_bytes(32), 'hex');
    delete from sync_private.profile_pin_devices where user_key = owner_key
      and profile_id = p_profile_id and expires_at <= clock_timestamp();
    if (select count(*) from sync_private.profile_pin_devices
        where user_key = owner_key and profile_id = p_profile_id) >= 20 then
      return jsonb_build_object('ok', false, 'error', 'device_limit');
    end if;
    insert into sync_private.profile_pin_devices values (owner_key, p_profile_id,
      sync_private.digest(device_token, 'sha256'), lock_row.version, clock_timestamp() + interval '90 days');
  end if;
  token := encode(sync_private.gen_random_bytes(32), 'hex');
  deadline := clock_timestamp() + interval '12 hours';
  delete from sync_private.profile_pin_grants where user_key = owner_key
    and profile_id = p_profile_id and expires_at <= clock_timestamp();
  insert into sync_private.profile_pin_grants values (owner_key, p_profile_id,
    sync_private.digest(token, 'sha256'), lock_row.version, deadline);
  response := jsonb_build_object('ok', true, 'locked', true, 'version', lock_row.version,
    'grant_token', token, 'expires_at', deadline);
  if recovery is not null then response := response || jsonb_build_object('recovery_code', recovery); end if;
  if device_token is not null then response := response || jsonb_build_object('device_token', device_token); end if;
  return response;
end;
$$;
revoke all on function sync_api.profile_lock(text, text, text, text, text) from public;
grant execute on function sync_api.profile_lock(text, text, text, text, text) to authenticated;

create or replace function sync_private.clear_deleted_profile_pin()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from sync_private.profile_pins where user_key = old.user_key and profile_id = old.profile_id;
  return old;
end;
$$;
revoke all on function sync_private.clear_deleted_profile_pin() from public;
create or replace function sync_private.guard_profile_pin_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtext(old.user_key), hashtext(old.profile_id));
  if current_setting('role', true) = 'authenticated' then
    perform sync_private.require_profile_access(old.user_key, old.profile_id);
  end if;
  return old;
end;
$$;
revoke all on function sync_private.guard_profile_pin_delete() from public;
drop trigger if exists guard_profile_pin_delete on sync_api.viewer_profiles;
create trigger guard_profile_pin_delete before delete on sync_api.viewer_profiles
  for each row execute function sync_private.guard_profile_pin_delete();
drop trigger if exists clear_deleted_profile_pin on sync_api.viewer_profiles;
create trigger clear_deleted_profile_pin after delete on sync_api.viewer_profiles
  for each row execute function sync_private.clear_deleted_profile_pin();

do $$
declare table_name text;
begin
  foreach table_name in array array['history', 'reading_history', 'mylist',
    'list_categories', 'mylist_categories'] loop
    execute format('drop policy if exists profile_pin_access on sync_api.%I', table_name);
    execute format('create policy profile_pin_access on sync_api.%I as restrictive '
      'for all to authenticated using (sync_private.require_profile_access(user_key, ''default'')) '
      'with check (sync_private.require_profile_access(user_key, ''default''))', table_name);
  end loop;
  foreach table_name in array array['profile_history', 'profile_reading_history',
    'profile_mylist', 'profile_list_categories', 'profile_mylist_categories'] loop
    execute format('drop policy if exists profile_pin_access on sync_api.%I', table_name);
    execute format('create policy profile_pin_access on sync_api.%I as restrictive '
      'for all to authenticated using (sync_private.require_profile_access(user_key, profile_id)) '
      'with check (sync_private.require_profile_access(user_key, profile_id))', table_name);
  end loop;
  foreach table_name in array array['mylist_sync_clock', 'mylist_sync_tombstones'] loop
    execute format('drop policy if exists profile_pin_access on sync_api.%I', table_name);
    execute format('create policy profile_pin_access on sync_api.%I as restrictive '
      'for select to authenticated using (sync_private.require_profile_access('
      'user_key, coalesce(nullif(profile_scope, ''''), ''default'')))', table_name);
  end loop;
end;
$$;
drop policy if exists profile_pin_backup_access on sync_api.backups;
create policy profile_pin_backup_access on sync_api.backups as restrictive for all to authenticated
  using (sync_private.require_all_profile_access(user_key))
  with check (sync_private.require_all_profile_access(user_key));
drop policy if exists profile_pin_edit_access on sync_api.viewer_profiles;
create policy profile_pin_edit_access on sync_api.viewer_profiles as restrictive for update to authenticated
  using (sync_private.require_profile_access(user_key, profile_id))
  with check (sync_private.require_profile_access(user_key, profile_id));
drop policy if exists profile_pin_delete_access on sync_api.viewer_profiles;
create policy profile_pin_delete_access on sync_api.viewer_profiles as restrictive for delete to authenticated
  using (sync_private.require_profile_access(user_key, profile_id));
drop policy if exists profile_pin_insert_access on sync_api.viewer_profiles;
create policy profile_pin_insert_access on sync_api.viewer_profiles as restrictive for insert to authenticated
  with check (sync_private.require_profile_access(user_key, profile_id));

notify pgrst, 'reload schema';
