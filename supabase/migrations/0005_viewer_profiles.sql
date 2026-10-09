create table if not exists public.viewer_profiles (
  user_key text not null,
  profile_id text not null,
  name text not null check (char_length(btrim(name)) between 1 and 24),
  avatar integer not null default 0 check (avatar between 0 and 11),
  is_kids boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (user_key, profile_id)
);

create or replace function public.enforce_viewer_profile_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform pg_advisory_xact_lock(hashtext(new.user_key), 0);
  if not exists (
    select 1 from public.viewer_profiles
    where user_key = new.user_key and profile_id = new.profile_id
  ) and (
    select count(*) from public.viewer_profiles where user_key = new.user_key
  ) >= 4 then
    raise exception 'A maximum of four profiles is allowed per account';
  end if;
  return new;
end;
$$;

drop trigger if exists viewer_profile_limit on public.viewer_profiles;
create trigger viewer_profile_limit
before insert on public.viewer_profiles
for each row execute function public.enforce_viewer_profile_limit();

alter table public.viewer_profiles enable row level security;
drop policy if exists viewer_profiles_own on public.viewer_profiles;
create policy viewer_profiles_own on public.viewer_profiles
  for all using (user_key = auth.uid()::text)
  with check (user_key = auth.uid()::text);

create table if not exists public.profile_mylist (
  user_key text not null,
  profile_id text not null,
  source_id text not null,
  item_id text not null,
  title text not null default '',
  cover text,
  cover_headers jsonb,
  url text,
  type text,
  status text,
  added_at bigint not null default 0,
  primary key (user_key, profile_id, source_id, item_id),
  foreign key (user_key, profile_id)
    references public.viewer_profiles(user_key, profile_id) on delete cascade
);

create table if not exists public.profile_history (
  user_key text not null,
  profile_id text not null,
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
  primary key (user_key, profile_id, source_id, show_id),
  foreign key (user_key, profile_id)
    references public.viewer_profiles(user_key, profile_id) on delete cascade
);

create table if not exists public.profile_reading_history (
  user_key text not null,
  profile_id text not null,
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
  type text,
  primary key (user_key, profile_id, source_id, show_id),
  foreign key (user_key, profile_id)
    references public.viewer_profiles(user_key, profile_id) on delete cascade
);

create table if not exists public.profile_list_categories (
  user_key text not null,
  profile_id text not null,
  id uuid not null default gen_random_uuid(),
  name text not null,
  position integer not null default 0,
  primary key (user_key, profile_id, id),
  foreign key (user_key, profile_id)
    references public.viewer_profiles(user_key, profile_id) on delete cascade
);

create table if not exists public.profile_mylist_categories (
  user_key text not null,
  profile_id text not null,
  source_id text not null,
  item_id text not null,
  category_id uuid not null,
  primary key (user_key, profile_id, source_id, item_id, category_id),
  foreign key (user_key, profile_id)
    references public.viewer_profiles(user_key, profile_id) on delete cascade,
  foreign key (user_key, profile_id, category_id)
    references public.profile_list_categories(user_key, profile_id, id)
    on delete cascade
);

alter table public.profile_mylist enable row level security;
alter table public.profile_history enable row level security;
alter table public.profile_reading_history enable row level security;
alter table public.profile_list_categories enable row level security;
alter table public.profile_mylist_categories enable row level security;

create policy profile_mylist_own on public.profile_mylist
  for all using (user_key = auth.uid()::text)
  with check (user_key = auth.uid()::text);
create policy profile_history_own on public.profile_history
  for all using (user_key = auth.uid()::text)
  with check (user_key = auth.uid()::text);
create policy profile_reading_history_own on public.profile_reading_history
  for all using (user_key = auth.uid()::text)
  with check (user_key = auth.uid()::text);
create policy profile_list_categories_own on public.profile_list_categories
  for all using (user_key = auth.uid()::text)
  with check (user_key = auth.uid()::text);
create policy profile_mylist_categories_own on public.profile_mylist_categories
  for all using (user_key = auth.uid()::text)
  with check (user_key = auth.uid()::text);
