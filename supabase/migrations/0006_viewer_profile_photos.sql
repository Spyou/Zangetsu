alter table public.viewer_profiles
  add column if not exists photo_url text;
