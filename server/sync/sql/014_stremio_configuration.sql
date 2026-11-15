-- Only encrypted addon configurations reach durable storage.
begin;
create table if not exists sync_private.stremio_configurations (
  user_key text primary key,
  version bigint not null default 0,
  payload jsonb,
  updated_at timestamptz not null default now()
);
revoke all on sync_private.stremio_configurations from public, authenticated;

create or replace function sync_api.stremio_configuration(
  p_expected_version bigint default null, p_payload jsonb default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  owner_key text := sync_private.jwt_user_key();
  row sync_private.stremio_configurations%rowtype;
  accepted boolean := false;
begin
  if owner_key is null or btrim(owner_key) = '' then
    raise sqlstate 'PT401' using message = 'Sign in required';
  end if;
  if p_expected_version is not null and (
    p_expected_version < 0 or p_payload is null or
    p_payload->>'format' is distinct from 'stremio-server-v1' or
    octet_length(p_payload::text) > 2097152
  ) then
    raise sqlstate 'PT400' using message = 'Invalid configuration';
  end if;
  insert into sync_private.stremio_configurations(user_key) values(owner_key)
    on conflict do nothing;
  select * into row from sync_private.stremio_configurations
    where user_key = owner_key for update;
  accepted := p_expected_version is null or p_expected_version = row.version;
  if p_expected_version is not null and accepted then
    update sync_private.stremio_configurations set version = version + 1,
      payload = p_payload, updated_at = clock_timestamp()
      where user_key = owner_key returning * into row;
  end if;
  return jsonb_build_object('version', row.version, 'payload', row.payload, 'accepted', accepted);
end;
$$;
revoke all on function sync_api.stremio_configuration(bigint, jsonb) from public;
grant execute on function sync_api.stremio_configuration(bigint, jsonb) to authenticated;
notify pgrst, 'reload schema';
commit;
