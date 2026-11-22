-- JWT signatures are checked by PostgREST before this request hook.
create or replace function sync_private.verify_auth_issuer()
returns void
language plpgsql
stable
set search_path = pg_catalog
as $$
declare
  claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
begin
  if coalesce(claims->>'iss', '') not in (
    'https://eogwzrlfoercfwcfwlmv.supabase.co/auth/v1',
    'https://sb.AniAura.online/auth/v1'
  ) or coalesce(claims->>'role', '') <> 'authenticated'
    or claims->>'is_anonymous' = 'true' then
    raise sqlstate 'PT401' using message = 'Invalid sign-in token';
  end if;
end;
$$;
revoke all on function sync_private.verify_auth_issuer() from public;
grant execute on function sync_private.verify_auth_issuer() to authenticated;
