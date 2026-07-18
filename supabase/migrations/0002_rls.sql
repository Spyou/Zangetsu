-- supabase/migrations/0002_rls.sql
alter table public.profiles     enable row level security;
alter table public.mylist       enable row level security;
alter table public.history      enable row level security;
alter table public.backups      enable row level security;
alter table public.watch_rooms  enable row level security;
alter table public.tv_pairings  enable row level security;

-- Helper: current user's key as text
-- (auth.uid() is uuid; user_key stores it as text)

-- profiles: own row full access
create policy profiles_self on public.profiles
  for all using (id = auth.uid()) with check (id = auth.uid());

-- mylist / history / backups: strictly own rows
create policy mylist_own on public.mylist
  for all using (user_key = auth.uid()::text) with check (user_key = auth.uid()::text);
create policy history_own on public.history
  for all using (user_key = auth.uid()::text) with check (user_key = auth.uid()::text);
create policy backups_own on public.backups
  for all using (user_key = auth.uid()::text) with check (user_key = auth.uid()::text);

-- watch_rooms: any authenticated user can read (join by code) and create;
-- update/delete host-only. Joining writes nothing (Presence covers it).
create policy rooms_read on public.watch_rooms
  for select using (auth.role() = 'authenticated');
create policy rooms_create on public.watch_rooms
  for insert with check (host_key = auth.uid()::text);
create policy rooms_host_update on public.watch_rooms
  for update using (host_key = auth.uid()::text) with check (host_key = auth.uid()::text);
create policy rooms_host_delete on public.watch_rooms
  for delete using (host_key = auth.uid()::text);

-- tv_pairings: clients may ONLY insert a pending row (a TV registering).
-- No client select/update/delete — the TV never reads the table; it learns
-- approval + the login secret via the pair-tv function's `poll` action (passing
-- the tv_secret it generated), and the function (service role) returns app_secret
-- only when that secret matches. This prevents any client reading another
-- device's app_secret / tracker_blob.
create policy pairings_insert on public.tv_pairings
  for insert with check (status = 'pending');

-- Public name+avatar for the party UI, WITHOUT leaking legacy_uid /
-- needs_password_capture (RLS is row-level; a view is the column filter).
create or replace view public.public_profiles as
  select id, display_name, avatar_path from public.profiles;
grant select on public.public_profiles to authenticated;
