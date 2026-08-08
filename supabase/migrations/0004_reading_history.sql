-- supabase/migrations/0004_reading_history.sql
-- Continue Reading: per-title reading progress for manga/novel mode, the
-- reading counterpart of public.history (Continue Watching). Not applied
-- automatically — run this by hand against the project, same as 0001-0003
-- were. Until it's run, ReadHistory degrades to local-only (see
-- lib/core/reading/read_history.dart).

create table if not exists public.reading_history (
  user_key text not null,
  source_id text not null,
  show_id text not null,
  title text not null default '',
  cover text,
  chapter_id text,
  chapter_number double precision,
  chapter_url text,
  pos integer not null default 0,
  total integer not null default 0,
  updated_ms bigint not null default 0,
  -- 'manga' or 'novel' — which reader a chapter opens in (see ReadEntry.type
  -- in lib/core/reading/read_history.dart). No default: the app always
  -- writes it now, and a row missing it is read back as 'novel' client-side
  -- (readEntryTypeFromName), not here — a DB default would silently paper
  -- over a future write path that forgets to set it.
  type text,
  primary key (user_key, source_id, show_id)
);

alter table public.reading_history enable row level security;

-- Same policy shape as history_own in 0002_rls.sql: strictly own rows.
create policy reading_history_own on public.reading_history
  for all using (user_key = auth.uid()::text) with check (user_key = auth.uid()::text);
