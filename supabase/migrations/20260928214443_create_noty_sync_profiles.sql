-- Noty account workspace metadata.
-- The app uses only Supabase's public client key. Every row is protected by RLS.

create table if not exists public.noty_sync_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  icloud_share_url text,
  folder_display_name text,
  sync_mode text not null default 'folder' check (sync_mode in ('folder')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.noty_sync_profiles enable row level security;

revoke all on table public.noty_sync_profiles from anon;
grant select, insert, update, delete on table public.noty_sync_profiles to authenticated;

drop policy if exists "Users can read their Noty sync profile" on public.noty_sync_profiles;
create policy "Users can read their Noty sync profile"
on public.noty_sync_profiles
for select
to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists "Users can create their Noty sync profile" on public.noty_sync_profiles;
create policy "Users can create their Noty sync profile"
on public.noty_sync_profiles
for insert
to authenticated
with check ((select auth.uid()) = user_id);

drop policy if exists "Users can update their Noty sync profile" on public.noty_sync_profiles;
create policy "Users can update their Noty sync profile"
on public.noty_sync_profiles
for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists "Users can delete their Noty sync profile" on public.noty_sync_profiles;
create policy "Users can delete their Noty sync profile"
on public.noty_sync_profiles
for delete
to authenticated
using ((select auth.uid()) = user_id);
