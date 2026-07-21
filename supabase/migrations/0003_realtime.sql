-- Realtime: Watch Together subscribes to Postgres changes on watch_rooms
-- (episode change / pause-stop anchor / host transfer / room end) over the same
-- channel that carries host-beat broadcast + presence + chat. The table MUST be
-- in the supabase_realtime publication or that binding errors and takes the
-- whole channel down (no sync, no roster, no chat). REPLICA IDENTITY FULL makes
-- the filtered UPDATE events carry the complete row. Writes here are rare (the
-- 4s beat is broadcast, zero-write), so the WAL cost is negligible.
alter publication supabase_realtime add table public.watch_rooms;
alter table public.watch_rooms replica identity full;
