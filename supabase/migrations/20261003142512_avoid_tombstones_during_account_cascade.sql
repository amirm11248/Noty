create or replace function public.noty_record_cloud_tombstone()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- During auth.users ON DELETE CASCADE the parent no longer exists.
  -- Recording a new child tombstone then would violate the account FK.
  if not exists (select 1 from auth.users where id = old.user_id) then
    return old;
  end if;
  insert into public.noty_cloud_tombstones(user_id, entity_type, entity_id, deleted_at)
  values (old.user_id, tg_argv[0], old.id, now())
  on conflict (user_id, entity_type, entity_id)
  do update set deleted_at = greatest(public.noty_cloud_tombstones.deleted_at, excluded.deleted_at);
  return old;
end;
$$;
revoke all on function public.noty_record_cloud_tombstone() from public, anon, authenticated;
