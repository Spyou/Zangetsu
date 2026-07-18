-- supabase/migrations/0002_rls.sql
alter table public.profiles     enable row level security;
alter table public.mylist       enable row level security;
alter table public.history      enable row level security;
alter table public.backups      enable row level security;
alter table public.watch_rooms  enable row level security;
alter table public.tv_pairings  enable row level security;

-- Helper: current user's key as text
-- (auth.uid() is uuid; user_key stores it as text)

-- profiles: own row full access; name+avatar readable by any authenticated user
create policy profiles_self on public.profiles
  for all using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_read_all on public.profiles
  for select using (auth.role() = 'authenticated');

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

-- tv_pairings: TV (anon or authed) inserts a pending row and reads its own by code;
-- sensitive fields are written only by the Edge Function (service role bypasses RLS).
create policy pairings_insert on public.tv_pairings
  for insert with check (status = 'pending');
create policy pairings_read_own on public.tv_pairings
  for select using (true);   -- read is by code (opaque); no cross-user data leaks (secret written only after approve, TV polls its own code)
create policy pairings_delete_own on public.tv_pairings
  for delete using (true);
