-- Shared Noty cloud model for iOS + web. Existing Sites tables are preserved.

create table if not exists public.noty_web_folders (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  name text not null check (char_length(name) between 1 and 200),
  parent_id uuid,
  color text not null default '#294fe3',
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

alter table public.noty_web_folders
  add column if not exists payload jsonb not null default '{}'::jsonb;

create table if not exists public.noty_web_documents (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  title text not null check (char_length(title) between 1 and 300),
  kind text not null default 'note' check (kind in ('note','pdf','book','whiteboard')),
  folder_id uuid,
  payload jsonb not null default '{"pages":[]}'::jsonb check (jsonb_typeof(payload) = 'object'),
  starred boolean not null default false,
  trashed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revision bigint not null default 1,
  primary key (user_id, id)
);

create table if not exists public.noty_cloud_assets (
  user_id uuid not null references auth.users(id) on delete cascade,
  document_id uuid not null,
  relative_path text not null
    check (
      char_length(relative_path) between 1 and 900
      and relative_path !~ '(^|/)\.\.(/|$)'
      and relative_path !~ '^/'
      and position(E'\\' in relative_path) = 0
    ),
  object_key text not null,
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  byte_size bigint not null check (byte_size >= 0),
  content_type text not null default 'application/octet-stream',
  updated_at timestamptz not null default now(),
  primary key (user_id, document_id, relative_path)
);

create index if not exists noty_cloud_assets_document_idx
  on public.noty_cloud_assets (user_id, document_id);

create table if not exists public.noty_cloud_tombstones (
  user_id uuid not null references auth.users(id) on delete cascade,
  entity_type text not null check (entity_type in ('document','folder')),
  entity_id uuid not null,
  deleted_at timestamptz not null default now(),
  primary key (user_id, entity_type, entity_id)
);

alter table public.noty_web_folders enable row level security;
alter table public.noty_web_documents enable row level security;
alter table public.noty_cloud_assets enable row level security;
alter table public.noty_cloud_tombstones enable row level security;

revoke all on table public.noty_web_folders from anon;
revoke all on table public.noty_web_documents from anon;
revoke all on table public.noty_cloud_assets from anon;
revoke all on table public.noty_cloud_tombstones from anon;

grant select, insert, update, delete on table public.noty_web_folders to authenticated;
grant select, insert, update, delete on table public.noty_web_documents to authenticated;
grant select, insert, update, delete on table public.noty_cloud_assets to authenticated;
grant select, insert, update, delete on table public.noty_cloud_tombstones to authenticated;

drop policy if exists "Own folders" on public.noty_web_folders;
create policy "Own folders" on public.noty_web_folders
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Own documents" on public.noty_web_documents;
create policy "Own documents" on public.noty_web_documents
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Own cloud assets" on public.noty_cloud_assets;
create policy "Own cloud assets" on public.noty_cloud_assets
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Own cloud tombstones" on public.noty_cloud_tombstones;
create policy "Own cloud tombstones" on public.noty_cloud_tombstones
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create or replace function public.noty_record_cloud_tombstone()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.noty_cloud_tombstones(user_id, entity_type, entity_id, deleted_at)
  values (old.user_id, tg_argv[0], old.id, now())
  on conflict (user_id, entity_type, entity_id)
  do update set deleted_at = greatest(public.noty_cloud_tombstones.deleted_at, excluded.deleted_at);
  return old;
end;
$$;

drop trigger if exists noty_documents_record_tombstone on public.noty_web_documents;
create trigger noty_documents_record_tombstone
after delete on public.noty_web_documents
for each row execute function public.noty_record_cloud_tombstone('document');

drop trigger if exists noty_folders_record_tombstone on public.noty_web_folders;
create trigger noty_folders_record_tombstone
after delete on public.noty_web_folders
for each row execute function public.noty_record_cloud_tombstone('folder');
