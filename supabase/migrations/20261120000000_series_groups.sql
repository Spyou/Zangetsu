-- Series groups: manual card-merge for My List ("Fate" seasons 1-5 as one
-- card). One row per group; membership lives in the row itself (ordered
-- title keys), same pattern as custom_lists. Columns mirror
-- SeriesGroupStore._rowFor exactly: id, user_key, title, position,
-- member_keys, cover_mode, cover_member_key.
create table if not exists public.series_groups (
  user_key text not null,
  id uuid not null default gen_random_uuid(),
  title text not null,
  position integer not null default 0,
  member_keys jsonb not null default '[]',
  cover_mode text not null default 'auto',
  cover_member_key text,
  primary key (user_key, id)
);

alter table public.series_groups enable row level security;
drop policy if exists series_groups_own on public.series_groups;
create policy series_groups_own on public.series_groups
  for all using (user_key = auth.uid()::text)
  with check (user_key = auth.uid()::text);
