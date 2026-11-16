\set ON_ERROR_STOP on
begin;
do $$
declare
  issuer text;
  invalid jsonb;
begin
  foreach issuer in array array[
    'https://eogwzrlfoercfwcfwlmv.supabase.co/auth/v1',
    'https://sb.zangetsu.online/auth/v1'
  ] loop
    perform set_config('request.jwt.claims', jsonb_build_object('iss', issuer, 'role', 'authenticated')::text, true);
    perform sync_private.verify_auth_issuer();
  end loop;
  for invalid in select value from jsonb_array_elements('[
    {},
    {"iss":"https://attacker.invalid/auth/v1","role":"authenticated"},
    {"iss":"https://sb.zangetsu.online/auth/v1/","role":"authenticated"},
    {"iss":"https://sb.zangetsu.online/auth/v1","role":"anon"},
    {"iss":"https://sb.zangetsu.online/auth/v1","role":"authenticated","is_anonymous":true}
  ]'::jsonb) loop
    perform set_config('request.jwt.claims', invalid::text, true);
    begin
      perform sync_private.verify_auth_issuer();
      raise exception 'Invalid claims were accepted';
    exception when sqlstate 'PT401' then null;
    end;
  end loop;
end;
$$;
rollback;
