-- supabase/migrations/0001_schema.sql
-- All user-data tables key on user_key TEXT. Pre-migration rows hold the
-- Appwrite user id; migrate-account rewrites them to the Supabase auth uid
-- (as text) at claim time, after which user_key = auth.uid()::text always.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  avatar_path text,                       -- Storage object path, e.g. legacy/<uid>.jpg
  legacy_uid text unique,                 -- Appwrite user id, null for post-switch signups
  needs_password_capture boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.mylist (
  user_key text not null,
  source_id text not null,
  item_id text not null,
  title text not null default '',
  cover text,
  cover_headers jsonb,
  url text,
  type text,
  added_at bigint not null default 0,
  primary key (user_key, source_id, item_id)
);

create table if not exists public.history (
  user_key text not null,
  source_id text not null,
  show_id text not null,
  show_title text not null default '',
  cover text,
  cover_headers jsonb,
  show_url text,
  category text,
  episode_id text,
  episode_number int,
  episode_url text,
  position_ms bigint not null default 0,
  duration_ms bigint not null default 0,
  updated_at bigint not null default 0,
  mal_id text,
  primary key (user_key, source_id, show_id)
);

create table if not exists public.backups (
  user_key text primary key,
  payload text not null,                  -- JSON string, <=1MB
  updated_at timestamptz not null default now()
);

create table if not exists public.watch_rooms (
  code text primary key,                  -- 8-char room code
  host_key text not null,                 -- host's user_key (auth.uid()::text)
  status text not null default 'live',
  content jsonb,                          -- current content descriptor (episode, title, source)
  host_pos_ms bigint not null default 0,
  host_rate double precision not null default 1.0,
  host_playing boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.tv_pairings (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  status text not null default 'pending', -- pending | approved | consumed
  device_name text not null default '',
  app_user_id text,
  app_secret text,
  tracker_blob text,
  expires_at bigint not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_tv_pairings_code on public.tv_pairings(code);
