-- Synthetic users only; all test rows are rolled back.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"pin-test-owner"}', true);
insert into sync_api.viewer_profiles (user_key, profile_id, name) values
  ('pin-test-owner', 'default', 'Home'),
  ('pin-test-owner', 'private', 'Private');
insert into sync_api.history (user_key, source_id, show_id) values
  ('pin-test-owner', 'source', 'main');
insert into sync_api.profile_history (user_key, profile_id, source_id, show_id) values
  ('pin-test-owner', 'private', 'source', 'private-show');
insert into sync_api.profile_mylist(user_key,profile_id,source_id,item_id) values ('pin-test-owner','private','source','item');
insert into sync_api.profile_reading_history(user_key,profile_id,source_id,show_id) values ('pin-test-owner','private','source','book');
update sync_api.viewer_profiles set photo_url = 'https://avatars.example/avatars/pin-test-owner/private.jpg' where profile_id = 'private';
insert into sync_api.backups (user_key, payload) values ('pin-test-owner', '{}');

do $$
declare
  result jsonb;
  grant_token text;
  device_token text;
  recovery text;
begin
  result := sync_api.profile_lock('set', 'private', null, 'abcde');
  if result->>'error' <> 'invalid_pin' then raise exception 'alphabetic PIN accepted'; end if;
  result := sync_api.profile_lock('set', 'private', null, '12345');
  if result->>'error' <> 'invalid_pin' then raise exception 'five digit PIN accepted'; end if;
  result := sync_api.profile_lock('set', 'private', null, '1234');
  if not (result->>'ok')::boolean or result->>'recovery_code' is null then
    raise exception 'setting a PIN did not return a recovery code';
  end if;
  recovery := result->>'recovery_code';
  begin
    perform sync_api.profile_lock('asset_delete_access', null, null, null, 'avatars/pin-test-owner/private.jpg');
    raise exception 'locked avatar could be deleted';
  exception when sqlstate 'PT403' then null;
  end;
  result := sync_api.profile_lock('asset_delete_access', null, null, null, 'avatars/pin-test-owner/unused.jpg');
  if not (result->>'ok')::boolean then raise exception 'unused upload cleanup blocked'; end if;
  perform set_config('request.headers', '{}', true);
  begin
    perform 1 from sync_api.profile_history where profile_id = 'private';
    raise exception 'locked history could be read without an unlock';
  exception when sqlstate 'PT403' then null;
  end;
  begin
    perform 1 from sync_api.profile_mylist where profile_id = 'private';
    raise exception 'locked list could be read';
  exception when sqlstate 'PT403' then null;
  end;
  begin
    perform 1 from sync_api.profile_reading_history where profile_id = 'private';
    raise exception 'locked reading history could be read';
  exception when sqlstate 'PT403' then null;
  end;
  begin
    perform 1 from sync_api.backups;
    raise exception 'whole-account backup bypassed profile lock';
  exception when sqlstate 'PT403' then null;
  end;
  begin
    update sync_api.viewer_profiles set name = 'Bypass' where profile_id = 'private';
    raise exception 'locked profile could be edited without an unlock';
  exception when sqlstate 'PT403' then null;
  end;
  if (select count(*) from sync_api.history) != 1 then
    raise exception 'locking one profile affected an unlocked profile';
  end if;
  result := sync_api.profile_lock('unlock', 'private', '0000');
  if (result->>'ok')::boolean then raise exception 'wrong PIN unlocked profile'; end if;
  result := sync_api.profile_lock('unlock', 'private', '1234');
  if not (result->>'ok')::boolean then raise exception 'correct PIN rejected'; end if;
  grant_token := result->>'grant_token';
  perform set_config('request.headers', jsonb_build_object(
    'x-profile-grants', jsonb_build_object('private', grant_token)::text)::text, true);
  if (select count(*) from sync_api.profile_history where profile_id = 'private') != 1 then
    raise exception 'unlock did not grant access to history';
  end if;
  result := sync_api.profile_lock('asset_delete_access', null, null, null, 'avatars/pin-test-owner/private.jpg');
  if not (result->>'ok')::boolean then raise exception 'unlocked asset cleanup blocked'; end if;
  if (select count(*) from sync_api.backups) != 1 then
    raise exception 'verified profile could not access its backup';
  end if;
  result := sync_api.profile_lock('device_enroll', 'private', '0000');
  if (result->>'ok')::boolean then raise exception 'biometrics enrolled without PIN'; end if;
  result := sync_api.profile_lock('device_enroll', 'private', '1234');
  device_token := result->>'device_token';
  if device_token is null then raise exception 'device enrollment failed'; end if;
  result := sync_api.profile_lock('device_unlock', 'private', null, null, device_token);
  if not (result->>'ok')::boolean then raise exception 'enrolled device rejected'; end if;
  result := sync_api.profile_lock('set', 'private', '1234', '056789');
  if not (result->>'ok')::boolean then raise exception 'PIN change failed'; end if;
  begin
    perform 1 from sync_api.profile_history where profile_id = 'private';
    raise exception 'old grant survived PIN change';
  exception when sqlstate 'PT403' then null;
  end;
  result := sync_api.profile_lock('device_unlock', 'private', null, null, device_token);
  if (result->>'ok')::boolean then raise exception 'old device survived PIN change'; end if;
  result := sync_api.profile_lock('recover', 'private', null, '9012', recovery);
  if (result->>'ok')::boolean then raise exception 'old recovery code survived PIN change'; end if;
  result := sync_api.profile_lock('status', 'private');
  if not (result->>'locked')::boolean then raise exception 'status lost lock'; end if;
  if result ? 'pin_hash' or result ? 'recovery_hash' or result ? 'device_token' then
    raise exception 'status exposed a credential';
  end if;
  perform set_config('request.jwt.claims', '{"sub":"pin-test-other"}', true);
  result := sync_api.profile_lock('unlock', 'private', '056789');
  if (result->>'ok')::boolean then raise exception 'cross-account unlock succeeded'; end if;
end;
$$;

select set_config('request.jwt.claims', '{"sub":"pin-test-owner"}', true);
select set_config('request.headers', '{}', true);
do $$
declare result jsonb; recovery text; i integer;
begin
  result := sync_api.profile_lock('set', 'default', null, '1234');
  recovery := result->>'recovery_code';
  begin
    perform 1 from sync_api.history;
    raise exception 'default profile history bypassed PIN';
  exception when sqlstate 'PT403' then null;
  end;
  begin
    perform 1 from sync_private.profile_pins;
    raise exception 'client could read credential hashes';
  exception when insufficient_privilege then null;
  end;
  for i in 1..5 loop
    result := sync_api.profile_lock('unlock', 'default', '0000');
    if (result->>'ok')::boolean then raise exception 'wrong PIN accepted'; end if;
  end loop;
  result := sync_api.profile_lock('unlock', 'default', '1234');
  if result->>'error' <> 'rate_limited' or (result->>'retry_after')::integer < 1 then
    raise exception 'failed PIN attempts were not rate limited';
  end if;
end;
$$;

-- The test owner alone advances its synthetic cooldown.
reset role;
update sync_private.profile_pins set blocked_until = '-infinity', failures = 0
where user_key = 'pin-test-owner' and profile_id = 'default';
set local role authenticated;
do $$
declare result jsonb; recovery text; grant_token text;
begin
  result := sync_api.profile_lock('set', 'default', '1234', '056789');
  recovery := result->>'recovery_code';
  result := sync_api.profile_lock('recover', 'default', null, '9012', recovery);
  if not (result->>'ok')::boolean then raise exception 'valid recovery code rejected'; end if;
  if result->>'recovery_code' = recovery then raise exception 'recovery code was not rotated'; end if;
  result := sync_api.profile_lock('unlock', 'default', '056789');
  if (result->>'ok')::boolean then raise exception 'old PIN survived recovery'; end if;
  result := sync_api.profile_lock('unlock', 'default', '9012');
  if not (result->>'ok')::boolean then raise exception 'new PIN failed after recovery'; end if;
  result := sync_api.profile_lock('remove', 'default', '0000');
  if (result->>'ok')::boolean then raise exception 'lock removed without correct PIN'; end if;
  result := sync_api.profile_lock('remove', 'default', '9012');
  if not (result->>'ok')::boolean then raise exception 'correct PIN could not remove lock'; end if;
  if (select count(*) from sync_api.history) != 1 then raise exception 'history lost after lock removal'; end if;
  result := sync_api.profile_lock('unlock', 'private', '056789');
  grant_token := result->>'grant_token';
  perform set_config('request.headers', jsonb_build_object(
    'x-profile-grants', jsonb_build_object('private', grant_token)::text)::text, true);
  delete from sync_api.viewer_profiles where profile_id = 'private';
  result := sync_api.profile_lock('backup_access');
  if not (result->>'ok')::boolean then raise exception 'deleted profile stranded a lock'; end if;
end;
$$;
rollback;
